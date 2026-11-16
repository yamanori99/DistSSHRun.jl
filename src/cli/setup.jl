#!/usr/bin/env julia
# `julia -m DistSSHKit setup` — deploy and verify the project on SSH hosts.
#
# Recommended workflow:
#   1. ship-tree → 2. instantiate → 3. check → 4. runtest (optional) → `go` / `drive`
#   instantiate/check/go use --run-id ID, else last-ship.toml, else a git
#   checkout with Project.toml at the deploy root. Lexical latest is not used.
#   Optional git: git-clone → instantiate → check → git-sync / git-pull
#   Replace a clone dest: delete, then git-clone
#
#   julia --project=. -m DistSSHKit setup ship-tree host1 host2
#   julia --project=. -m DistSSHKit setup git-sync host1 host2   # git updates
#
# See `--help`.

# Guard on a setup-only import — not names `go`/`drive` may already have
# bound from DistSSHRun (e.g. `cli_project_root`) before `setup.jl` is included.
# Top-level include so JETLS sees `_include_checkout_run`. Including this file
# does not load the package and does not exit.
include(joinpath(@__DIR__, "_checkout.jl"))

# `find_package` is nothing when this environment does not provide DistSSHRun.
# Any other import failure (precompile, `__init__`) propagates.
if !isdefined(@__MODULE__, :DistSSHRun)
    if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") == "1"
        import DistSSHRun
    elseif Base.find_package("DistSSHRun") === nothing
        include(joinpath(@__DIR__, "_checkout.jl"))
        try
            _include_checkout_run()
            import DistSSHRun
        catch err
            _checkout_report(err, @__FILE__)
        end
    else
        import DistSSHRun
    end
end

# The included module already binds `resolve_remote_project_root`.
# Key off the setup parser, which that import does not bring in.

# A mismatch returns 1. The path is single-quoted so a shell does not expand `~`.
function _confirm_path_quote(path::AbstractString)::String
    return "'" * replace(String(path), "'" => "'\\''") * "'"
end

"""`--deploy-root PATH` suffix for printed setup follow-up commands (one shell word)."""
function _setup_next_deploy_root_flag(deploy_root::Union{Nothing, AbstractString})::String
    deploy_root isa AbstractString || return ""
    p = strip(String(deploy_root))
    isempty(p) && return ""
    return " --deploy-root $(DistSSHRun.posix_quote(p))"
end

# `-y` / `--yes` / `DISTSSH_YES` do not authorize delete or prune.
# A matching `--confirm-path` still deletes. With neither, the caller prompts.
function _setup_reject_yes_delete(
        yes::Bool,
        confirm_paths::Vector{String},
    )::Union{Nothing, Cint}
    yes || return nothing
    isempty(confirm_paths) || return nothing
    print_err("Error: "; bold = true)
    println_fatal(
        "-y, --yes, and DISTSSH_YES do not authorize setup delete or setup prune. " *
            "Pass --confirm-path. See help setup.",
    )
    return DistSSHRun.DistSSHBase.CLI_EXIT_USAGE
end

function _setup_confirm_error(err)::Cint
    err isa DistSSHRun.ConfirmPathMismatch || err isa ArgumentError || rethrow()
    print_err("Error: "; bold = true)
    if err isa DistSSHRun.ConfirmPathMismatch
        shown = _confirm_path_quote(err.expected)
        println_fatal("--confirm-path does not match $(shown). See help setup.")
    else
        println_fatal(err.msg)
    end
    println_fatal()
    return DistSSHRun.DistSSHBase.CLI_EXIT_USAGE
end

function _setup_confirm_plan(
        hosts::Vector{String},
        mode::Symbol,
        confirm_paths::Vector{String},
        expected::AbstractString,
    )
    try
        return DistSSHRun._setup_confirm_plans(hosts, mode, confirm_paths, expected)
    catch err
        return _setup_confirm_error(err)
    end
end
if !isdefined(@__MODULE__, :parse_setup_args)
    include(joinpath(@__DIR__, "setup", "_using.jl"))
end

