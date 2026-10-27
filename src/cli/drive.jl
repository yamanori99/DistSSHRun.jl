#!/usr/bin/env julia
"""
`julia -m DistSSHKit drive` — run a driver on local/SSH workers, then collect remote outputs.

  julia --project=. -m DistSSHKit drive
  julia --project=. -m DistSSHKit drive parent:9 child:host1:10 script.jl
  julia --project=. -m DistSSHKit drive --collect-missing data/out host1 host2

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
include(joinpath(@__DIR__, "drive", "_using.jl"))

function _restore_drive_args!(original_args::Vector{String})
    empty!(ARGS)
    return append!(ARGS, original_args)
end

function drive_main()::Cint
    original_args = copy(ARGS)
    try
        return _drive_main_body(original_args)
    finally
        _restore_drive_args!(original_args)
    end
end

function _drive_main_body(original_args::Vector{String})::Cint
    try
        parsed = parse_drive_args(ARGS)
        return run_drive_parsed!(
            parsed;
            original_args = original_args,
            project_root = cli_project_root(@__DIR__),
        )
    catch e
        DistSSHRun._report_manifest_refusal(e) || rethrow()
        return Cint(1)
    end
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(drive_main())
end
