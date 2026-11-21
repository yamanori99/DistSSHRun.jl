function _reject_drive_isolated_api!(
        isolated::Bool,
        session::DistSSHSession,
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString},
    )
    isolated || return nothing
    session.cli_session.hosts_file !== nothing &&
        throw(ArgumentError(drive_isolated_hosts_file_message()))
    !isempty(bind_overrides) &&
        throw(ArgumentError(drive_isolated_bind_overrides_message()))
    return nothing
end

function _append_drive_shared_verbosity_argv!(out::Vector{String}, cli_session::CliSharedFlags)
    cli_session.verbosity_explicit || return nothing
    cli_session.quiet && push!(out, "--quiet")
    cli_session.verbosity === :verbose && !cli_session.quiet && push!(out, "--verbose")
    cli_session.verbosity === :progress && !cli_session.quiet && push!(out, "--progress")
    return nothing
end

"""CLI argv for a child `julia -m DistSSHKit drive` from API `drive_parsed_from_session` output."""
function drive_api_isolated_argv(parsed)::Vector{String}
    out = String[]
    push!(out, "--head-workers", string(Int(parsed.head_workers)))
    for (h, n) in parsed.hosts
        push!(out, "--hosts", DistSSHBase.format_machine_token(Int(something(n, 1)), h))
    end
    get(parsed, :skip_hash_check, true) == false && push!(out, "--require-git")
    get(parsed, :enable_log, true) == false && push!(out, "--no-log")
    let v = get(parsed, :log_dir, nothing)
        v !== nothing && push!(out, "--log-dir", String(v))
    end
    let v = get(parsed, :output_dir, nothing)
        v !== nothing && push!(out, "--output-dir", String(v))
    end
    let v = get(parsed, :explicit_package, nothing)
        v !== nothing && push!(out, "--package", String(v))
    end
    let v = get(parsed, :julia, nothing)
        v !== nothing && push!(out, "--julia", String(v))
    end
    let v = get(parsed, :run_id, nothing)
        v !== nothing && push!(out, "--run-id", String(v))
    end
    let v = get(parsed, :deploy_root, nothing)
        v !== nothing && push!(out, DEPLOY_ROOT_FLAG, String(v))
    end
    get(parsed, :best_effort, false) === true && push!(out, "--best-effort")
    get(parsed, :worker_include, false) === true && push!(out, "--worker-include")
    for row in options_for_command(:drive)
        row.cli === nothing && continue
        get(parsed, row.key, missing) === true && push!(out, row.cli)
    end
    _append_drive_shared_verbosity_argv!(out, parsed.cli_session)
    push!(out, String(parsed.script_path))
    _append_drive_api_script_args!(out, parsed.script_args)
    return out
end

"""Env keys the API isolated child must not read. CLI `--isolated` drops nothing."""
function _isolated_api_env_drops(parsed)::Vector{String}
    hasproperty(parsed, :reuse_main) || return String[]
    drops = String["DISTSSH_HOSTS", "DISTSSH_HOSTS_FILE"]
    for row in options_for_command(:drive)
        row.env === nothing && continue
        get(parsed, row.key, missing) === false && push!(drops, String(row.env))
    end
    return drops
end

"""Build a `parse_drive_args`-shaped NamedTuple from a session + options."""
function drive_parsed_from_session(
        session::DistSSHSession,
        script::AbstractString;
        workers::Union{Nothing, WorkerPlan} = nothing,
        script_args::AbstractVector{<:AbstractString} = String[],
        skip_hash_check::Bool = true,
        output_dir::Union{Nothing, AbstractString} = nothing,
        enable_log::Bool = true,
        log_dir::Union{Nothing, AbstractString} = nothing,
        package::Union{Nothing, AbstractString} = nothing,
        sync::Union{Nothing, Symbol, Bool} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
        best_effort::Bool = false,
        worker_include::Bool = false,
        sync_script::Union{Nothing, Bool} = nothing,
        unsafe_skip_env_digests = false,
        allow_external_symlinks::Bool = false,
        run_id::Union{Nothing, AbstractString} = nothing,
        unsafe_master_silence_exit::Union{Nothing, Bool} = nothing,
        unsafe_expose_port::Union{Nothing, Bool} = nothing,
        unsafe_all_to_all::Union{Nothing, Bool} = nothing,
        isolated::Bool = false,
        reuse_main::Bool = false,
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
    )
    isolated && reuse_main && throw(ArgumentError(drive_isolated_reuse_main_conflict_message()))
    _reject_drive_isolated_api!(isolated, session, bind_overrides)
    _reject_removed_drive_worker_include_kw!(sync_script)
    _reject_run_transfer_kw!("drive!", sync; surface = hint_surface(session))
    allow_external_symlinks &&
        _reject_run_transfer_cli!("drive!", "--allow-external-symlinks")
    head_workers = 0
    hosts = Tuple{String, Union{Int, Nothing}}[]
    if workers !== nothing
        head_workers = workers.head_workers
        for (host, n) in workers.child_workers
            n > 0 && push!(hosts, (host, n))
        end
    else
        lw = session.cli_session.head_workers
        lw !== nothing && (head_workers = Int(lw))
        for h in session.hosts
            push!(hosts, (h, nothing))
        end
    end
    cli_session = CliSharedFlags(
        quiet = session.quiet,
        verbosity = session.verbosity,
        yes = session.cli_session.yes,
        show_version = false,
        hosts_file = session.cli_session.hosts_file,
        hint_surface = hint_surface(session),
    )
    snap = run_id === nothing ? nothing : validate_run_id(run_id)
    julia_exe = if julia === nothing || strip(String(julia)) == "" ||
            lowercase(strip(String(julia))) == "auto"
        nothing
    else
        String(julia)
    end
    return (
        head_workers = head_workers,
        default_workers = nothing,
        julia = julia_exe,
        skip_hash_check = skip_hash_check,
        enable_log = enable_log,
        log_dir = log_dir === nothing ? nothing : String(log_dir),
        output_dir = output_dir === nothing ? nothing : String(output_dir),
        explicit_package = package === nothing ? nothing : String(package),
        hosts = hosts,
        script_path = String(script),
        script_args = collect(String, script_args),
        collect_root = nothing,
        collect_hosts = nothing,
        collect_overwrite = nothing,
        worker_include = worker_include,
        best_effort = best_effort,
        help = false,
        show_version = false,
        cli_session = cli_session,
        hint_surface = hint_surface(session),
        unsafe_skip_env_digests = cli_optional_bool(unsafe_skip_env_digests),
        unsafe_expose_port = unsafe_expose_port === nothing ? missing : cli_optional_bool(unsafe_expose_port),
        unsafe_all_to_all = unsafe_all_to_all === nothing ? missing : cli_optional_bool(unsafe_all_to_all),
        print_config = missing,
        dry_run = missing,
        run_id = snap,
        deploy_root = session.remote,
        isolated = isolated,
        reuse_main = reuse_main,
        unsafe_master_silence_exit = unsafe_master_silence_exit === nothing ?
            missing :
            unsafe_master_silence_exit,
        bind_overrides = Dict{String, String}(String(k) => String(v) for (k, v) in bind_overrides),
    )
end
