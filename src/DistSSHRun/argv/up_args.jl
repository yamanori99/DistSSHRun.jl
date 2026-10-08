function show_up_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("up"); io = io)
    print_help_lines(
        io,
        "juliaup verbs: add, default, update, status.",
        "Hosts: child:NAME[:N] and parent[:N] (:N ignored).",
        "add installs a channel. default switches to it.",
        "update with no channel updates every installed channel.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) up add 1.13 child:host1",
        "  up default 1.13 parent",
        "  up update child:host1",
        "  up update 1.13 parent",
        "  up status parent",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes           skip confirmations",
        "  --hosts CSV          child:NAME[:N] or parent[:N] (:N stripped)",
        "  --hosts-file PATH    one token per line (:N stripped)",
        "  --version, -v        print version and exit",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (manual/setup). See also: setup, go.",
    )
end

function _up_host_token(arg::AbstractString)::Bool
    a = String(arg)
    return a == "parent" || startswith(a, "parent:") || startswith(a, "child:")
end

function parse_up_args(args::Vector{String})
    cli_session, args = peel_kit_cli_flags(args)
    verb = ""
    channel = nothing
    hosts = String[]
    show_help = false
    verbs = ("add", "default", "update", "status")

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if arg in verbs && isempty(verb) && isempty(hosts)
            verb = arg
            cli_consume!(c)
        elseif arg in verbs
            throw(ArgumentError("`$arg` comes first: $(cli_m()) up $arg …"))
        elseif cli_match(c, ["-h", "--help"])
            show_help = true
            cli_consume!(c)
        elseif startswith(arg, "-")
            throw(ArgumentError("unknown up option: $(arg)"))
        elseif isempty(verb)
            throw(ArgumentError("up needs add, default, update, or status: $(cli_m()) up add 1.13 …"))
        elseif channel === nothing && !_up_host_token(arg)
            channel = arg
            cli_consume!(c)
        else
            let p = parse_placement_token(arg)
                push!(hosts, p.role === :parent ? PARENT_HOST_NAME : p.name)
            end
            cli_consume!(c)
        end
    end
    if !isempty(verb) && verb in ("add", "default") && channel === nothing && !show_help
        throw(ArgumentError("$verb needs a channel: $(cli_m()) up $verb 1.13 …"))
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true)
    apply_kit_cli_session!(cli_session)

    return (
        verb = verb,
        channel = channel,
        hosts = hosts,
        show_help = show_help,
        show_version = cli_session.show_version,
        cli_session = cli_session,
    )
end

up_help_text()::String = sprint(io -> show_up_usage(; io))
