#!/usr/bin/env julia
"""
`julia -m DistSSHKit size` — estimate worker counts from RAM/CPU.

  julia --project=. -m DistSSHKit size parent child:host1 child:host2
  julia --project=. -m DistSSHKit size --gb-per-worker 1.5 child:host1

See `--help`.
"""

if !isdefined(@__MODULE__, :DistSSHRun)
    if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") == "1"
        import DistSSHRun
    else
        try
            import DistSSHRun
        catch
            include(joinpath(@__DIR__, "..", "DistSSHRun.jl"))
        end
    end
end
include(joinpath(@__DIR__, "size", "_using.jl"))

const PROJECT_ROOT = cli_project_root(@__DIR__)
const _PATH_ANCHOR = DistSSHRun.canonical_local_path(PROJECT_ROOT)

function size_main()::Cint
    opts = parse_size_args(ARGS)
    if opts.show_help
        show_size_usage()
        return 0
    end
    if opts.show_version
        DistSSHRun.println_kit_version()
        return 0
    end
    hosts = opts.hosts
    all_hosts = opts.include_parent ? [DistSSHRun.PARENT_HOST_NAME; hosts] : hosts

    if isempty(all_hosts)
        show_size_usage()
        return 0
    end

    print_header("DistSSHRun size")
    DistSSHRun.writeln_field("Project", cli_project_disp(PROJECT_ROOT, _PATH_ANCHOR))
    DistSSHRun.kit_println()

    samples = resolve_worker_memory_samples(PROJECT_ROOT, all_hosts, hosts, opts)
    samples === nothing && return 1
    DistSSHRun.kit_println()

    print_size_report(
        all_hosts, hosts, samples, opts;
        show_peak = (opts.probe !== nothing && opts.gb_per_worker === nothing),
    )
    return 0
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    size_main()
end
