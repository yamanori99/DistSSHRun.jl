#!/usr/bin/env julia
"""
`julia -m DistSSHKit go` — run an as-is complete job (no Kit APIs in the script).

Outputs: `{script}/.distssh/go/<stem>_<UTC>/<slot>/` (or `--output-dir`).

  julia --project=. -m DistSSHKit go SCRIPT.jl
  julia --project=. -m DistSSHKit go parent:2 user@h1 SCRIPT.jl

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
include(joinpath(@__DIR__, "go", "_using.jl"))

function go_main()::Cint
    return DistSSHRun.DistSSHBase.with_cli_exit() do
        project_root = cli_project_root(@__DIR__)
        path_anchor = DistSSHRun.canonical_local_path(project_root)
        original_args = copy(ARGS)
        parsed = DistSSHRun.DistSSHBase.cli_parse(() -> parse_go_args(ARGS))
        if parsed.show_version
            println_kit_version()
            return Cint(0)
        end
        if parsed.help
            return DistSSHRun.DistSSHBase.cli_help_stdout(show_go_usage)
        end
        if parsed.script_path === nothing
            return DistSSHRun.DistSSHBase.cli_required_else_help(show_go_usage)
        end
        diag = DistSSHRun.finish_run_job_diagnostics!(
            parsed;
            command = :go,
            project = project_root,
            hosts = parsed.hosts,
            worker_tokens = host_tokens(parsed; kind = :go),
        )
        diag !== nothing && return Cint(diag)
        kw = execute_kwargs_from_parsed(parsed; kind = :go)
        result = try
            go!(
                parsed.script_path,
                host_tokens(parsed; kind = :go);
                head_slots = parsed.cli_session.head_slots,
                project = project_root,
                quiet = kw[:quiet],
                verbosity = kw[:verbosity],
                args = kw[:args],
                path_anchor = path_anchor,
                output_dir = kw[:output_dir],
                hosts_file = parsed.cli_session.hosts_file,
                julia = kw[:julia],
                unsafe_skip_env_digests = get(parsed, :unsafe_skip_env_digests, missing),
                unsafe_expose_port = get(parsed, :unsafe_expose_port, missing),
                unsafe_all_to_all = get(parsed, :unsafe_all_to_all, missing),
                repeat = get(kw, :repeat, nothing),
                run_id = get(parsed, :run_id, nothing),
                remote = get(parsed, :deploy_root, nothing),
                hint_surface = :cli,
                original_args = original_args,
            )
        catch e
            if e isa DistSSHRun.DistSSHBase.CliUsageError
                rethrow()
            elseif e isa ArgumentError
                if DistSSHRun._report_manifest_refusal(e)
                    return Cint(1)
                end
                throw(DistSSHRun.DistSSHBase.CliUsageError(DistSSHRun._bind_config_cli_message(e.msg)))
            end
            rethrow()
        end
        report_go_errors(result)
        return result.ok ? Cint(0) : Cint(1)
    end
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(go_main())
end
