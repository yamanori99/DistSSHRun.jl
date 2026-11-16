#!/usr/bin/env julia
"""
`julia -m DistSSHKit hostinfo` — per-host identity, Julia, OS, CPU, RAM.

  julia --project=. -m DistSSHKit hostinfo parent host1 host2

See `--help`.
"""

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
include(joinpath(@__DIR__, "hostinfo", "_using.jl"))

function hostinfo_main()::Cint
    return DistSSHRun.DistSSHBase.with_cli_exit() do
        project_root = cli_project_root(@__DIR__)
        path_anchor = DistSSHRun.canonical_local_path(project_root)
        opts = DistSSHRun.DistSSHBase.cli_parse(() -> parse_hostinfo_args(ARGS))
        if opts.show_help
            return DistSSHRun.DistSSHBase.cli_help_stdout(show_hostinfo_usage)
        end
        if opts.show_version
            DistSSHRun.println_kit_version()
            return Cint(0)
        end
        print_header(DistSSHRun.cli_heading("hostinfo"))
        DistSSHRun.writeln_field("Project", cli_project_disp(project_root, path_anchor))
        DistSSHRun.kit_println()

        session = DistSSHRun.DistSSHSession(
            project = project_root,
            workers = opts.hosts,
            include_head_for_size = true,
            quiet = opts.cli_session.quiet,
            verbosity = opts.cli_session.verbosity,
            yes = opts.cli_session.yes,
        )
        DistSSHRun.apply_session_env!(session)
        hosts = DistSSHRun.session_inventory_hosts(session)
        rows = DistSSHRun.DistSSHBase.collect_host_facts(hosts; julia = opts.julia)
        print_hostinfo(rows)
        return all(r -> r.reachable, rows) ? Cint(0) : Cint(1)
    end
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(hostinfo_main())
end