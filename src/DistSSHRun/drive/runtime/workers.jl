"""Per-worker project directory for `Pkg.activate` (`myid` → path on that process)."""
const RUNNER_WORKER_PROJECT_DIRS = Dict{Int, String}()
"""Per-worker driver script path for `include` (`myid` → path on that process)."""
const RUNNER_WORKER_SCRIPT_PATHS = Dict{Int, String}()

function _register_drive_workers!(
        before::Set{Int},
        proj_path::String,
        script_path::String,
    )
    for w in workers()
        if w ∉ before
            RUNNER_WORKER_PROJECT_DIRS[w] = proj_path
            RUNNER_WORKER_SCRIPT_PATHS[w] = script_path
        end
    end
    return nothing
end

function _skip_global_worker_pkill()::Bool
    return get(ENV, "DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL", "") == "1"
end

# Pre-run local `pkill -f julia.*--worker` is gone: it is not pid-scoped and
# would reap workers belonging to other Julia processes on the same login
# (parallel tests, another drive). Local teardown is `rmprocs` at atexit.
# Remote untagged `pkill` is the same class (shared SSH host). Drive only
# `pkill`s argv containing `distsshkit-job:<id>` when `DISTSSHKIT_JOB_ID` is set.
# Machine-wide sweep remains `setup --cleanup`. Skip leftover tagged pkill with
# DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL=1.
function cleanup_stale_workers!(hosts::Vector{Tuple{String, Union{Int, Nothing}}})
    if _skip_global_worker_pkill() || isempty(hosts)
        return
    end
    job_id = DistSSHRun.resolved_kit_job_id()
    job_id === nothing && return
    writeln_both("Cleaning up stale workers..."; color = :light_black)

    for (host_name, _) in hosts
        DistSSHRun._drive_host_span!(host_name, "cleanup", :running)
        write_both("  $host_name: ")
        if DistSSHRun._pkill_remote_tagged_workers!(host_name, job_id)
            print_ok("✓")
            DistSSHRun._drive_host_span!(host_name, "cleanup", :ok)
        else
            print_progress_warn("(SSH unreachable)")
            DistSSHRun._drive_host_span!(host_name, "cleanup", :fail)
        end
        writeln_both("")
    end
    return writeln_both("")
end

# `add_drive_workers!` throws this after the host loop when nothing joined.
# `drive` deletes `kit.hosts` only for this error, not for an interrupt.
const _NO_WORKERS_JOINED = "No workers available. Check SSH connectivity."

