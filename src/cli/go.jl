#!/usr/bin/env julia
"""
`julia -m DistSSHKit go` — run an as-is complete job (no Kit APIs in the script).

Outputs: `{script}/.distsshkit/go/<stem>_<UTC>/<slot>/` (or `--output-dir`).

  julia --project=. -m DistSSHKit go SCRIPT.jl
  julia --project=. -m DistSSHKit go parent:2 child:user@h1 SCRIPT.jl

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
    project_root = cli_project_root(@__DIR__)
    path_anchor = DistSSHRun.canonical_local_path(project_root)
    original_args = copy(ARGS)
    parsed = parse_go_args(ARGS)
    if parsed.show_version
        println_kit_version()
        return 0
    end
    if parsed.help
        show_go_usage()
        return 0
    end
    # No script → same as drive with no args: show the command overview.
    if parsed.script_path === nothing
        show_go_usage()
        return 0
    end
    yes = parsed.cli_session.yes || kit_noninteractive()
    kw = execute_kwargs_from_parsed(parsed; kind = :go)
    result = go!(
        parsed.script_path,
        host_tokens(parsed; kind = :go);
        project = project_root,
        quiet = kw[:quiet],
        verbosity = kw[:verbosity],
        yes = yes,
        sync = kw[:sync],
        args = kw[:args],
        path_anchor = path_anchor,
        output_dir = kw[:output_dir],
        hosts_file = nothing,
        julia = kw[:julia],
        repeat = get(kw, :repeat, nothing),
        hint_surface = :cli,
        original_args = original_args,
    )
    report_go_errors(result)
    return result.ok ? 0 : 1
end

if get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", "") != "1" &&
        !isempty(PROGRAM_FILE) &&
        abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(go_main())
end
