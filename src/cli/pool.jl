#!/usr/bin/env julia
"""
`julia -m DistSSHKit pool` — cluster cores / RAM / health (no job).

  julia --project=. -m DistSSHKit pool parent child:host1 child:host2

See `--help`.
"""

if !isdefined(@__MODULE__, :DistSSHRun)
    if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") == "1"
        import DistSSHRun
    else
        try
            import DistSSHRun
        catch
            include(joinpath(@__DIR__, "_checkout.jl"))
            _include_checkout_run()
            import DistSSHRun
        end
    end
end
include(joinpath(@__DIR__, "pool", "_using.jl"))

function pool_main()::Cint
    project_root = cli_project_root(@__DIR__)
    path_anchor = DistSSHRun.canonical_local_path(project_root)
    opts = parse_pool_args(ARGS)
    if opts.show_help
        show_pool_usage()
        return 0
    end
    if opts.show_version
        DistSSHRun.println_kit_version()
        return 0
    end
    tokens = String[]
    opts.include_parent && push!(tokens, "parent")
    for h in opts.hosts
        push!(tokens, "child:$h")
    end
    if isempty(tokens)
        show_pool_usage()
        return 0
    end

    print_header(DistSSHRun.cli_heading("pool"))
    DistSSHRun.writeln_field("Project", cli_project_disp(project_root, path_anchor))
    DistSSHRun.kit_println()

    session = DistSSHRun.KitSession(
        project = project_root,
        workers = tokens,
        quiet = opts.cli_session.quiet,
        verbosity = opts.cli_session.verbosity,
        yes = opts.cli_session.yes,
    )
    result = pool!(
        session;
        gb_per_worker = opts.gb_per_worker,
        mem_headroom = opts.mem_headroom,
        parent_gb = opts.parent_gb,
    )
    print_pool(result)
    return result.ok ? 0 : 1
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(pool_main())
end
