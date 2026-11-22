# Core drive execution after argv parse (shared by CLI `drive_main` and API `drive!`).

# Driver hooks and the argument types the kit calls them with.
# `include` leaves each hook defined in `Main`. A later in-process `drive!` whose
# script does not define a hook must not run the previous driver's method.
# Every hook is looked up and called only through the functions below; the
# `drive-hooks` lint rejects other `Main` access under the drive sources.
_drive_script_hook_signatures(script_args) = (
    init_output_dir! = Tuple{typeof(script_args)},
    prepare_workers! = Tuple{},
    main = Tuple{},
)

# The bound value and the method it would call. Closure instances of one type
# share a `Method`, so `main = make_main(path)` is a change only in the value.
# Lookup is `invokelatest`: after `include` the binding's world is newer than
# this method, and Julia 1.12+ warns (later errors) on a stale read.
function _drive_hook_binding(name::Symbol, argtypes::Type{<:Tuple})::Union{Nothing, Tuple{Function, Method}}
    return Base.invokelatest() do
        isdefined(Main, name) || return nothing
        hook = getfield(Main, name)
        hook isa Function || return nothing
        applicable = methods(hook, argtypes)
        return isempty(applicable) ? nothing : (hook, first(applicable)::Method)
    end
end

function _drive_script_hook_bindings(script_args)
    sigs = _drive_script_hook_signatures(script_args)
    return NamedTuple{keys(sigs)}(map(_drive_hook_binding, keys(sigs), values(sigs)))
end

"""
Methods of the hooks this script's `include` added or replaced. Each other hook is `nothing`.
Assigning a value `===` to the one already bound is not a change.
"""
function _drive_script_hooks(before::NamedTuple, after::NamedTuple)::NamedTuple
    return map((b, a) -> a === nothing || a === b ? nothing : last(a), before, after)
end

Base.@constprop :none function _call_drive_script_hook(name::Symbol, args...)
    return Base.invokelatest() do
        hook = getfield(Main, name)
        return Base.invokelatest(Base.inferencebarrier(hook), args...)
    end
end

function _call_drive_script_hook_on_workers(name::Symbol)
    return _drive_eval_workers(:(Base.invokelatest(getfield(Main, $(QuoteNode(name))))))
end

# Set before any in-process drive `Base.include(Main, script)`. It stays set on success or throw.
const _DRIVE_MAIN_DRIVER_INCLUDED = Ref(false)

function _drive_main_driver_included()::Bool
    return _DRIVE_MAIN_DRIVER_INCLUDED[]
end

function _set_drive_main_driver_included!()
    _DRIVE_MAIN_DRIVER_INCLUDED[] = true
    return nothing
end

function _reject_second_drive_main_include!(reuse_main::Bool)
    _drive_main_driver_included() || return nothing
    reuse_main && return nothing
    throw(ArgumentError(drive_reuse_main_required_message()))
end

"""CLI parses omit `:reuse_main` and keep including. The API field `false` does not."""
function _drive_reuse_main_opt_in(parsed)::Bool
    hasproperty(parsed, :reuse_main) || return true
    return getproperty(parsed, :reuse_main) === true
end

# Options that take the next argv word. A word equal to `--isolated` there is a value.
const _DRIVE_VALUE_FLAGS = (
    "--workers", "-w", "--julia",
    "--log-dir", "--output-dir", "--package", "--hosts", "--hosts-file",
    "--ship-id", "--deploy-root",
)

"""Index of the drive `--isolated` option in already-peeled argv, or `nothing`."""
function _peeled_isolated_option(peeled::AbstractVector{<:AbstractString})::Union{Nothing, Int}
    i = 1
    n = length(peeled)
    while i <= n
        arg = String(peeled[i])
        endswith(arg, ".jl") && return nothing
        if arg in _DRIVE_VALUE_FLAGS
            i += 2
            continue
        end
        arg == "--isolated" && return i
        i += 1
    end
    return nothing
end

"""Raw index of peeled index `peeled_index`. Shared flags are absent from the peeled argv."""
function _raw_index_for_peeled(raw::AbstractVector{<:AbstractString}, peeled_index::Int)::Int
    p = 0
    i = 1
    n = length(raw)
    while i <= n
        arg = String(raw[i])
        if _shared_bare_cli_flag(arg)
            i += 1
            continue
        end
        if _shared_valued_cli_flag(arg)
            i += i < n ? 2 : 1
            continue
        end
        p += 1
        p == peeled_index && return i
        i += 1
    end
    return peeled_index