function add_drive_workers!(
        hosts::Vector{Tuple{String, Union{Int, Nothing}}},
        parent_workers::Int,
        default_workers,
        julia_exe,
        proj_dir::String,
        script_path::String,
        project_root::String,
    )::Vector{String}
    empty!(RUNNER_WORKER_PROJECT_DIRS)
    empty!(RUNNER_WORKER_SCRIPT_PATHS)
    DistSSHRun._require_drive_host_status_idle!()
    DistSSHRun._clear_drive_host_worker_ids!()
    script_path = abspath(String(script_path))
    writeln_both("Adding workers..."; color = :light_black)

    successful_hosts = String[]

    DistSSHRun.ensure_run_cluster_cookie!()
    before_all = Set(workers())
    names = DistSSHRun.launch_override_names(ENV)
    notice = DistSSHRun.launch_override_notice(DistSSHRun.PARENT_HOST_NAME, names)
    isempty(notice) || writeln_both(notice)
    local_julia = DistSSHRun.pin_local_julia(nothing)
    host_manifests = Dict{Int, String}()

    if parent_workers > 0
        write_both("  $(DistSSHRun.PARENT_HOST_NAME) ($parent_workers workers): ")
        DistSSHRun._drive_host_span!(DistSSHRun.PARENT_HOST_NAME, "workers", :running)
        try
            before = Set(workers())
            DistSSHRun._add_local_drive_workers!(
                parent_workers, proj_dir, local_julia,
            )
            _register_drive_workers!(before, proj_dir, script_path)
            added = sort!(Int[w for w in workers() if w ∉ before])
            DistSSHRun._register_drive_host_worker_ids!(
                DistSSHRun.PARENT_HOST_NAME,
                added,
            )
            local_man = DistSSHRun._existing_project_manifest(proj_dir)
            if !isempty(local_man)
                for w in added
                    host_manifests[w] = local_man
                end
            end
            print_ok("✓")
            writeln_both("")
            DistSSHRun._drive_host_span!(DistSSHRun.PARENT_HOST_NAME, "workers", :ok)
        catch e
            DistSSHRun._drive_host_span!(DistSSHRun.PARENT_HOST_NAME, "workers", :fail)
            print_progress_err("✗ ($e)")
            writeln_both("")
        end
    else
        writeln_both("  $(DistSSHRun.PARENT_HOST_NAME): master only (use $(DistSSHRun.PARENT_HOST_NAME):N for parent workers)")
    end

    sshflags_cmd = Cmd(ssh_opts())

    for (host_name, host_workers_spec) in hosts
        DistSSHRun._drive_host_span!(host_name, "workers", :running)
        host_ok = false
        try
            host_workers = something(host_workers_spec, default_workers, 1)

            repo_ra = canonical_local_path(project_root)
            remote_proj = resolve_host_path_abs(host_name, proj_dir, repo_ra)
            remote_script = resolve_host_path_abs(host_name, script_path, repo_ra)
            if remote_proj === nothing || remote_script === nothing
                write_both("$host_name ($host_workers workers): ")
                missing = remote_proj === nothing ? remote_layout_path(proj_dir, repo_ra) :
                    remote_layout_path(script_path, repo_ra)
                print_progress_err("✗ (remote path not found: $missing)")
                writeln_both("")
                writeln_both("    hint: julia --project=. -m DistSSHKit setup --ship-tree $(setup_cli_host_token(host_name))")
                writeln_both("          julia --project=. -m DistSSHKit setup --instantiate $(setup_cli_host_token(host_name))")
                writeln_both("          or drive --ship-tree (extracts to runs/<run_id>/src/ and instantiates)")
                writeln_both("           or export DISTRIBUTED_REMOTE_PROJECT_ROOT=<abs path on host>")
                continue
            end

            host_julia = try
                DistSSHRun.pin_remote_julia(host_name, julia_exe)
            catch e
                e isa ArgumentError || rethrow()
                write_both("  $host_name: ")
                print_progress_err("✗ ($(e.msg))")
                writeln_both("")
                continue
            end
            if host_julia === nothing
                write_both("  $host_name: ")
                print_progress_err("✗ (Julia not found)")
                writeln_both("")
                continue
            end
            write_both("  $host_name: pinned $(host_julia)")
            writeln_both("")
            hn = DistSSHRun.launch_override_notice(host_name, names)
            isempty(hn) || writeln_both("  " * hn)
            write_both("  ")

            deps_err = DistSSHRun.probe_remote_project_deps(
                host_name, remote_proj; julia_path = String(host_julia),
            )
            if deps_err !== nothing
                write_both("$host_name ($host_workers workers): ")
                print_progress_err("✗ ($deps_err)")
                writeln_both("")
                writeln_both("    hint: julia --project=. -m DistSSHKit setup --instantiate $(setup_cli_host_token(host_name))")
                continue
            end

            write_both("$host_name ($host_workers workers): ")
            try
                before = Set(workers())
                # Default tunnel=true. Set DISTSSHKIT_SSH_TUNNEL=0 to disable.
                # Machine must be user@host: Distributed prefixes \$USER otherwise and
                # overrides SSH config User (Host aliases then look like "No free port?").
                # Bind 127.0.0.1 so the cluster cookie is not reachable on other interfaces.
                machine = DistSSHRun.ssh_addprocs_bind_localhost(host_name)
                DistSSHRun._add_ssh_drive_workers!(
                    machine,
                    host_workers,
                    host_julia,
                    remote_proj,
                    sshflags_cmd,
                )
                added = sort!(Int[w for w in workers() if w ∉ before])
                # `SSHManager.launch` can swallow a failed machine; `addprocs` then
                # returns with fewer (or zero) workers and no throw.
                if length(added) < host_workers
                    isempty(added) || rmprocs(added; waitfor = 2.0)
                    print_progress_err("✗ (wanted $host_workers workers, got $(length(added)))")
                    writeln_both("")
                    continue
                end
                _register_drive_workers!(before, remote_proj, remote_script)
                DistSSHRun._register_drive_host_worker_ids!(host_name, added)
                parent_man = DistSSHRun._existing_project_manifest(proj_dir)
                if !isempty(parent_man)
                    remote_man = joinpath(remote_proj, basename(parent_man))
                    for w in added
                        host_manifests[w] = remote_man
                    end
                end
                print_ok("✓")
                writeln_both("")
                push!(successful_hosts, host_name)
                host_ok = true
            catch e
                print_progress_err("✗")
                writeln_both("")
                if e isa CompositeException
                    for (i, ex) in enumerate(e.exceptions)
                        actual_ex = ex isa TaskFailedException ? ex.task.result : ex
                        writeln_both("    Error $i: $(typeof(actual_ex))")
                        msg = sprint(showerror, actual_ex)
                        first_line = first(split(msg, '\n'))
                        writeln_both("    $first_line")
                    end
                else
                    writeln_both("    $(sprint(showerror, e))")
                end
            end
        finally
            DistSSHRun._drive_host_span!(host_name, "workers", host_ok ? :ok : :fail)
        end
    end

    writeln_both("")
    writeln_field("Workers", string(nworkers()))
    writeln_both("")

    # Alone, Julia reports nworkers()==1 (the master). Fail when nothing joined.
    nprocs() <= 1 && error(_NO_WORKERS_JOINED)
    try
        DistSSHRun.verify_workers_match_job!(
            proj_dir;
            allow = DistSSHRun._ALLOW_MISMATCH[],
            host_manifests = host_manifests,
        )
    catch
        DistSSHRun._rmprocs_added_since(before_all)
        rethrow()
    end

    return successful_hosts
