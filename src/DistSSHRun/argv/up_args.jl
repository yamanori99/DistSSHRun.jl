function show_up_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("up"); io = io)
    print_help_lines(
        io,
        "Align a host's Julia channel with juliaup: add, update, and default.",
        "Hosts: child:NAME[:N] and parent[:N] (:N ignored).",
        "up update runs juliaup update only and leaves the default.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) up child:host1 child:host2",
        "  up parent child:host1",
        "  up update child:host1",
        "  up update parent",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes            skip confirmations",
        "  --hosts CSV          child:NAME[:N] or parent[:N] (`:N` stripped)",
        "  --hosts-file PATH    one token per line (`:N` stripped)",
        "  --version, -v        print version and exit",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (manual/setup). See also: setup, go.",
    )
end

function parse_up_args(args::Vector{String})
    cli_session, args = peel_kit_cli_flags(args)
    update = false
    hosts = String[]
    show_help = false

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if arg == "update" && !update && isempty(hosts)
            update = true
            cli_consume!(c)
        elseif arg == "update"
            throw(ArgumentError("`update` comes before hosts: $(cli_m()) up update …"))
        elseif arg in ("--juliaup", "--juliaup-update")
            gone = arg == "--juliaup-update" ? "up update" : "up"
            throw(ArgumentError("$arg is now: $(cli_m()) $gone"))
        elseif cli_match(c, ["-h", "--help"])
            show_help = true
            cli_consume!(c)
        elseif startswith(arg, "-")
            throw(ArgumentError("unknown up option: $(arg)"))
        else
            let p = parse_placement_token(arg)
                push!(hosts, p.role === :parent ? PARENT_HOST_NAME : p.name)
            end
            cli_consume!(c)
        end
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true)
    apply_kit_cli_session!(cli_session)

    return (
        update = update,
        hosts = hosts,
        show_help = show_help,
        show_version = cli_session.show_version,
        cli_session = cli_session,
    )
end

up_help_text()::String = sprint(io -> show_up_usage(; io))
