# Argument parsing for `ride` (run-only).

function _ride_parsed(;
        help::Bool,
        show_version,
        cli_session,
        script_path,
        script_args,
        hosts,
        spi_check::Bool,
        output_dir,
        julia = nothing,
        run_id = nothing,
        deploy_root = nothing,
        unsafe_heterogeneous = false,
    )
    return (
        help = help,
        show_version = show_version,
        cli_session = cli_session,
        script_path = script_path,
        script_args = script_args,
        hosts = hosts,
        spi_check = spi_check,
        output_dir = output_dir,
        julia = julia,
        run_id = run_id,
        deploy_root = deploy_root,
        unsafe_heterogeneous = unsafe_heterogeneous,
    )
end

function show_ride_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("ride"); io = io)
    print_help_lines(
        io,
        "Experimental. Split map / filter / simple comprehensions / indexed for",
        "on Distributed workers.",
        "Rejects Distributed vocabulary (use drive).",
        "SSH child: uses the same worker-add path as drive (setup the project first).",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) ride SCRIPT.jl",
        "  ride parent:2 SCRIPT.jl",
        "  ride parent:1 child:host1:2 SCRIPT.jl",
        "  ride --spi-check parent:2 SCRIPT.jl",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  parent:N / child:NAME:N  Distributed workers (default: no tokens → parent:1)",
        "  omit :N             error (pass parent:N / child:NAME:N)",
        "  --spi-check         compare to sequential map/filter (default off)",
        "  --no-spi-check      skip that compare",
        "  --output-dir PATH   DISTRIBUTED_OUTPUT_DIR for the script (must be missing or empty)",
        "  --julia PATH        remote Julia (ENV or auto)",
        "  --deploy-root PATH  remote deployment root (location, not snapshot id).",
        "                      Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT, else the",
        "                      ~/Parent/RepoName layout from the local env_dir.",
        "  --run-id ID       use runs/<ID>/src under the deploy root",
        "  --unsafe-heterogeneous  allow Julia, packages, and environment files to differ across workers",
        "  SSH workers: project-root cwd, bind 127.0.0.1; environment mismatch is an error unless --unsafe-heterogeneous.",
        "  $(KIT_HOSTS_FLAG_HELP)",
        "  --hosts-file PATH   one token per line",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  --version, -v       print version and exit",
        "  -h, --help          this help",
    )
    print_help_blank(io)
    print_help_lines(
        io,
        "See also: go, drive, setup.",
        "API: ride!(script, \"parent:2\", \"child:host:1\"; spi_check=false, run_id=\"…\").",
    )
    return nothing
end

"""Parse `ride` CLI arguments (same shape as other kit CLI parsers)."""
function parse_ride_args(args::AbstractVector{<:AbstractString})
    cli_session, rest = peel_shared_cli_flags(args)
    hosts = String[]
    host_tokens = String[]
    script_path = nothing
    script_args = String[]
    output_dir = nothing
    julia_exe = nothing
    run_id = nothing
    deploy_root = nothing
    unsafe_heterogeneous = false
    spi_check = false
    options_done = false
    c = CliCursor(collect(String, rest))
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if options_done
            if endswith(arg, ".jl")
                script_path = arg
                cli_consume!(c)
                while !cli_at_end(c)
                    push!(script_args, cli_current(c)::String)
                    cli_consume!(c)
                end
                break
            elseif !startswith(arg, "-")
                push!(host_tokens, arg)
                cli_consume!(c)
            else
                throw(ArgumentError("unknown ride option: $arg"))
            end
            continue
        end
        if arg == "--analyze"
            throw(ArgumentError("ride: ride --analyze is not a flag"))
        elseif arg == "--output-dir"
            output_dir = cli_take_value!(c, arg)
        elseif arg == "--julia"
            julia_exe = cli_take_value!(c, arg)
        elseif arg == "--run-id"
            raw = strip(cli_take_value!(c, arg))
            isempty(raw) && throw(ArgumentError("ride: --run-id needs a non-empty id"))
            run_id = raw
        elseif _legacy_remote_path_arg(arg)
            _throw_legacy_remote_path("ride")
        elseif arg == DEPLOY_ROOT_FLAG
            deploy_root = _set_deploy_root!(
                deploy_root, _take_deploy_root!(c), "ride",
            )
        elseif arg == "--"
            options_done = true
            cli_consume!(c)
        elseif arg == "--unsafe-heterogeneous"
            unsafe_heterogeneous = true
            cli_consume!(c)
        elseif arg == "--spi-check"
            cli_consume!(c)
            spi_check = true
        elseif arg == "--no-spi-check"
            cli_consume!(c)
            spi_check = false
        elseif arg == "--help" || arg == "-h"
            cli_consume!(c)
            append!(hosts, host_tokens)
            append_kit_host_sources!(hosts, cli_session; keep_counts = true)
            if julia_exe === nothing
                env_val = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
                julia_exe = env_val == "auto" ? nothing : env_val
            elseif julia_exe == "auto"
                julia_exe = nothing
            end
            return _ride_parsed(;
                help = true,
                show_version = cli_session.show_version,
                cli_session = cli_session,
                script_path = script_path,
                script_args = script_args,
                hosts = hosts,
                spi_check = spi_check,
                output_dir = output_dir,
                julia = julia_exe,
                run_id = run_id,
                deploy_root = deploy_root,
                unsafe_heterogeneous = unsafe_heterogeneous,
            )
        elseif endswith(arg, ".jl")
            script_path = arg
            cli_consume!(c)
            while !cli_at_end(c)
                push!(script_args, cli_current(c)::String)
                cli_consume!(c)
            end
            break
        elseif !startswith(arg, "-")
            push!(host_tokens, arg)
            cli_consume!(c)
        else
            throw(ArgumentError("unknown ride option: $arg"))
        end
    end
    append!(hosts, host_tokens)
    append_kit_host_sources!(hosts, cli_session; keep_counts = true)
    for h in hosts
        parse_placement_token(h)
    end
    if julia_exe === nothing
        env_val = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
        julia_exe = env_val == "auto" ? nothing : env_val
    elseif julia_exe == "auto"
        julia_exe = nothing
    end
    apply_shared_cli_flags!(cli_session)
    if script_path !== nothing
        require_counted_placement_tokens(hosts; surface = :cli)
    end
    return _ride_parsed(;
        help = false,
        show_version = cli_session.show_version,
        cli_session = cli_session,
        script_path = script_path,
        script_args = script_args,
        hosts = hosts,
        spi_check = spi_check,
        output_dir = output_dir,
        julia = julia_exe,
        run_id = run_id,
        deploy_root = deploy_root,
        unsafe_heterogeneous = unsafe_heterogeneous,
    )
end
