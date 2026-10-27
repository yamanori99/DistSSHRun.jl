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

    if parent_workers > 0
        write_both("  $(DistSSHRun.PARENT_HOST_NAME) ($parent_workers workers): ")
        DistSSHRun._drive_host_span!(DistSSHRun.PARENT_HOST_NAME, "workers", :running)
        try
            before = Set(workers())
            addprocs(
                parent_workers;
                exeflags = DistSSHRun._drive_worker_exeflags(proj_dir),
                env = DistSSHRun._drive_worker_env(),
                topology = :master_worker
            )
            _register_drive_workers!(before, proj_dir, script_path)
            DistSSHRun._register_drive_host_worker_ids!(
                DistSSHRun.PARENT_HOST_NAME,
                sort!(Int[w for w in workers() if w ∉ before]),
            )
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
            host_julia = julia_exe
            if host_julia === nothing
                write_both("  $host_name: detecting Julia... ")
                host_julia = try
                    detect_julia_path(host_name)
                catch e
                    e isa ArgumentError || rethrow()
                    print_progress_err("✗ ($(e.msg))")
                    writeln_both("")
                    continue
                end
                if host_julia === nothing
                    print_progress_err("✗ (Julia not found)")
                    writeln_both("")
                    continue
                end
                print_info("found at $host_julia")
                writeln_both("")
                write_both("  ")
            end

            host_workers = something(host_workers_spec, default_workers, 1)

            repo_ra = canonical_local_path(project_root)
            script_dir = dirname(script_path)
            remote_dir = resolve_host_path_abs(host_name, script_dir, repo_ra)
            remote_proj = resolve_host_path_abs(host_name, proj_dir, repo_ra)
            remote_script = resolve_host_path_abs(host_name, script_path, repo_ra)
            if remote_dir === nothing || remote_proj === nothing || remote_script === nothing
                write_both("$host_name ($host_workers workers): ")
                missing = remote_dir === nothing ? remote_layout_path(script_dir, repo_ra) :
                    remote_proj === nothing ? remote_layout_path(proj_dir, repo_ra) :
                    remote_layout_path(script_path, repo_ra)
                print_progress_err("✗ (remote path not found: $missing)")
                writeln_both("")
                writeln_both("    hint: julia --project=. -m DistSSHKit setup --rsync $(setup_cli_host_token(host_name))")
                writeln_both("          julia --project=. -m DistSSHKit setup --instantiate $(setup_cli_host_token(host_name))")
                writeln_both("          or drive --rsync onto an empty path (instantiates missing deps)")
                writeln_both("           or export DISTRIBUTED_REMOTE_PROJECT_ROOT=<abs path on host>")
                continue
            end

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
                use_tunnel = get(ENV, "DISTSSHKIT_SSH_TUNNEL", "1") != "0"
                machine = DistSSHRun.ssh_addprocs_machine(host_name)
                addprocs(
                    [(machine, host_workers)];
                    exename = `$host_julia`,
                    sshflags = sshflags_cmd,
                    dir = remote_dir,
                    tunnel = use_tunnel,
                    topology = :master_worker,
                    env = DistSSHRun._drive_worker_env(),
                    exeflags = DistSSHRun._drive_worker_exeflags(remote_proj)
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
    nprocs() <= 1 && error("No workers available. Check SSH connectivity.")

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
# can catch that exception and save state before `rmprocs`.
# `DistSSHBase.is_sigint` is `public` and not exported. Not a public setting.
const _INTERRUPT_SETTLE_S = 3.0

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

"""One `kill -INT` for every OS pid on `host`. Connection failure is logged, not thrown."""
function _signal_ssh_interrupt(host::String, ospids::Vector{Int})
    isempty(ospids) && return nothing
    # `*` of strings is `Union{String, AnnotatedString}`. `String` keeps the
    # shell text concrete for `_host_sync_remote_shell_cmd(::String, ::String)`.
    inner = String("kill -INT " * join(string.(ospids), " ") * " || true")
    try
        run(
            pipeline(
                _host_sync_remote_shell_cmd(host, inner);
                stdout = devnull,
                stderr = devnull,
            )
        )
    catch e
        _rethrow_missing_host_tool(e)
        @error "Error sending a Ctrl-C to workers on $host"
    end
    return nothing
end

"""
Send SIGINT to `pids`, one SSH connection per host, then wait
[`_INTERRUPT_SETTLE_S`](@ref).

Local workers and any worker whose OS pid is not known use
`Distributed.interrupt`. `Distributed.SSHManager` otherwise opens one `ssh`
per worker (`kill -2`), which `sshd` `MaxStartups` drops once a host has
many workers.
"""
function _interrupt_workers_grouped(pids)
    rows = [(Int(pid), _interrupt_endpoint(pid)) for pid in pids]
    groups = _group_interrupt_targets(rows)
    @sync begin
        if !isempty(groups.local_pids)
            @async try
                interrupt(groups.local_pids)
            catch
            end
        end
        if !isempty(groups.fallback)
            @async try
                interrupt(groups.fallback)
            catch
            end
        end
        for (host, ospids) in groups.ssh
            @async _signal_ssh_interrupt(host, ospids)
        end
    end
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
                sleep(0.5)
            catch
            end
        end

        if nprocs() > 1
            try
                rmprocs(workers(); waitfor = 5.0)
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
