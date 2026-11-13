"""Build a `parse_drive_args`-shaped NamedTuple from a session + options."""
function drive_parsed_from_session(
        session::KitSession,
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
        require_all_hosts::Bool = true,
        worker_include::Bool = false,
        sync_script::Union{Nothing, Bool} = nothing,
        unsafe_heterogeneous = false,
        allow_external_symlinks::Bool = false,
        run_id::Union{Nothing, AbstractString} = nothing,
    )
    _reject_removed_drive_worker_include_kw!(sync_script)
    _reject_run_transfer_kw!("drive!", sync; surface = hint_surface(session))
    allow_external_symlinks &&
        _reject_run_transfer_cli!("drive!", "--allow-external-symlinks")
    parent_workers = 0
    hosts = Tuple{String, Union{Int, Nothing}}[]
    if workers !== nothing
        parent_workers = workers.parent_workers
        for (host, n) in workers.child_workers
            n > 0 && push!(hosts, (host, n))
        end
    else
        for h in session.hosts
            push!(hosts, (h, nothing))
        end
    end
    cli_session = KitCliSession(
        quiet = session.quiet,
        verbosity = session.verbosity,
        yes = session.yes,
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
        parent_workers = parent_workers,
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
        require_all_hosts = require_all_hosts,
        help = false,
        show_version = false,
        cli_session = cli_session,
        hint_surface = hint_surface(session),
        unsafe_heterogeneous = unsafe_heterogeneous,
        run_id = snap,
        deploy_root = session.remote,
        isolated = false,
    )
end
