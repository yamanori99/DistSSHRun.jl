#!/usr/bin/env julia
"""
`julia -m DistSSHKit plan` — inspect a script; do not start a job.

  julia --project=. -m DistSSHKit plan SCRIPT.jl

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
include(joinpath(@__DIR__, "plan", "_using.jl"))

function plan_main()::Cint
    project_root = cli_project_root(@__DIR__)
    opts = try
        parse_plan_args(ARGS)
    catch e
        e isa ArgumentError || rethrow()
        startswith(e.msg, "unknown plan option:") || rethrow()
        DistSSHRun.print_cli_error(e.msg)
        return Cint(1)
    end
    if opts.show_help
        show_plan_usage()
        return 0
    end
    if opts.show_version
        DistSSHRun.println_kit_version()
        return 0
    end
    if opts.script_path === nothing
        show_plan_usage()
        return 0
    end
    kp = plan(
        opts.script_path;
        workers = opts.tokens,
        project = project_root,
        gb_per_worker = opts.gb_per_worker,
        probe = opts.probe,
        mem_headroom = opts.mem_headroom,
        parent_gb = opts.parent_gb,
    )
    print_plan(kp)
    return kp.ok ? 0 : 1
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(plan_main())
end
