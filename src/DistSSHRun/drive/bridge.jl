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
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
    )
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
        isolated = false,
        unsafe_master_silence_exit = unsafe_master_silence_exit === nothing ?
            missing :
            unsafe_master_silence_exit,
        bind_overrides = Dict{String, String}(String(k) => String(v) for (k, v) in bind_overrides),
    )
end
