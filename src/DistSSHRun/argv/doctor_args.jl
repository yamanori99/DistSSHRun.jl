# `julia -m DistSSHKit doctor --deploy …`

function show_doctor_requirements(; io::IO = stdout)
    print_help_chrome(cli_heading("doctor"); io = io)
    print_help_lines(
        io,
        "Verify hosts before go / drive / ride (replaces setup check).",
        "0.2.0 supports --deploy only; more groups ship in 0.2.x.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) doctor --deploy host1 host2",
        "  $(cli_m_project()) doctor --deploy --run-id ID host1",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  --deploy             required: full deploy prerequisite check",
        "  --deploy-root PATH   same as setup (remote deployment root)",
        "  --run-id ID          runs/<ID>/ under that root",
        "  --julia PATH         remote Julia (default: auto / JULIA_DISTRIBUTED_EXE)",
        "  --ignore-julia-version  warn on Julia skew instead of failing",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  --hosts CSV          placement tokens",
        "  --hosts-file PATH    one host per line",
        "  --version, -v        print version and exit",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "See also: setup instantiate, go, drive.",
    )
end

function parse_doctor_args(args::Vector{String})
    _reject_unknown_cli_options(
        args,
        "doctor";
        valued = (DEPLOY_ROOT_FLAG, "--run-id", "--julia"),
        known = (
            "--deploy", "--ignore-julia-version",
            "-h", "--help", "--",
        ),
        bare_dash = true,
    )
    cli_session, args = peel_shared_cli_flags(args)
    deploy = false
    julia_path = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
    deploy_root = nothing
    run_id = nothing
    hosts = String[]
    show_help = false
    ignore_julia_version = false
    options_done = false

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if options_done
            push!(hosts, parse_setup_host_token(arg))
            cli_consume!(c)
            continue
        end
        if arg == "--"
            options_done = true
            cli_consume!(c)
            continue
        end
        if arg == "--deploy"
            deploy = true
            cli_consume!(c)
            continue
        end
        if _legacy_remote_path_arg(arg)
            _throw_legacy_remote_path("doctor")
        elseif arg == DEPLOY_ROOT_FLAG
            deploy_root = _set_deploy_root!(
                deploy_root, _take_deploy_root!(c), "doctor",
            )
        elseif arg == "--run-id"
            raw = String(strip(cli_take_value!(c, arg)))
            isempty(raw) && throw(ArgumentError("--run-id needs a non-empty id"))
            run_id = raw
        elseif arg == "--julia"
            julia_path = cli_take_value!(c, arg)
        elseif arg == "--ignore-julia-version"
            ignore_julia_version = true
            cli_consume!(c)
        elseif cli_match(c, ["-h", "--help"])
            show_help = true
            cli_consume!(c)
        elseif startswith(arg, "-") && length(arg) > 1
            throw(ArgumentError(_unknown_cli_option_message("doctor", arg)))
        else
            push!(hosts, parse_setup_host_token(arg))
            cli_consume!(c)
        end
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true, for_setup = true)
    apply_shared_cli_flags!(cli_session)

    return (
        deploy = deploy,
        julia_path = julia_path,
        deploy_root = deploy_root,
        run_id = run_id,
        hosts = hosts,
        show_help = show_help,
        ignore_julia_version = ignore_julia_version,
        show_version = cli_session.show_version,
        cli_session = cli_session,
    )
end

show_doctor_usage(; io::IO = stdout) = show_doctor_requirements(; io)
doctor_help_text()::String = sprint(io -> show_doctor_requirements(; io))
