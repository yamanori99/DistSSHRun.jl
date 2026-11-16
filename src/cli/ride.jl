#!/usr/bin/env julia
"""
`julia -m DistSSHKit ride` — experimental auto-split of map / filter / comprehensions.

  julia --project=. -m DistSSHKit ride SCRIPT.jl
  julia --project=. -m DistSSHKit ride parent:2 SCRIPT.jl
  julia --project=. -m DistSSHKit ride parent:1 2*host1 SCRIPT.jl

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
include(joinpath(@__DIR__, "ride", "_using.jl"))

function ride_main()::Cint
    return DistSSHRun.DistSSHBase.with_cli_exit() do
        project_root = cli_project_root(@__DIR__)
        parsed = DistSSHRun.DistSSHBase.cli_parse(() -> parse_ride_args(ARGS))
        if parsed.show_version
            println_kit_version()
            return Cint(0)
        end
        if parsed.help
            return DistSSHRun.DistSSHBase.cli_help_stdout(show_ride_usage)
        end
        if parsed.script_path === nothing
            return DistSSHRun.DistSSHBase.cli_required_else_help(show_ride_usage)
        end
        diag = DistSSHRun.finish_run_job_diagnostics!(
            parsed;
            command = :ride,
            project = project_root,
            hosts = parsed.hosts,
            worker_tokens = DistSSHRun.host_tokens(parsed; kind = :ride),
        )
        diag !== nothing && return Cint(diag)
        tok = parsed.hosts
        remote_cli = get(parsed, :deploy_root, nothing)
        remote_raw = strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))
        result = try
            ride!(
                parsed.script_path,
                tok;
                args = parsed.script_args,
                spi_check = parsed.spi_check,
                output_dir = parsed.output_dir,
                project = project_root,
                julia = parsed.julia,
                head_workers = parsed.cli_session.head_workers,
                unsafe_skip_env_digests = parsed.unsafe_skip_env_digests,
                remote = remote_cli isa AbstractString ? remote_cli :
                    (isempty(remote_raw) ? nothing : remote_raw),
                run_id = parsed.run_id,
                hint_surface = :cli,
            )
        catch e
            if e isa ArgumentError
                DistSSHRun.print_cli_error(e.msg)
                return Cint(1)
            end
            rethrow()
        end
        if !(kit_output_progress() && result.ok)
            print_ride(result)
        end
        return result.ok ? Cint(0) : Cint(1)
    end
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(ride_main())
end