# CLI `setup` → [`setup!`](@ref) bridge (display stays in `src/cli/setup.jl`).

"""Build a [`DistSSHSession`](@ref) from parsed setup CLI options."""
function setup_session_from_cli(
        opts,
        project::AbstractString,
        remote_path::Union{Nothing, AbstractString},
    )::DistSSHSession
    cs = opts.cli_session
    return DistSSHSession(
        project = canonical_local_path(project),
        workers = String.(opts.hosts),
        remote = remote_path,
        quiet = cs.quiet,
        verbosity = cs.verbosity,
        yes = cs.yes,
    )
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
    mode_name = Dict(
        :git_clone => "git-clone",
        :check => "Check Prerequisites",
        :git_pull => "git-pull",
        :git_sync => "git-sync",
        :ship_tree => "ship-tree",
        :remote_root => "remote-root",
        :instantiate => "Instantiate",
        :runtest => "Pkg.test (job)",
        :cleanup => "Cleanup Workers",
    )[mode]
    print_header("$(DistSSHRun.cli_heading("setup")) · $mode_name")
    kit_println()
    remote_for_session = opts.deploy_root !== nothing ? deploy_path : remote_path
    writeln_field("Remote path", remote_for_session)
    kit_println()
    session = setup_session_from_cli(opts, project, remote_for_session)
    if mode in (:instantiate, :runtest, :check, :ship_tree, :git_clone) &&
            !isempty(opts.hosts) && !preflight_setup_ssh(opts.hosts)
        print_err("SSH preflight failed. Fix connectivity, then retry.\n")
        kit_println()
        return Cint(1)
    end
    if mode === :remote_root && opts.deploy_root isa AbstractString
        session = DistSSHSession(
            project = session.project,
            workers = session.hosts,
            remote = opts.deploy_root,
            quiet = session.quiet,
            verbosity = session.verbosity,
            yes = session.yes,
        )
    end
    result = try
        if mode === :git_clone
            run_setup_bang_mode!(
                session,
                mode;
                repo = opts.repo_url,
                julia = opts.julia_path,
            )
        elseif mode === :check
            run_setup_bang_mode!(
                session,
                mode;
                julia = opts.julia_path,
                run_id = opts.run_id,
                ignore_julia_version = opts.ignore_julia_version,
                check_code_sync = true,
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
                run_id = opts.run_id,
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
    ok = result.ok
    if ok && mode === :ship_tree
        sel = active_source_selection()
        if sel !== nothing
            path_flag = _cli_deploy_root_flag(opts.deploy_root)
            rid = sel.run_id
            if rid isa AbstractString && !isempty(rid)
                kit_println(
                    "  Next: $(cli_m()) setup instantiate --run-id $rid$path_flag",
                )
                kit_println(
                    "        $(cli_m()) setup check --run-id $rid$path_flag",
                )
            elseif sel.work_root isa AbstractString
                flag = _cli_deploy_root_flag(sel.work_root)
                kit_println(
                    "  Next: $(cli_m()) setup instantiate$flag",
                )
                kit_println(
                    "        $(cli_m()) setup check$flag",
                )
            end
            kit_println()
        end
    end
    return Cint(ok ? 0 : 1)
end

public run_setup_bang_mode!, setup_cli_via_bang!, setup_confirm_path_from_cli
public setup_session_from_cli