end

"""Drop the drive `--isolated` option. Keep that word after the driver script, and as a flag value."""
function _drive_isolated_child_args(original_args::AbstractVector{<:AbstractString})::Vector{String}
    raw = String[String(a) for a in original_args]
    _, peeled = peel_shared_cli_flags(raw)
    drop_at = _peeled_isolated_option(peeled)
    drop_at === nothing && return raw
    deleteat!(raw, _raw_index_for_peeled(raw, drop_at))
    return raw
end

function _isolated_child_load_path()::String
    sep = Sys.iswindows() ? ";" : ":"
    parts = String[]
    for entry in LOAD_PATH
        entry isa AbstractString || continue
        s = String(entry)
        (isempty(s) || s in parts) && continue
        push!(parts, s)
    end
    d = pkgdir(@__MODULE__)
    if d !== nothing && !isempty(d) && !(d in parts)
        push!(parts, d)
    end
    return join(parts, sep)
end

function _isolated_project_flag()::Union{Nothing, String}
    ap = Base.active_project()
    ap === nothing && return nothing
    dir = dirname(String(ap))
    isempty(dir) && return nothing
    return "--project=$(dir)"
end

"""`Int64(x)` when `x` is an integer in `Int64` range; else `nothing` (no silent wrap)."""
function _status_int64(x)::Union{Int64, Nothing}
    x isa Bool && return nothing
    x isa Integer || return nothing
    if x isa Unsigned && big(x) > typemax(Int64)
        return nothing
    end
    try
        return Int64(x)
    catch
        return nothing
    end
end

"""Fit `code` in `Cint`. A Windows crash code such as `0xC0000005` does not."""
function _as_cint(code::Integer)::Cint
    n = _status_int64(code)
    n === nothing && return Cint(1)
    lo = Int64(typemin(Cint))
    hi = Int64(typemax(Cint))
    lo <= n <= hi && return Cint(n)
    return Cint(1)
end

"""A signalled child is a failure. Unix can report `exitcode == 0` with a nonzero `termsignal`."""
function _drive_child_status(exitcode, termsignal)::Cint
    if termsignal isa Integer && !(termsignal isa Bool)
        sig = _status_int64(termsignal)
        sig === nothing && return Cint(1)
        if sig > 0
            sig > 127 && return Cint(1)
            sig > typemax(Int64) - 128 && return Cint(1)
            # `shell_status` owns `128 + signal`. This path has no `Process`.
            return _as_cint(DistSSHBase._shell_status(zero(Int64), sig))
        elseif sig != 0
            return Cint(1)
        end
    elseif termsignal !== nothing && termsignal !== 0
        return Cint(1)
    end
    if exitcode isa Integer && !(exitcode isa Bool)
        return _as_cint(exitcode)
    end
    return Cint(1)
end

# Child `julia` that runs the same drive arguments without the drive `--isolated` option.
function _drive_isolated_cmd(
        original_args::AbstractVector{<:AbstractString};
        project_root::Union{Nothing, AbstractString} = nothing,
        drop_env::Vector{String} = String[],
    )::Cmd
    child = _drive_isolated_child_args(original_args)
    script = "using DistSSHRun; exit(Int(DistSSHRun.run_drive_parsed!(DistSSHRun.parse_drive_args(String[ARGS...]); original_args=String[ARGS...])))"
    argv = String[]
    append!(argv, Base.julia_cmd().exec)
    push!(argv, "--startup-file=no")
    proj = _isolated_project_flag()
    proj === nothing || push!(argv, proj)
    push!(argv, "-e", script, "--")
    append!(argv, child)
    pairs = Pair{String, String}["JULIA_LOAD_PATH" => _isolated_child_load_path()]
    if project_root !== nothing
        root = strip(String(project_root))
        isempty(root) || push!(pairs, "DISTSSH_PROJECT_ROOT" => root)
    end
    cmd = addenv(Cmd(argv), pairs...)
    isempty(drop_env) && return cmd
    return addenv(cmd, (String(key) => nothing for key in drop_env)...)
end

"""SIGINT the child, then wait until it exits. A second interrupt still uses the drive handler."""
function _forward_isolated_interrupt!(proc::Base.Process)
    if process_running(proc)
        try
            kill(proc, Base.SIGINT)
        catch
        end
    end
    try
        wait(proc)
    catch
    end
    return nothing
end

