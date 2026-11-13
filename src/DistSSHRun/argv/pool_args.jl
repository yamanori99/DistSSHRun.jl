# Argument parsing for `pool` (inventory + health; no slot estimate).

function _pool_parsed(;
        show_help::Bool,
        show_version::Bool,
        cli_session,
        include_parent::Bool,
        hosts::Vector{String},
    )
    return (
        show_help = show_help,
        show_version = show_version,
        cli_session = cli_session,
        include_parent = include_parent,
        hosts = hosts,
    )
end

function show_pool_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("pool"); io = io)
    print_help_lines(
        io,
        "Show cluster cores, RAM, and reachability. Does not start a job.",
        "Fail-closed: unreachable listed hosts make the command fail.",
        "Does not recommend a worker count. Use explicit parent:N / child:NAME:N.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) pool [parent] [child:NAME...]",
        "  pool parent child:host1 child:host2",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  --hosts CSV         parent / child:NAME[:N] (:N stripped)",
        "  --hosts-file PATH   same, one token per line",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  --version, -v       print version and exit",
        "  -h, --help          this help",
    )
    print_help_blank(io)
    print_help_lines(
        io,
        "Details: docs (API pool). See also: hostinfo, setup.",
        "API: pool!(session) -> ResourcePool.",
    )
    return nothing
end

function parse_pool_args(args::Vector{String})
    _reject_unknown_cli_options(
        args,
        "pool";
        valued = (),
        known = (
            "-h", "--help",
            "--local", "-l",
            "--parenthost", "--masterhost", "--parent",
            "--probe",
            "--gb-per-worker",
            "--mem-headroom",
            "--parent-gb",
            "--master-gb",
        ),
        prefixes = ("--local:", "-l:"),
    )
    cli_session, args = peel_shared_cli_flags(args)
    include_parent = false
    hosts = String[]

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if cli_match(c, ["-h", "--help"])
            cli_consume!(c)
            return _pool_parsed(;
                show_help = true,
                show_version = cli_session.show_version,
                cli_session = cli_session,
                include_parent = include_parent,
                hosts = hosts,
            )
        elseif cli_match(c, ["--local", "-l"]) || startswith(arg, "--local:") || startswith(arg, "-l:")
            throw_removed_local_flag(arg)
        elseif arg == "--parenthost" || arg == "--masterhost" || arg == "--parent"
            throw(
                ArgumentError(
                    "pool: pass the token `parent` (e.g. pool parent child:host1), not `--parenthost`.",
                )
            )
        elseif arg == "--probe" || arg == "--gb-per-worker" || arg == "--mem-headroom" ||
                arg == "--parent-gb" || arg == "--master-gb"
            throw(ArgumentError("pool: worker-count sizing was removed; pool reports cores and RAM only"))
        elseif !startswith(arg, "-")
            let p = parse_placement_token(arg)
                push!(hosts, p.role === :parent ? PARENT_HOST_NAME : p.name)
            end
            cli_consume!(c)
        else
            throw(ArgumentError(_unknown_cli_option_message("pool", arg)))
        end
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true)
    include_parent = _absorb_parent_hosts!(hosts, include_parent)
    apply_shared_cli_flags!(cli_session)

    return _pool_parsed(;
        show_help = false,
        show_version = cli_session.show_version,
        cli_session = cli_session,
        include_parent = include_parent,
        hosts = hosts,
    )
end