end

function wait_for_worker_connections!(; ssh::Bool = true)
    _init_delay = DistSSHRun._drive_init_delay_sec(; ssh = ssh)
    return if _init_delay > 0
        label = "Waiting for worker connections ($(round(_init_delay, digits = 1))s)... "
        DistSSHRun.kit_spin!(label) do
            sleep(_init_delay)
            return nothing
        end
        print_ok("✓")
        writeln_both("")
    end
end

# A yielding worker task observed `InterruptException` about 2s after the
# signal (Julia 1.13.2, local `remotecall`). On Julia 1.14, with
# `exit_on_sigint(false)`, `sleep` throws `Base.CancellationRequest`, and a
# later wait throws again while that request stays raised. Wait so user code
# can `catch` it and save a small amount of state before `rmprocs`.
# Not a public setting. `DistSSHBase.is_sigint` is `public` and not exported.
# The window is fixed. A write here is best-effort. Large state belongs in
# an incremental checkpoint (temporary file, then rename) during the run.
const _INTERRUPT_SETTLE_S = 3.0

# Let the heartbeat task leave before `rmprocs`. Not a public setting.
const _HEARTBEAT_STOP_S = 0.5

# `rmprocs` `waitfor` when a drive run stops. Not a public setting.
const _RMPROCS_WAITFOR_S = 5.0

# Wall clock for parallel `kill -INT` ssh. The same number as SSH
# `ConnectTimeout`, so a slow handshake cannot outlive that budget.
const _INTERRUPT_SSH_PHASE_S = Float64(DistSSHBase._SSH_CONNECT_TIMEOUT_S)

"""
    _group_interrupt_targets(rows) -> (local_pids, ssh, fallback)

`rows` is `(pid, endpoint)`. `endpoint` is `:local`, `nothing` (use
`Distributed.interrupt` for that pid), or `(host, ospid)` for one SSH worker.
SSH workers on the same host share one OS signal.
"""
function _group_interrupt_targets(rows)
    local_pids = Int[]
    fallback = Int[]
    ssh = Dict{String, Vector{Int}}()
    for (pid, endpoint) in rows
        if endpoint === :local
            push!(local_pids, Int(pid))
        elseif endpoint === nothing
            push!(fallback, Int(pid))
        else
            host, ospid = endpoint
            push!(get!(ssh, String(host), Int[]), Int(ospid))
        end
    end
    return (local_pids = local_pids, ssh = ssh, fallback = fallback)
end