function _drive_isolated_process(
        original_args::AbstractVector{<:AbstractString},
        project_root::Union{Nothing, AbstractString} = nothing;
        drop_env::Vector{String} = String[],
    )::Cint
    proc = run(
        ignorestatus(
            _drive_isolated_cmd(
                original_args;
                project_root = project_root,
                drop_env = drop_env,
            )
        );
        wait = false,
    )
    try
        wait(proc)
    catch e
        if is_sigint(e) || _is_cancellation_request(e)
            _forward_isolated_interrupt!(proc)
        end
        rethrow()
    end
    return _drive_child_status(proc.exitcode, proc.termsignal)
end

"""
    run_drive_parsed!(parsed; original_args=String[], resolved_output_dir=nothing, resolved_log_dir=nothing) -> Cint

Run a driver from a `parse_drive_args`-shaped NamedTuple. Mutates `ARGS` to
`script_args` while the driver runs; callers should restore `ARGS` in `finally`.

`resolved_output_dir` / `resolved_log_dir` are optional `Ref{Union{Nothing,String}}`
out-params: when a real run happens (script found, past argv-only branches),
they are filled with the directory actually used — `resolve_drive_output_dir`
(same value `collect_drive_results!` reports as `Results:`) and
`resolve_drive_log_dir` (same value `init_log_file` writes to) respectively.
Callers (`drive!`) use these to report an accurate `DriveResult.output_dir` /
`.log_dir` even when the caller did not pass `output_dir=` / `log_dir=` explicitly.
"""
function run_drive_parsed!(
        parsed;
        original_args::Vector{String} = String[],
        resolved_output_dir::Union{Nothing, Base.RefValue{Union{Nothing, String}}} = nothing,
        resolved_log_dir::Union{Nothing, Base.RefValue{Union{Nothing, String}}} = nothing,
        resolved_hosts::Union{Nothing, Base.RefValue{Vector{HostRunResult}}} = nothing,
        resolved_run_dir::Union{Nothing, Base.RefValue{Union{Nothing, String}}} = nothing,
        project_root::Union{Nothing, AbstractString} = nothing,
    )::Cint
    # `drive!` builds the same field as `parse_drive_args` (`false`). A missing
    # key stays in this process. `get` does not read a field the tuple lacks.
    if get(parsed, :isolated, false) === true
        return _drive_isolated_process(
            original_args,
            project_root;
            drop_env = _isolated_api_env_drops(parsed),
        )
    end
    # `parse_drive_args` is inferred as one NamedTuple whose fields are unions.
    # CLI `drive_main` already opened the frame (`cli=true`). A direct call,
    # including `drive!`, opens it here when none is active (`cli=false`).
    pe = parsed.cli_session.process_env
    return with_kit_invocation_env!(pe) do
        cfg = resolve_run_job_config_from_parsed(parsed; command = :drive)
        return with_run_unsafe_options!(cfg) do
            return _drive_frame(; cli = false) do
                return Base.invokelatest(
                    _run_drive_parsed_specialized!,
                    parsed,
                    original_args,
                    resolved_output_dir,
                    resolved_log_dir,
                    resolved_hosts,
                    resolved_run_dir,
                    project_root,
                )
            end
        end
    end
end

