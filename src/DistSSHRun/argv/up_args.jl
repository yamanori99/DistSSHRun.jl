function show_up_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("up"); io = io)
    print_help_lines(
        io,
        "juliaup verbs: add, default, update, status.",
        "Hosts: plain SSH names (optional :N suffix is stripped; counts belong on drive/go).",
        "Omit hosts to touch only this machine (kit parent / local juliaup).",
        "add installs a channel. default switches to it.",
        "update with no channel updates every installed channel.",
        "status prints one line per host (channel, installed patch, available update).",
        "A worker line also says how that patch sits against the local controller. The controller line does not.",
        "--verbose also prints the juliaup rows. Skew in that line is not an error.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) up add 1.13 host1",
        "  up default 1.13 $(kit_head_host_label())",
        "  up update host1",
        "  up update 1.13",
        "  up status",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes           skip confirmations",
        "  --hosts CSV          plain host names (:N suffix stripped)",
        "  --hosts-file PATH    one token per line (:N stripped)",
        "  --version, -v        print version and exit",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (manual/setup). See also: setup, go.",
    )
end

function _looks_like_up_channel(arg::AbstractString)::Bool
    s = String(strip(arg))
    occursin(r"^\d+\.\d+", s) && return true
    s in ("release", "lts", "nightly", "alpha", "beta", "rc") && return true
    return false
end

function _looks_like_up_host(arg::AbstractString)::Bool
    s = String(strip(arg))
    is_parent_host_name(s) && return true
    findfirst('*', s) !== nothing && return true
    colon = findfirst(':', s)
    if colon !== nothing
        base = strip(s[1:(colon - 1)])
        is_parent_host_name(base) && return true
    end
    try
        DistSSHBase.parse_machine_token(s)
        return true
    catch
        return false
    end
end

function _up_absorb_host!(hosts::Vector{String}, arg::AbstractString)
    s = String(strip(arg))
    star = findfirst('*', s)
    star !== nothing && (s = String(strip(s[(star + 1):end])))
    throw_legacy_placement_token(s)
    if is_parent_host_name(s)
        push!(hosts, PARENT_HOST_NAME)
        return nothing
    end
    colon = findfirst(':', s)
    if colon !== nothing
        base = strip(s[1:(colon - 1)])
        is_parent_host_name(base) && throw(
            ArgumentError(
                join_explained_message(
                    "up: $(repr(arg)) was removed",
                    "Use plain host names; optional :N is ignored. " *
                        "For this machine omit the host or pass --hosts $(PARENT_HOST_NAME).",
                ),
            ),
        )
        s = String(strip(s[(colon + 1):end]))
        isempty(s) && throw(ArgumentError("up: empty host after ':' in $(repr(arg))"))
    end
    p = DistSSHBase.parse_machine_token(s)
    dest = String(p.dest)
    push!(hosts, is_parent_host_name(dest) ? PARENT_HOST_NAME : dest)
    return nothing
end

function parse_up_args(args::Vector{String})
    cli_session, args = peel_shared_cli_flags(args)
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
        elseif channel === nothing && verb in ("add", "default")
            channel = arg
            cli_consume!(c)
        elseif channel === nothing && verb == "update" &&
                (_looks_like_up_channel(arg) || !_looks_like_up_host(arg))
            channel = arg
            cli_consume!(c)
        else
            _up_absorb_host!(hosts, arg)
            cli_consume!(c)
        end
    end
    if !isempty(verb) && verb in ("add", "default") && !show_help
        channel === nothing &&
            throw(ArgumentError("$verb needs a channel: $(cli_m()) up $verb 1.13 …"))
        is_parent_host_name(something(channel, "")) &&
            throw(ArgumentError("$verb needs a channel: $(cli_m()) up $verb 1.13 …"))
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true)
    apply_shared_cli_flags!(cli_session)

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