if !isdefined(@__MODULE__, :setup_main)
    function setup_main()::Cint
        return DistSSHRun.DistSSHBase.with_cli_exit() do
            return _setup_main_body()
        end
    end

    function _setup_main_body()::Cint
        opts = DistSSHRun.DistSSHBase.cli_parse(() -> parse_setup_args(ARGS))

        if opts.show_version
            DistSSHRun.println_kit_version()
            return Cint(0)
        end

        if opts.show_help
            return DistSSHRun.DistSSHBase.cli_help_stdout(show_usage)
        end

        if opts.mode === :requirements
            show_requirements()
            return Cint(0)
        end

        if opts.mode === nothing
            return DistSSHRun.DistSSHBase.cli_required_else_help(show_usage)
        end

        try
            DistSSHRun.check_setup_options!(
                opts.mode;
                extra_files = opts.extra_files,
                run_id = opts.run_id,
            )
        catch e
            e isa ArgumentError || rethrow()
            throw(DistSSHRun.DistSSHBase.CliUsageError(String(e.msg)))
        end

        try
            validate_setup_hosts(
                opts.hosts;
                allow_parent = false,
            )
        catch e
            e isa ArgumentError || rethrow()
            throw(DistSSHRun.DistSSHBase.CliUsageError(String(e.msg)))
        end

        project = String(DistSSHRun.cli_project_root(@__DIR__))
        path_anchor = DistSSHRun.canonical_local_path(project)
        remote_path = resolve_remote_project_root(
            project;
            cli_override = opts.deploy_root,
        )
        deploy_path = DistSSHRun.remote_deploy_root(
            project;
            cli_override = opts.deploy_root,
        )

        function setup_job!(mode::Symbol)::Cint
            if mode === :check
                print_err(DistSSHRun.setup_check_removed_message(); bold = true)
                println_fatal()
                return Cint(2)
            end
            if mode in (
                    :instantiate, :runtest, :ship_tree, :remote_root,
                    :cleanup, :git_pull, :git_sync, :git_clone,
                )
                return DistSSHRun.setup_cli_via_bang!(
                    opts, project, deploy_path, remote_path, path_anchor, mode,
                )
            end
            mode_name = Dict(
                :git_clone => "git-clone",
                :delete => "Delete",
                :git_pull => "git-pull",
                :git_sync => "git-sync",
                :ship_tree => "ship-tree",
                :remote_root => "remote-root",
                :instantiate => "Instantiate",
                :runtest => "Pkg.test (job)",
                :cleanup => "Cleanup Workers",
                :prune => "Prune kit leaves",
            )[mode]
            selection_err = nothing
            op_path = try
                if mode === :delete
                    DistSSHRun.remote_delete_root(
                        project;
                        cli_override = opts.deploy_root,
                    )
                elseif mode === :git_clone
                    DistSSHRun.remote_git_clone_dest(
                        project;
                        cli_override = opts.deploy_root,
                    )
                elseif mode === :ship_tree
                    DistSSHRun._checked_remote_dest(deploy_path)
                elseif mode === :remote_root
                    override = opts.deploy_root
                    if !(override isa AbstractString)
                        throw(
                            ArgumentError(
                                "setup remote-root needs --deploy-root as an absolute path",
                            ),
                        )
                    end
                    DistSSHRun.explicit_remote_root_path(override)
                elseif mode === :prune
                    DistSSHRun._checked_remote_dest(remote_path)
                else
                    remote_path
                end
            catch e
                e isa ArgumentError || rethrow()
                print_err("Error: "; bold = true)
                println_fatal(e.msg)
                return Cint(1)
            end
            if (mode === :instantiate || mode === :runtest) &&
                    !isempty(opts.hosts)
                try
                    op_path = DistSSHRun._project_work_root(
                        opts.hosts, project;
                        cli_override = opts.deploy_root,
                        run_id = opts.run_id,
                    )
                catch e
                    e isa ArgumentError || rethrow()
                    # --check still has to reach SSH diagnostics (`ssh not
                    # found`) when selection cannot probe yet. After
                    # prerequisites succeed, this error still fails the
                    # command so an incomplete snapshot is not reported as
                    # met.
                    print_err("Error: "; bold = true)
                    println_fatal(e.msg)
                    return Cint(1)
                end
            end
            print_header("$(DistSSHRun.cli_heading("setup")) · $mode_name")
            kit_println()
            writeln_field("Remote path", op_path)
            kit_println()

            # Mutating / multi-host SSH ops: fail fast before confirmations.
            # `--delete` and `--prune` stay off SSH until `--confirm-path` matches.
            if mode === :git_clone || mode === :ship_tree || mode === :remote_root ||
                    mode === :instantiate || mode === :runtest
                if !preflight_setup_ssh(opts.hosts)
                    print_err("SSH preflight failed. Fix connectivity, then retry.\n")
                    kit_println()
                    return Cint(1)
                end
            end

            if mode === :delete
                delete_path = op_path
                yes_gate = _setup_reject_yes_delete(opts.cli_session.yes, opts.confirm_paths)
                yes_gate isa Cint && return yes_gate
                plan = _setup_confirm_plan(opts.hosts, :delete, opts.confirm_paths, delete_path)
                plan isa Cint && return plan
                if plan !== nothing && !preflight_setup_ssh(opts.hosts)
                    print_err("SSH preflight failed. Fix connectivity, then retry.\n")
                    kit_println()
                    return Cint(1)
                end
                result = plan === nothing ?
                    delete_remotes(
                        opts.hosts, delete_path;
                        confirm = true, deploy_root = deploy_path,
                    ) :
                    DistSSHRun._apply_confirmed_delete(opts.hosts, plan, deploy_path)
                ok = finish_host_op!("Delete", result)
                ok && DistSSHRun.forget_last_ship_after_host_op!(project, deploy_path, result)
                return Cint(ok ? 0 : 1)
            end

            if mode === :git_clone
                DistSSHRun.ensure_manifest_in_git_worktree!(project)
                clone_url = resolve_clone_url(opts.repo_url, project)
                clone_dest = op_path
                result = clone_to_remotes(opts.hosts, clone_dest, clone_url)
                ok = finish_host_op!("Clone", result)
                if ok
                    DistSSHRun.forget_last_ship_after_host_op!(project, deploy_path, result)
                    if result.failed == 0
                        ok_hosts = String[
                            hr.host for hr in result.hosts if hr.ok
                        ]
                        DistSSHRun.commit_deploy_record_after_git!(
                            ok_hosts, deploy_path, project, :git_clone,
                        )
                    end
                    if !result.cancelled && result.failed == 0 &&
                            (
                            opts.deploy_root !== nothing ||
                                !isempty(strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", "")))
                        )
                        kit_println(
                            "  Tip: export DISTRIBUTED_REMOTE_PROJECT_ROOT=$(DistSSHRun.posix_quote(deploy_path))",
                        )
                        kit_println("       so drive.jl uses the same remote root for workers / collect.")
                        kit_println()
                    end
                end
                return Cint(ok ? 0 : 1)
            end

            if mode === :ship_tree
                ok = finish_host_op!(
                    "ship-tree",
                    ship_to_remotes(
                        opts.hosts,
                        op_path,
                        project;
                        path_anchor = path_anchor,
                        allow_external_symlinks = opts.allow_external_symlinks,
                        extra_files = opts.extra_files,
                    ),
                )
                sel = ok ? DistSSHRun.active_source_selection() : nothing
                if ok && sel !== nothing
                    rid = sel.run_id
                    src = sel.work_root
                    path_flag = _setup_next_deploy_root_flag(opts.deploy_root)
                    if rid isa AbstractString && !isempty(rid)
                        kit_println(
                            "  Next: $(DistSSHRun.cli_m()) setup instantiate --run-id $rid$path_flag",
                        )
                        kit_println(
                            "        $(DistSSHRun.cli_m()) doctor --deploy --run-id $rid$path_flag",
                        )
                    elseif src isa AbstractString
                        flag = _setup_next_deploy_root_flag(src)
                        kit_println(
                            "  Next: $(DistSSHRun.cli_m()) setup instantiate$flag",
                        )
                        kit_println(
                            "        $(DistSSHRun.cli_m()) doctor --deploy$flag",
                        )
                    end
                    kit_println()
                end
                return Cint(ok ? 0 : 1)
            end

            if mode === :remote_root
                ok = finish_host_op!(
                    "remote-root",
                    DistSSHRun.create_remote_roots!(
                        opts.hosts, op_path; confirm = !opts.cli_session.yes,
                    ),
                )
                return Cint(ok ? 0 : 1)
            end

            if mode === :instantiate
                return Cint(
                    finish_host_op!(
                            "Instantiate",
                            instantiate_remotes(
                                opts.hosts, opts.julia_path, op_path, project;
                                path_anchor = path_anchor,
                            ),
                        ) ? 0 : 1
                )
            end

            if mode === :runtest
                return Cint(
                    finish_host_op!(
                            "Pkg.test",
                            runtest_remotes(
                                opts.hosts, opts.julia_path, op_path, project;
                                path_anchor = path_anchor,
                            ),
                        ) ? 0 : 1
                )
            end

            if mode === :cleanup
                job_id = opts.job_id
                if job_id === nothing || isempty(strip(String(job_id)))
                    print_err("Error: "; bold = true)
                    println_fatal("setup cleanup requires --job-id JOB_ID (job-scoped since 0.2.0).")
                    println_fatal()
                    return Cint(2)
                end
                return Cint(
                    finish_host_op!(
                            "Cleanup",
                            cleanup_remote_workers(opts.hosts, String(job_id)),
                        ) ? 0 : 1
                )
            end

            if mode === :prune
                yes_gate = _setup_reject_yes_delete(opts.cli_session.yes, opts.confirm_paths)
                yes_gate isa Cint && return yes_gate
                plan = _setup_confirm_plan(opts.hosts, :prune, opts.confirm_paths, op_path)
                plan isa Cint && return plan
                if plan !== nothing && !preflight_setup_ssh(opts.hosts)
                    print_err("SSH preflight failed. Fix connectivity, then retry.\n")
                    kit_println()
                    return Cint(1)
                end
                result = plan === nothing ?
                    prune_kit_leaves(
                        opts.hosts,
                        op_path,
                        project;
                        confirm = true,
                        older_days = opts.older_days,
                        id = opts.prune_id,
                        skip_setup = DistSSHRun.setup_log_dir(project),
                    ) :
                    DistSSHRun._apply_confirmed_prune(
                        opts.hosts,
                        plan,
                        project;
                        older_days = opts.older_days,
                        id = opts.prune_id,
                        skip_setup = DistSSHRun.setup_log_dir(project),
                    )
                return Cint(finish_host_op!("Prune", result) ? 0 : 1)
            end

            # --git-pull/--git-sync: a commit mismatch is fixed by checkout --detach.
            # Both git modes refuse a dirty local tree (a patch is not shipped).
            require_clean = mode === :git_pull ||
                (mode === :git_sync && !opts.skip_git_guard)
            result = check_prerequisites(
                opts.hosts, opts.julia_path, op_path, project;
                path_anchor = path_anchor,
                require_clean_git = require_clean,
                check_code_sync = false,
                ignore_julia_version = opts.ignore_julia_version,
            )

            if !result.ok
                println_err_after_progress("Prerequisites not met. Fix issues above and retry.")
                return Cint(1)
            end

            # Hashes already matching still run: the remote must be detached at
            # that commit, and a dirty remote tree is refused.
            print_ok("Ready to proceed.")
            kit_println()
            kit_println()

            # --git-sync also pushes the local branch to origin.
            # --git-pull does not. Neither mode runs git pull.
            do_push = (mode === :git_sync)
            raw = git_sync_project_to_hosts!(
                opts.hosts,
                project,
                remote_path;
                do_push = do_push,
                do_pull = true,
                allow_dirty = opts.skip_git_guard,
            )
            raw.cancelled && return Cint(0)
            if !raw.ok
                print_err("$mode_name failed.")
                kit_println()
                return Cint(1)
            end

            DistSSHRun.forget_last_ship_default!(project, deploy_path)
            DistSSHRun.commit_deploy_record_after_git!(
                opts.hosts,
                deploy_path,
                project,
                mode === :git_sync ? :git_sync : :git_pull;
                dirty = mode === :git_sync && opts.skip_git_guard,
            )
            print_ok("$mode_name complete.")
            kit_println()
            return Cint(0)
        end

        log_dir = DistSSHRun.setup_log_dir(project)
        init_log_file(
            log_dir;
            prefix = "setup",
            path_anchor = path_anchor,
        )
        try
            return DistSSHRun.with_kit_setup_progress(
                log_dir,
                DistSSHRun.setup_progress_step_name(opts.mode::Symbol);
                path_anchor = path_anchor,
            ) do
                setup_job!(opts.mode::Symbol)
            end
        catch e
            DistSSHRun._report_manifest_refusal(e) || rethrow()
            return Cint(1)
        finally
            close_log_file()
        end
    end
end # setup_main guard

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(setup_main())
end