function _run_drive_parsed_specialized!(
        parsed,
        original_args,
        resolved_output_dir,
        resolved_log_dir,
        resolved_hosts,
        resolved_run_dir,
        project_root,
    )::Cint
    if parsed.help
        return DistSSHRun.DistSSHBase.cli_help_stdout(show_drive_usage)
    end

    if parsed.show_version
        DistSSHRun.println_kit_version()
        return 0
    end

    project = something(project_root, get(ENV, "DISTSSH_PROJECT_ROOT", pwd()))
    let diag = finish_run_job_diagnostics!(
            parsed;
            command = :drive,
            project = project,
            hosts = String[first(h) for h in parsed.hosts],
            worker_tokens = host_tokens(parsed; kind = :drive),
        )
        diag !== nothing && return Cint(diag)
    end

    if parsed.collect_root !== nothing && parsed.collect_hosts !== nothing
        apply_shared_cli_flags!(parsed.cli_session)
        root = canonical_local_path(
            something(project_root, get(ENV, "DISTSSH_PROJECT_ROOT", pwd())),
        )
        collect_opts = collect_job_options_from_parsed(parsed)
        session = DistSSHSession(
            project = root,
            workers = String[],
            remote = collect_opts.remote_root,
            quiet = parsed.cli_session.quiet,
            verbosity = parsed.cli_session.verbosity,
        )
        session.cli_session = parsed.cli_session
        apply_shared_cli_flags!(session.cli_session)
        return _with_kit_inproc_run!(:collect) do
            result = collect!(
                session,
                parsed.collect_root::String;
                merge = collect_opts.merge,
                best_effort = collect_opts.best_effort,
                hosts = parsed.collect_hosts::Vector{String},
                julia = collect_opts.julia,
                ship_id = collect_opts.ship_id,
                remote_root = collect_opts.remote_root,
            )
            return result.ok ? 0 : 1
        end
    end

    if parsed.script_path === nothing
        return DistSSHRun.DistSSHBase.cli_required_else_help(show_drive_usage)
    end

    hosts = parsed.hosts
    raw_script = String(parsed.script_path)::String
    remote_argv = DistSSHRun._remote_script_argv(raw_script)
    script_path = remote_argv ? raw_script : DistSSHRun.canonical_local_path(raw_script)
    script_args = parsed.script_args
    head_workers = parsed.head_workers
    default_workers = parsed.default_workers
    julia_exe = parsed.julia
    skip_hash_check = parsed.skip_hash_check
    enable_log = parsed.enable_log
    log_dir = parsed.log_dir
    output_dir = parsed.output_dir
    explicit_package = parsed.explicit_package
    best_effort = parsed.best_effort::Bool

    host_names = [h[1] for h in hosts]

    snap_for_script = get(parsed, :ship_id, nothing)
    if !isfile(script_path) && !(remote_argv && snap_for_script !== nothing)
        surface = hasproperty(parsed, :hint_surface) ? parsed.hint_surface::Symbol : :cli
        root0 = canonical_local_path(something(project_root, dirname(script_path)))
        throw(ArgumentError(drive_script_not_found_message(script_path, root0; surface = surface)))
    end

    root_hint = project_root === nothing ? nothing : canonical_local_path(project_root)
    outside_snapshot = root_hint !== nothing &&
        snap_for_script !== nothing &&
        !DistSSHRun._script_inside_project(root_hint, script_path)
    script_dir = if remote_argv || outside_snapshot
        canonical_local_path(something(root_hint, pwd()))
    else
        dirname(script_path)
    end
    proj_dir = resolve_pkg_project_dir(script_dir)
    project_root_abs = canonical_local_path(something(project_root, proj_dir))
    path_anchor = canonical_local_path(project_root_abs)
    DistSSHRun._acquire_kit_inproc_run!(:drive)
    old_run = get(ENV, DistSSHRun.DISTSSH_RUN_DIR_ENV, nothing)
    run_dir = DistSSHRun._ensure_kit_run_dir!(
        :drive, script_path; project = proj_dir,
    )
    resolved_run_dir isa Base.RefValue && (resolved_run_dir[] = run_dir)
    return try
        DistSSHRun._reset_run_provenance!(project_root_abs)
        DistSSHRun._clear_active_selection!()
        DistSSHRun._clear_active_deploy_record_unless_ship_id!(snap_for_script)
        # Inside `_drive_frame`: this `finally` restores after `rmprocs`.
        return _with_drive_process!(proj_dir) do
            local release_output_dir_lock
            code = Cint(1)
            hosts_acc = resolved_hosts === nothing ?
                Ref{Vector{HostRunResult}}(HostRunResult[]) :
                resolved_hosts
            if output_dir !== nothing
                ENV["DISTSSH_OUTPUT_DIR"] = DistSSHRun.canonical_local_path(String(output_dir))
            end
            # Drivers may set `DISTSSH_OUTPUT_DIR` in `init_output_dir!` (demos: `output/`).
            # If still unset, kit allocates `{script}/.distssh/drive/<stem>_<UTC>/`.
            # Lock after that so `.kit.lock` is not the kind root when the driver
            # chose `output/` (or `--output-dir` / a unique batch dir).
            hooks_before = _drive_script_hook_bindings(script_args)
            _reject_second_drive_main_include!(_drive_reuse_main_opt_in(parsed))
            _set_drive_main_driver_included!()
            Base.include(Main, script_path)
            script_hooks = _drive_script_hooks(hooks_before, _drive_script_hook_bindings(script_args))
            if script_hooks.init_output_dir! !== nothing
                _call_drive_script_hook(:init_output_dir!, script_args)
            end
            DistSSHRun._ensure_drive_output_env!(script_path; project = proj_dir)
            out_ready = DistSSHRun._prepare_output_dir!(
                DistSSHRun.resolve_drive_output_dir(script_dir);
                command = :drive,
                surface = hasproperty(parsed, :hint_surface) ? parsed.hint_surface::Symbol : :cli,
                allow_parent_sidecars = old_run isa AbstractString && !isempty(strip(old_run)),
            )
            ENV["DISTSSH_OUTPUT_DIR"] = out_ready
            release_output_dir_lock = DistSSHRun.kit_output_dir_lock!(out_ready)
            try
                code = _run_drive_parsed_locked!(
                    parsed, output_dir, script_path, script_dir, proj_dir, script_args,
                    enable_log, log_dir, original_args, host_names, hosts, head_workers,
                    default_workers, julia_exe, skip_hash_check, explicit_package,
                    best_effort, resolved_output_dir, resolved_log_dir, hosts_acc,
                    project_root_abs, path_anchor; script_hooks,
                )
                return code
            finally
                # The locked body throws before it can return 130. The result
                # file is what `cancel!` reads.
                _drive_was_interrupted() && (code = Cint(130))
                out = DistSSHRun.resolve_drive_output_dir(script_dir)
                log = enable_log ? DistSSHRun.resolve_drive_log_dir(log_dir, script_dir) : nothing
                result = DistSSHRun.DistSSHJobResult(
                    code == 0,
                    :drive,
                    out,
                    log,
                    code == 0 ? nothing : "drive",
                    Int(code),
                    hosts_acc[],
                    DistSSHRun.resolved_placement_tokens(head_workers, hosts, default_workers);
                    run_dir = run_dir,
                )
                DistSSHRun._write_kit_result_file(result)
                DistSSHRun.note_controller_shipped_tree_drift!(project_root_abs)
                DistSSHRun.write_kit_run_toml!(
                    run_dir;
                    kind = :drive,
                    output_dir = out,
                    log_dir = log,
                    result = result,
                    project_root = project_root_abs,
                    provenance = DistSSHRun.assemble_provenance(),
                )
                DistSSHRun._remove_kit_pid_file(
                    getpid(),
                    out,
                    log;
                    run_dir = run_dir,
                )
                release_output_dir_lock()
            end
        end
    finally
        DistSSHRun._restore_kit_run_dir_env!(old_run)
        DistSSHRun._release_kit_inproc_run!()
    end
