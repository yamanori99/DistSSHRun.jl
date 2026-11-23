# CLI `setup` → [`setup!`](@ref) bridge (display stays in `src/cli/setup.jl`).

"""Build a [`DistSSHSession`](@ref) from parsed setup CLI options."""
function setup_session_from_cli(
        opts,
        project::AbstractString,
        remote_path::Union{Nothing, AbstractString},
    )::DistSSHSession
    cs = opts.cli_session
    workers = String[setup_cli_host_token(h) for h in opts.hosts]
    session = DistSSHSession(
        project = canonical_local_path(project),
        workers = workers,
        remote = remote_path,
        quiet = cs.quiet,
        verbosity = cs.verbosity,
    )
    session.cli_session.yes = cs.yes
    session.cli_session.hint_surface = cs.hint_surface
    return session
end

"""
    setup_confirm_path_from_cli(hosts, confirm_paths) -> confirm_path

Bind `confirm_path` for [`setup!`](@ref) `:delete` / `:prune` from CLI vectors.
"""
function setup_confirm_path_from_cli(
        hosts::Vector{String},
        confirm_paths::Vector{String},
    )
    isempty(confirm_paths) && return nothing
    length(confirm_paths) == 1 && length(hosts) == 1 &&
        return normalize_remote_confirm_path(confirm_paths[1])
    plan = Dict{String, String}()
    for (i, host) in enumerate(hosts)
        i > length(confirm_paths) && break
        plan[String(host)] = normalize_remote_confirm_path(confirm_paths[i])
    end
    return plan
end

"""
    run_setup_bang_mode!(
        session,
        mode::Symbol;
        kwargs...
    ) -> SyncResult

Run one setup mode through [`setup!`](@ref). Git prerequisite checks live in core.
"""
function run_setup_bang_mode!(session::DistSSHSession, mode::Symbol; kwargs...)::SyncResult
    return setup!(session, mode; kwargs...)
end

function _cli_deploy_root_flag(deploy_root)::String
    deploy_root isa AbstractString || return ""
    p = strip(String(deploy_root))
    isempty(p) && return ""
    return " --deploy-root $(posix_quote(p))"
end

const _SETUP_CLI_FINISH_LABEL = Dict(
    :cleanup => "Cleanup",
    :git_clone => "Clone",
    :git_pull => "git-pull",
    :git_sync => "git-sync",
    :instantiate => "Instantiate",
    :remote_root => "remote-root",
    :runtest => "Pkg.test",
    :ship_tree => "ship-tree",
)

function _setup_cli_path_guard!(
        mode::Symbol,
        deploy_path::AbstractString,
        deploy_root,
    )
    if mode === :ship_tree
        _checked_remote_dest(deploy_path)
    elseif mode === :remote_root
        deploy_root isa AbstractString ||
            throw(ArgumentError("setup remote-root needs --deploy-root as an absolute path"))
        explicit_remote_root_path(String(deploy_root))
    end
    return nothing
end

function _host_op_counts(result::SyncResult)
    succeeded = count(hr -> hr.ok, result.hosts)
    failed = length(result.hosts) - succeeded
    return host_op_result(; cancelled = result.cancelled, succeeded = succeeded, failed = failed)
end

"""
    setup_cli_via_bang!(opts, project, deploy_path, remote_path, path_anchor, mode) -> Cint

CLI `setup` subcommands that map directly to [`setup!`](@ref).
"""
function setup_cli_via_bang!(
        opts,
        project::AbstractString,
        deploy_path::AbstractString,
        remote_path::AbstractString,
        _path_anchor::AbstractString,
        mode::Symbol,
    )::Cint
    if mode === :cleanup
        job_id = opts.job_id
        if job_id === nothing || isempty(strip(String(job_id)))
            print_err("Error: "; bold = true)
            println_fatal("setup cleanup requires --job-id JOB_ID (job-scoped since 0.2.0).")
            println_fatal()
            return Cint(2)
        end
    end
    mode_name = Dict(
        :git_clone => "git-clone",
        :git_pull => "git-pull",
        :git_sync => "git-sync",
        :ship_tree => "ship-tree",
        :remote_root => "remote-root",
        :instantiate => "Instantiate",
        :runtest => "Pkg.test (job)",
        :cleanup => "Cleanup Workers",
    )[mode]
    try
        _setup_cli_path_guard!(mode, deploy_path, opts.deploy_root)
    catch e
        e isa ArgumentError || rethrow()
        print_err("Error: "; bold = true)
        println_fatal(e.msg)
        return Cint(1)
    end
    print_header("$(DistSSHRun.cli_heading("setup")) · $mode_name")
    cli_println()
    remote_for_session = opts.deploy_root !== nothing ? deploy_path : remote_path
    writeln_field("Remote path", remote_for_session)
    cli_println()
    session = setup_session_from_cli(opts, project, remote_for_session)
    if mode === :remote_root && opts.deploy_root isa AbstractString
        prev = session
        session = DistSSHSession(
            project = prev.project,
            workers = prev.tokens,
            remote = opts.deploy_root,
            quiet = prev.quiet,
            verbosity = prev.verbosity,
        )
        session.cli_session = prev.cli_session
    end
    result = try
        if mode === :git_clone
            run_setup_bang_mode!(
                session,
                mode;
                repo = opts.repo_url,
                julia = opts.julia_path,
            )
        elseif mode === :cleanup
            run_setup_bang_mode!(
                session,
                mode;
                job_id = String(opts.job_id),
            )
        elseif mode === :git_sync
            run_setup_bang_mode!(
                session,
                mode;
                allow_dirty = opts.skip_git_guard,
            )
        elseif mode === :ship_tree
            run_setup_bang_mode!(
                session,
                mode;
                allow_external_symlinks = opts.allow_external_symlinks,
                extra_files = opts.extra_files,
            )
        elseif mode === :instantiate || mode === :runtest
            run_setup_bang_mode!(
                session,
                mode;
                julia = opts.julia_path,
                ship_id = opts.ship_id,
            )
        else
            run_setup_bang_mode!(session, mode; julia = opts.julia_path)
        end
    catch e
        e isa ArgumentError || rethrow()
        print_err("Error: "; bold = true)
        println_fatal(e.msg)
        return Cint(1)
    end
    label = get(_SETUP_CLI_FINISH_LABEL, mode, nothing)
    label === nothing && return Cint(result.ok ? 0 : 1)
    ok = finish_host_op!(label, _host_op_counts(result))
    if ok && mode === :ship_tree
        sel = active_source_selection()
        if sel !== nothing
            path_flag = _cli_deploy_root_flag(opts.deploy_root)
            rid = sel.ship_id
            if rid isa AbstractString && !isempty(rid)
                cli_println(
                    "  Next: $(cli_m()) setup instantiate --ship-id $rid$path_flag",
                )
                cli_println(
                    "        $(cli_m()) doctor --deploy --ship-id $rid$path_flag",
                )
            elseif sel.work_root isa AbstractString
                flag = _cli_deploy_root_flag(sel.work_root)
                cli_println(
                    "  Next: $(cli_m()) setup instantiate$flag",
                )
                cli_println(
                    "        $(cli_m()) doctor --deploy$flag",
                )
            end
            cli_println()
        end
    end
    return Cint(ok ? 0 : 1)
end

public run_setup_bang_mode!, setup_cli_via_bang!, setup_confirm_path_from_cli
public setup_session_from_cli
