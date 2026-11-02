#!/usr/bin/env julia
# `julia -m DistSSHKit setup` — deploy and verify the project on SSH hosts.
#
# Recommended workflow:
#   1. --ship-tree → 2. --instantiate → 3. --check → 4. --runtest (optional) → `go` / `drive`
#   instantiate/check/go follow latest runs/<run_id>/src when the root has no Project.toml.
#   Optional git: --clone → --instantiate → --check → --sync / --pull
#   Replace a clone dest: --delete, then --clone
#
#   julia --project=. -m DistSSHKit setup --ship-tree child:host1 child:host2
#   julia --project=. -m DistSSHKit setup --sync child:host1 child:host2   # git updates
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

# `-y` / `--yes` / `DISTSSHKIT_YES` do not authorize delete or prune.
# A matching `--confirm-path` still deletes. With neither, the caller prompts.
function _setup_reject_yes_delete(
        yes::Bool,
        confirm_paths::Vector{String},
    )::Union{Nothing, Cint}
    yes || return nothing
    isempty(confirm_paths) || return nothing
    print_err("Error: "; bold = true)
    println_fatal(
        "-y, --yes, and DISTSSHKIT_YES do not authorize setup --delete or setup --prune. " *
            "Pass --confirm-path. See help setup.",
    )
    return Cint(1)
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
    return Cint(1)
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
        opts = try
            parse_setup_args(ARGS)
        catch e
            e isa ArgumentError || rethrow()
            print_err("Error: "; bold = true)
            println_fatal(e.msg)
            println_fatal()
            # An unknown option already names `help setup`. Do not print the page.
            if !startswith(e.msg, "unknown setup option:")
                show_usage()
            end
            return 1
        end

        if opts.show_version
            DistSSHRun.println_kit_version()
            return 0
        end

        if opts.show_help
            show_usage()
            return 0
        end

        if opts.mode === nothing || opts.mode === :requirements
            show_requirements()
            return 0
        end

        try
            validate_setup_hosts(
                opts.hosts;
                allow_parent = setup_mode_allows_parent(opts.mode::Symbol),
            )
        catch e
            e isa ArgumentError || rethrow()
            # Fatal: always on terminal.
            print_err("Error: "; bold = true)
            println_fatal(e.msg)
            println_fatal()
            show_usage()
            return 1
        end

        project = String(DistSSHRun.cli_project_root(@__DIR__))
        path_anchor = DistSSHRun.canonical_local_path(project)
        remote_path = resolve_remote_project_root(
            project;
            cli_override = opts.remote_path_override,
        )
        deploy_path = DistSSHRun.remote_deploy_root(
            project;
            cli_override = opts.remote_path_override,
        )

        function setup_job!(mode::Symbol)::Cint
            mode_name = Dict(
                :clone => "Clone",
                :delete => "Delete",
                :check => "Check Prerequisites",
                :pull => "Pull",
                :sync => "Sync",
                :ship_tree => "ship-tree",
                :remote_root => "remote-root",
                :instantiate => "Instantiate",
                :juliaup => "juliaup (align Julia)",
                :juliaup_update => "juliaup update",
                :runtest => "Pkg.test (job)",
                :cleanup => "Cleanup Workers",
                :prune => "Prune kit leaves",
            )[mode]
            if mode === :juliaup || mode === :juliaup_update
                flag = mode === :juliaup_update ? "--juliaup-update" : "--juliaup"
                instead = mode === :juliaup_update ? "up update" : "up"
                @warn "setup $flag is deprecated and will be removed. Use `$(DistSSHRun.cli_m()) $instead`. The command still runs."
            end
            op_path = try
                if mode === :delete
                    DistSSHRun.remote_delete_root(
                        project;
                        cli_override = opts.remote_path_override,
                    )
                elseif mode === :clone
                    DistSSHRun.remote_git_clone_dest(
                        project;
                        cli_override = opts.remote_path_override,
                    )
                elseif mode === :ship_tree
                    DistSSHRun._checked_remote_dest(deploy_path)
                elseif mode === :remote_root
                    override = opts.remote_path_override
                    if !(override isa AbstractString)
                        throw(
                            ArgumentError(
                                "setup --remote-root needs --remote-path as an absolute path",
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
            if (mode === :instantiate || mode === :runtest || mode === :check) &&
                    !isempty(opts.hosts)
                op_path = DistSSHRun._project_work_root(
                    opts.hosts, project; cli_override = opts.remote_path_override,
                )
            end
            print_header("$(DistSSHRun.cli_heading("setup")) · $mode_name")
            kit_println()
            writeln_field("Remote path", op_path)
            kit_println()

            # Mutating / multi-host SSH ops: fail fast before confirmations.
            # `--delete` and `--prune` stay off SSH until `--confirm-path` matches.
            if mode === :clone || mode === :ship_tree || mode === :remote_root ||
                    mode === :instantiate || mode === :runtest
                if !preflight_setup_ssh(opts.hosts)
                    print_err("SSH preflight failed. Fix connectivity, then retry.")
                    kit_println()
                    return Cint(1)
                end
            elseif setup_mode_allows_parent(mode)
                ssh_hosts = setup_juliaup_ssh_hosts(opts.hosts)
                if !isempty(ssh_hosts) && !preflight_setup_ssh(ssh_hosts)
                    print_err("SSH preflight failed. Fix connectivity, then retry.")
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
                    print_err("SSH preflight failed. Fix connectivity, then retry.")
                    kit_println()
                    return Cint(1)
                end
                result = plan === nothing ?
                    delete_remotes(
                        opts.hosts, delete_path;
                        confirm = true, deploy_root = deploy_path,
                    ) :
                    DistSSHRun._apply_confirmed_delete(opts.hosts, plan, deploy_path)
                return Cint(finish_host_op!("Delete", result) ? 0 : 1)
            end

            if mode === :clone
                DistSSHRun.ensure_manifest_in_git_worktree!(project)
                clone_url = resolve_clone_url(opts.repo_url, project)
                clone_dest = op_path
                result = clone_to_remotes(opts.hosts, clone_dest, clone_url)
                ok = finish_host_op!("Clone", result)
                if ok && !result.cancelled && result.failed == 0 &&
                        (
                        opts.remote_path_override !== nothing ||
                            !isempty(strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", "")))
                    )
                    kit_println("  Tip: export DISTRIBUTED_REMOTE_PROJECT_ROOT=$deploy_path")
                    kit_println("       so drive.jl uses the same remote root for workers / collect.")
                    kit_println()
                end
                return Cint(ok ? 0 : 1)
            end

            if mode === :ship_tree
                ok = finish_host_op!(
                    "ship-tree",
                    rsync_push_to_remotes(
                        opts.hosts,
                        op_path,
                        project;
                        path_anchor = path_anchor,
                        allow_external_symlinks = opts.allow_external_symlinks,
                    ),
                )
                rec = DistSSHRun.last_ship_result()
                if ok && rec !== nothing
                    src = rec["src"]
                    kit_println("  Next: $(DistSSHRun.cli_m()) setup --instantiate --remote-path $src")
                    kit_println("        $(DistSSHRun.cli_m()) setup --check --remote-path $src")
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

            if mode === :juliaup
                return Cint(
                    finish_host_op!(
                            "juliaup",
                            juliaup_align_remotes(opts.hosts),
                        ) ? 0 : 1
                )
            end

            if mode === :juliaup_update
                return Cint(
                    finish_host_op!(
                            "juliaup update",
                            juliaup_update_remotes(opts.hosts),
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
                return Cint(finish_host_op!("Cleanup", cleanup_remote_workers(opts.hosts)) ? 0 : 1)
            end

            if mode === :prune
                yes_gate = _setup_reject_yes_delete(opts.cli_session.yes, opts.confirm_paths)
                yes_gate isa Cint && return yes_gate
                plan = _setup_confirm_plan(opts.hosts, :prune, opts.confirm_paths, op_path)
                plan isa Cint && return plan
                if plan !== nothing && !preflight_setup_ssh(opts.hosts)
                    print_err("SSH preflight failed. Fix connectivity, then retry.")
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

            # --pull/--sync: a commit mismatch is fixed by checkout --detach.
            # --check: require the commits to match already.
            # Both git modes refuse a dirty local tree (a patch is not shipped).
            require_clean = (mode === :sync || mode === :pull)
            check_code_sync = (mode === :check)
            result = check_prerequisites(
                opts.hosts, opts.julia_path, op_path, project;
                path_anchor = path_anchor,
                require_clean_git = require_clean,
                check_code_sync = check_code_sync,
                ignore_julia_version = opts.ignore_julia_version,
            )

            if !result.ok
                print_err("Prerequisites not met. Fix issues above and retry.")
                kit_println()
                return Cint(1)
            end

            if mode === :check
                DistSSHRun._warn_git_worktree_ship!(project)
                print_ok("All prerequisites met.")
                kit_println()
                return Cint(0)
            end

            # Hashes already matching still run: the remote must be detached at
            # that commit, and a dirty remote tree is refused.
            print_ok("Ready to proceed.")
            kit_println()
            kit_println()

            # --sync also pushes the local branch to origin.
            # --pull does not. Neither mode runs git pull.
            do_push = (mode === :sync)
            raw = git_sync_project_to_hosts!(
                opts.hosts,
                project,
                remote_path;
                do_push = do_push,
                do_pull = true,
            )
            raw.cancelled && return Cint(0)
            if !raw.ok
                print_err("$mode_name failed.")
                kit_println()
                return Cint(1)
            end

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