end

# Process-global slots a drive frame writes. Empty string is a value; absence is `nothing`.
const _DRIVE_PROCESS_ENV = (
    "DISTSSH_PROJECT_ROOT",
    "DISTSSH_REMOTE_PROJECT_ROOT",
    "DISTSSH_OUTPUT_DIR",
    "DISTSSH_INTERNAL_RUNNER",
)

"""
    _with_drive_process!(f, proj_dir)

Run `f` with the drive project active. On the way out, put back the raw
`Base.ACTIVE_PROJECT[]` slot (so `nothing` round-trips) and each
`_DRIVE_PROCESS_ENV` entry (delete when it was absent).

Restore is idempotent and runs from `finally`, including throw.
Each slot is its own `try`, so one failure does not skip the rest.
`main` calls `exit` only after this returns.
"""
function _with_drive_process!(f, proj_dir::AbstractString)
    prev_active = Base.ACTIVE_PROJECT[]
    prev_env = Vector{Union{Nothing, String}}(undef, length(_DRIVE_PROCESS_ENV))
    for (i, key) in enumerate(_DRIVE_PROCESS_ENV)
        prev_env[i] = get(ENV, key, nothing)
    end
    restored = Ref(false)
    function restore_drive_process!()
        restored[] && return nothing
        restored[] = true
        try
            Base.ACTIVE_PROJECT[] = prev_active
        catch
        end
        for (i, key) in enumerate(_DRIVE_PROCESS_ENV)
            try
                old = prev_env[i]
                if old === nothing
                    delete!(ENV, key)
                else
                    ENV[key] = old
                end
            catch
            end
        end
        return nothing
    end
    activate_drive_project!(String(proj_dir))
    try
        return f()
    finally
        restore_drive_process!()
    end
end

"""True for the error `add_drive_workers!` raises when nothing joined."""
function _drive_no_workers_joined(e)::Bool
    return e isa ErrorException && e.msg == _NO_WORKERS_JOINED
end