"""`:local`, `(host, ospid)`, or `nothing` when the worker record cannot be used.

`nothing` means the caller must use `Distributed.interrupt` for that pid.
Reads `WorkerConfig.host` and `WorkerConfig.ospid` as documented for
`SSHManager`. A missing or renamed field falls back instead of guessing.
"""
function _interrupt_endpoint(pid::Integer)
    try
        w = Distributed.map_pid_wrkr[Int(pid)]
        w isa Distributed.Worker || return nothing
        if w.manager isa Distributed.LocalManager
            return :local
        end
        if w.manager isa Distributed.SSHManager
            host = w.config.host
            ospid = w.config.ospid
            if host isa AbstractString && !isempty(host) && ospid isa Integer && ospid > 0
                return (String(host), Int(ospid))
            end
        end
    catch
    end
    return nothing
end

"""Remote `kill -INT` text for julia pids on one host.

`ospids` are `WorkerConfig.ospid`. The worker reports `getpid()` in
`JoinCompleteMsg` after `SSHManager` `exec`s julia, so the signal names
that julia process, not sshd or the login shell.
"""
function _interrupt_kill_shell(ospids::Vector{Int})::String
    return String("kill -INT " * join(string.(ospids), " ") * " || true")
end

"""One bounded `kill -INT` ssh per host. A failure is logged, not thrown."""
function _interrupt_ssh_phase!(ssh::AbstractDict{<:AbstractString, <:AbstractVector{Int}})
    pairs = Pair{String, String}[]
    for (host, ospids) in ssh
        isempty(ospids) && continue
        push!(pairs, String(host) => _interrupt_kill_shell(Int[Int(pid) for pid in ospids]))
    end
    isempty(pairs) && return nothing
    results = _run_ssh_hosts!(pairs, _INTERRUPT_SSH_PHASE_S)
    for result in results
        _ssh_phase_exit_code(result) == 0 && continue
        @error "Error sending a Ctrl-C to workers on $(result.host)"
    end
    return nothing
end

"""
Send SIGINT to `pids`, one SSH connection per host, then wait
[`_INTERRUPT_SETTLE_S`](@ref).

Local workers and any worker whose OS pid is not known use
`Distributed.interrupt`. SSH workers on one host share one `kill -INT`.
That ssh is bounded by [`_INTERRUPT_SSH_PHASE_S`](@ref) and capped at
`_SSH_PHASE_CONCURRENCY` so a slow host cannot hold the rest open.
"""
function _interrupt_workers_grouped(pids)
    rows = [(Int(pid), _interrupt_endpoint(pid)) for pid in pids]
    groups = _group_interrupt_targets(rows)
    local_tasks = Task[]
    if !isempty(groups.local_pids)
        local_pids = groups.local_pids
        push!(
            local_tasks, @async try
                interrupt(local_pids)
            catch
            end
        )
    end
    if !isempty(groups.fallback)
        fallback = groups.fallback
        push!(
            local_tasks, @async try
                interrupt(fallback)
            catch
            end
        )
    end
    _interrupt_ssh_phase!(groups.ssh)
    isempty(local_tasks) ||
        timedwait(() -> all(istaskdone, local_tasks), 1.0; pollint = 0.05)
    isempty(pids) || sleep(_INTERRUPT_SETTLE_S)
    return nothing
end

"""SIGINT in-flight `pmap` work on workers before `rmprocs`."""
const INTERRUPT_DRIVE_WORKERS = Ref{Function}(_interrupt_workers_grouped)

function _interrupt_drive_workers!(pids = workers())
    nprocs() <= 1 && return nothing
    isempty(pids) && return nothing
    try
        INTERRUPT_DRIVE_WORKERS[](pids)
    catch
    end
    return nothing
end

function register_worker_cleanup!(successful_hosts::Vector{String})
    cleanup_registered = Ref(false)
    function drive_atexit_cleanup()
        cleanup_registered[] && return
        cleanup_registered[] = true

        # Alone, Julia reports nworkers()==1 and workers()==[1] (the driver).
        # nworkers() > 0 would rmprocs([1]) and warn "process 1 not removed".
        if nprocs() > 1
            try
                @everywhere stop_heartbeat_monitor()
                sleep(_HEARTBEAT_STOP_S)
            catch
            end
        end

        if nprocs() > 1
            try
                rmprocs(workers(); waitfor = _RMPROCS_WAITFOR_S)
            catch
            end
        end

        for host in successful_hosts
            job_id = DistSSHRun.resolved_kit_job_id()
            job_id === nothing && continue
            DistSSHRun._pkill_remote_tagged_workers!(host, job_id)
        end
        return
    end
    atexit(drive_atexit_cleanup)
    return drive_atexit_cleanup
end
