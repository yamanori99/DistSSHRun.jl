#!/usr/bin/env julia
# `julia -m DistSSHKit doctor --deploy …`

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

if !isdefined(@__MODULE__, :_DOCTOR_CLI_USING)
    include(joinpath(@__DIR__, "doctor", "_using.jl"))
    const _DOCTOR_CLI_USING = true
end

if !isdefined(@__MODULE__, :doctor_main)
    function doctor_main()::Cint
        opts = try
            parse_doctor_args(ARGS)
        catch e
            e isa ArgumentError || rethrow()
            DistSSHRun.print_err("Error: "; bold = true, io = stderr)
            DistSSHRun.println_fatal(e.msg; io = stderr)
            DistSSHRun.println_fatal("", io = stderr)
            return Cint(2)
        end

        if opts.show_version
            DistSSHRun.println_kit_version()
            return Cint(0)
        end
        if opts.show_help
            DistSSHRun.show_doctor_usage()
            return Cint(0)
        end

        if !opts.deploy && isempty(opts.hosts)
            DistSSHRun.show_doctor_usage(io = stderr)
            return Cint(2)
        end

        if !opts.deploy
            DistSSHRun.print_err("Error: "; bold = true, io = stderr)
            DistSSHRun.println_fatal(
                "doctor needs --deploy; use: $(DistSSHRun.cli_m()) doctor --deploy [--ship-id ID] HOSTS";
                io = stderr,
            )
            DistSSHRun.println_fatal("", io = stderr)
            return Cint(2)
        end

        # Same root as setup / drive. `pwd()` ignored DISTRIBUTED_PROJECT_ROOT,
        # so doctor checked the kit checkout while git-sync checked the app.
        project = String(DistSSHRun.cli_project_root(@__DIR__))
        path_anchor = DistSSHRun.canonical_local_path(project)
        remote_path = DistSSHRun.resolve_remote_project_root(
            project;
            cli_override = opts.deploy_root,
        )
        deploy_path = remote_path

        selection_err = nothing
        op_path = try
            if !isempty(opts.hosts)
                DistSSHRun._project_work_root(
                    opts.hosts, project;
                    cli_override = opts.deploy_root,
                    ship_id = opts.ship_id,
                )
            else
                remote_path
            end
        catch e
            e isa ArgumentError || rethrow()
            selection_err = e
            remote_path
        end

        print_header("$(DistSSHRun.cli_heading("doctor")) · deploy")
        kit_println()
        writeln_field("Remote path", op_path)
        kit_println()

        session = DistSSHRun.DistSSHSession(
            project = project,
            workers = opts.hosts,
            remote = opts.deploy_root,
            quiet = opts.cli_session.quiet,
            verbosity = opts.cli_session.verbosity,
        )
        session.cli_session.yes = opts.cli_session.yes

        log_dir = DistSSHRun.setup_log_dir(project)
        init_log_file(log_dir; prefix = "doctor", path_anchor = path_anchor)
        try
            report = DistSSHRun._with_kit_inproc_run!(:doctor) do
                DistSSHRun.apply_session_env!(session)
                return DistSSHRun.doctor_deploy_check(
                    opts.hosts,
                    opts.julia_path,
                    op_path,
                    project;
                    path_anchor = path_anchor,
                    ignore_julia_version = opts.ignore_julia_version,
                )
            end
            if !report.ok
                println_err_after_progress("Prerequisites not met. Fix issues above and retry.")
                return Cint(1)
            end
            if selection_err !== nothing
                DistSSHRun.print_err("Error: "; bold = true)
                DistSSHRun.println_fatal(selection_err.msg)
                DistSSHRun.kit_println()
                return Cint(1)
            end
            DistSSHRun._warn_git_worktree_ship!(project)
            print_ok("All prerequisites met.")
            kit_println()
            return Cint(0)
        catch e
            DistSSHRun._report_manifest_refusal(e) || rethrow()
            return Cint(1)
        finally
            close_log_file()
        end
    end
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(doctor_main())
end