"""
Write the planned SSH hosts, run `join`, then keep only hosts that joined.

`join` is `add_drive_workers!` and returns the SSH names that joined.
An empty list removes `kit.hosts`. The same removal runs when `join` throws
the no-worker error after that loop. An interrupt, or any other error,
leaves the planned list so `cancel!` can reap workers that may already
be running.
"""
function _drive_kit_hosts_around_join!(
        join::Function,
        hosts::Vector{Tuple{String, Union{Int, Nothing}}},
        output_dir::AbstractString,
        log_dir::Union{Nothing, AbstractString},
    )::Vector{String}
    _write_kit_hosts_file(String[String(pair[1]) for pair in hosts], output_dir, log_dir)
    local joined::Vector{String}
    try
        joined = join()::Vector{String}
    catch e
        if !_interruptish(e) && _drive_no_workers_joined(e)
            _remove_kit_hosts_file(output_dir, log_dir)
        end
        rethrow()
    end
    if isempty(joined)
        _remove_kit_hosts_file(output_dir, log_dir)
    else
        _write_kit_hosts_file(joined, output_dir, log_dir)
    end
    return joined
end

function _run_drive_parsed_locked!(
        parsed, _output_dir, script_path, script_dir, proj_dir, script_args,
        enable_log, log_dir, original_args, host_names, hosts, head_workers,
        default_workers, julia_exe, skip_hash_check, explicit_package,
        best_effort, resolved_output_dir, resolved_log_dir, resolved_hosts,
        project_root, path_anchor;
        script_hooks::NamedTuple,
    )::Cint
    DistSSHRun.assert_loaded_verified_worker_set!()
    if enable_log
        init_log_file(resolve_drive_log_dir(log_dir, script_dir); prefix = "drive", path_anchor = path_anchor)
    end

    writeln_field("Subcommand args", subcommand_args_record("drive", original_args))
    for (label, value) in julia_env_record()
        writeln_field(label, value)
    end
    writeln_both("")

    print_header(cli_heading("drive"))
    writeln_both("")
    writeln_field("Script", display_path(script_path, path_anchor))
    writeln_field("Args", isempty(script_args) ? "—" : join(script_args, " "))
    writeln_field("Project", cli_project_disp(proj_dir, path_anchor))
    writeln_field("DistSSHRun", dist_ssh_kit_version())
    app_git = get_local_git_hash(proj_dir; short = 8)
    writeln_field("App git", app_git === nothing ? "unavailable" : app_git)
    hb_self_exit = if hasproperty(parsed, :unsafe_master_silence_exit)
        getfield(parsed, :unsafe_master_silence_exit)
    else
        missing
    end
    pe = parsed.cli_session.process_env
    heartbeat_policy = if hb_self_exit === missing
        resolve_drive_heartbeat_policy(env = pe)
    else
        resolve_drive_heartbeat_policy(env = pe, self_exit = hb_self_exit)
    end
    record_heartbeat_provenance!(heartbeat_policy)
    write_heartbeat_startup_summary!(heartbeat_policy)
    writeln_both("")

    remote_argv = DistSSHRun._remote_script_argv(script_path)
    DistSSHRun._reject_script_outside_project_run!(
        "drive",
        proj_dir,
        script_path;
        ship_id = get(parsed, :ship_id, nothing),
        remote_argv = remote_argv,
    )
    snap_for_verify = get(parsed, :ship_id, nothing)
    if snap_for_verify isa AbstractString && !isempty(strip(snap_for_verify))
        DistSSHRun.assert_controller_environment_for_shipped_run!(proj_dir)
    else
        DistSSHRun.assert_controller_environment_for_verify!(proj_dir)
    end
    # git + cleanup + workers + wait + init + run + collect
    progress_steps = 7
    progress_ok = false
    # Set once `add_drive_workers!` returns (registers rmprocs-at-atexit for
    # whatever joined). `finally` below always calls it so local/SSH workers
    # from *this* run are torn down before `run_drive_parsed!` returns, not
    # just at Julia process exit — callers (`drive!`, `execute!`) can run more
    # than once per process (tests; long-lived services).
    drive_atexit_cleanup = nothing
    kit_out = DistSSHRun.resolve_drive_output_dir(script_dir)
    kit_log = enable_log ? DistSSHRun.resolve_drive_log_dir(log_dir, script_dir) : nothing
    DistSSHRun._set_kit_progress_sidecar!(kit_out)
    kit_progress_begin!("drive"; steps = progress_steps, kind = :drive)
    surface = parsed.cli_session.hint_surface
    bind_map_ref = Ref(Dict{String, String}())
    ssh_launch_plans_ref = Ref{Union{Nothing, Vector{HostLaunchPlan}}}(nothing)
    planned_ssh = String[h[1] for h in hosts]
    try
        bind_map_ref[] = hosts_file_bind_overrides(
            parsed.cli_session;
            bind_overrides = get(parsed, :bind_overrides, Dict{String, String}()),
            planned_hosts = planned_ssh,
            command = :drive,
        )
        if !isempty(planned_ssh)
            ssh_launch_plans_ref[] = validate_all_host_launch_plans!(planned_ssh, bind_map_ref[])
        end
    catch e
        e isa ArgumentError || rethrow()
        surface === :cli &&
            throw(DistSSHBase.CliUsageError(_bind_config_cli_message(e.msg)))
        rethrow()
    end
    try
        if !isempty(host_names)
            # Selection uses --ship-id / deploy record / git (setup deploys first).
            DistSSHRun._assign_remote_work_root_env!(
                host_names, project_root;
                cli_override = get(parsed, :deploy_root, nothing),
                ship_id = get(parsed, :ship_id, nothing),
            )
            deploy_root = DistSSHRun._resolved_deploy_root_for_work(
                proj_dir; cli_override = get(parsed, :deploy_root, nothing),
            )
            DistSSHRun.record_deploy_status_for_run!(
                host_names, deploy_root, proj_dir,
            )
        end

        kit_progress_step!("git")
        if !skip_hash_check
            if !local_git_clean(proj_dir)
                msg =
                    "⚠ Local working tree has uncommitted changes (this run may not match any git commit)"
                write_both("  ")
                print_warn(msg * "\n")
                println_fatal()
                println_fatal("  Omit --require-git to skip this check")
                println_fatal()
            end

            if !isempty(host_names)
                writeln_both("Checking git hashes (--require-git)..."; color = :light_black)
                ok, mismatches, unverifiable = check_git_hashes(host_names, project_root)
                writeln_both("")
                if !ok
                    # Fatal: always visible on the terminal (and kit log when open).
                    print_err("ERROR: "; bold = true)
                    if !isempty(mismatches)
                        println_fatal("Git hash mismatch on $(join(mismatches, ", "))")
                        println_fatal()
                        println_fatal("To re-deploy with git:")
                        println_fatal("  julia --project=. -m DistSSHKit setup git-sync $(join(setup_cli_host_token.(mismatches), " "))")
                        println_fatal()
                        println_fatal("Or re-deploy with ship-tree:")
                        println_fatal("  julia --project=. -m DistSSHKit setup ship-tree $(join(setup_cli_host_token.(mismatches), " "))")
                        println_fatal()
                    end
                    if !isempty(unverifiable)
                        println_fatal("Git commit could not be verified on $(join(unverifiable, ", "))")
                        println_fatal("(remote tree may lack .git/ — e.g. after `setup ship-tree`)")
                        println_fatal()
                        println_fatal("For ship-tree remotes, omit --require-git (the default).")
                        println_fatal()
                        println_fatal("Or use git-managed remotes:")
                        println_fatal("  julia --project=. -m DistSSHKit setup git-clone HOST ...")
                        println_fatal("  julia --project=. -m DistSSHKit setup git-sync HOST ...")
                        println_fatal()
                    end
                    println_fatal("Or omit --require-git and run without git parity.")
                    println_fatal()
                    return 1
                end
            end
        end

        ssh_preflight_hosts = String[String(h) for (h, _) in hosts]
        if !isempty(ssh_preflight_hosts)
            if !preflight_setup_ssh(ssh_preflight_hosts) && !best_effort
                writeln_both("")
                print_err("SSH preflight failed. Fix connectivity, then retry.\n")
                return 1
            end
        end

        kit_progress_step!("cleanup")
        cleanup_stale_workers!(hosts; env = pe)

        kit_progress_step!("workers")

        # Planned SSH names land in `kit.hosts` before `add_drive_workers!`.
        # A kill during join can still find those hosts. The list is replaced
        # with hosts that joined, or removed when none did.
        launch_report = Ref{Union{Nothing, LaunchReport}}(nothing)
        successful_hosts = try
            _drive_kit_hosts_around_join!(hosts, kit_out, kit_log) do
                hosts_joined, report = add_drive_workers!(
                    hosts, head_workers, default_workers, julia_exe, proj_dir, script_path,
                    project_root;
                    bind_overrides = bind_map_ref[],
                    launch_plans = ssh_launch_plans_ref[],
                    ship_id = get(parsed, :ship_id, nothing),
                )
                launch_report[] = report
                return hosts_joined
            end
        catch
            DistSSHRun.await_declared_input_hashes!()
            rethrow()
        end
        DistSSHRun.capture_worker_provenance!()
        # Register before the launch contract check below: that branch can
        # `return 1` with workers already joined, and `finally` must still
        # reach a non-`nothing` `drive_atexit_cleanup` to tear them down.
        drive_atexit_cleanup = register_worker_cleanup!(successful_hosts)
        DistSSHRun._write_joined_drive_host_status!(successful_hosts, kit_out, kit_log)
        if (rep = launch_report[]) !== nothing
            try
                enforce_launch_contract!(rep; best_effort)
            catch e
                e isa LaunchIncompleteError || rethrow()
                print_err("ERROR: "; bold = true)
                println_fatal(sprint(showerror, e))
                DistSSHRun.await_declared_input_hashes!()
                return 1
            end
        end
        kit_progress_step!("wait")
        wait_for_worker_connections!(; ssh = !isempty(hosts))

        kit_progress_step!("init")
        init_drive_workers!(proj_dir, explicit_package, path_anchor, heartbeat_policy)
        DistSSHRun._start_drive_host_status_monitor!(kit_out, kit_log)
        worker_include = get(parsed, :worker_include, false)
        sync_driver_to_workers!(script_path; worker_include = worker_include)
        script_hooks.prepare_workers! === nothing || run_prepare_workers!()

        empty!(ARGS)
        append!(ARGS, script_args)

        ENV["DISTSSH_INTERNAL_RUNNER"] = "1"
        skip_collect = DistSSHBase.env_flag("DISTSSH_SKIP_COLLECT", ENV; default = false)
        sentinel_placed = place_drive_sentinels!(
            successful_hosts, script_dir, skip_collect, project_root,
        )
        # Overlap is printed inside `place_drive_sentinels!`. Stop before `main`.
        if sentinel_placed === nothing
            return 1
        end
        sentinel_name = sentinel_placed::String

        kit_progress_step!("run")
        _drive_cancellable() do
            run_driver_script!(enable_log; script_main = script_hooks.main)
        end
        if !best_effort
            DistSSHRun._refresh_drive_host_status_file!(kit_out, kit_log)
            left = DistSSHRun._drive_hosts_that_left()
            if !isempty(left)
                print_err("ERROR: "; bold = true)
                println_fatal("required hosts left during the run: $(join(left, ", "))")
                println_fatal("Pass --best-effort for a partial run.")
                progress_ok = false
                return 1
            end
        end

        kit_progress_step!("collect")
        DistSSHRun._stop_drive_host_status_monitor!()
        DistSSHRun._mark_drive_hosts_collect_pending!(kit_out, kit_log)
        collect_ok, collect_hosts = collect_drive_results!(
            successful_hosts, script_dir, sentinel_name, skip_collect, path_anchor, project_root;
            julia = julia_exe,
        )
        resolved_hosts !== nothing && (resolved_hosts[] = collect_hosts)
        if !best_effort && !collect_ok
            progress_ok = false
            return 1
        end
        progress_ok = true
        return 0
    finally
        if resolved_output_dir !== nothing
            resolved_output_dir[] = DistSSHRun.resolve_drive_output_dir(script_dir)
        end
        if resolved_log_dir !== nothing
            resolved_log_dir[] = enable_log ? DistSSHRun.resolve_drive_log_dir(log_dir, script_dir) : nothing
        end
        kit_progress_done!(; ok = progress_ok)
        # Replay any job-stdout capture (log-enabled `:progress`, worker sync).
        # `--no-log` drivers print live after `_progress_release_line!` instead.
        DistSSHRun._print_job_stdout_after_progress!()
        DistSSHRun._maybe_print_kit_progress_phases(kit_out)
        DistSSHRun._set_kit_progress_sidecar!(nothing)
        DistSSHRun._stop_drive_host_status_monitor!()
        # `nothing` when no workers were ever added (early `return` above
        # `add_drive_workers!`). Otherwise idempotent (guarded by a `Ref`
        # inside) — a harmless no-op if `atexit` already ran it.
        # Runs in the frame's non-cancellable scope, before Distributed `atexit`.
        _teardown_drive_workers_after_run!(drive_atexit_cleanup)
        try
            DistSSHRun.await_declared_input_hashes!()
        finally
            enable_log && close_log_file()
        end
    end
end
