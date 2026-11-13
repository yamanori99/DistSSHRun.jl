# Argument parsing for `hostinfo` (facts; no worker-count estimate).

function _absorb_parent_hosts!(hosts::Vector{String}, include_parent::Bool)::Bool
    kept = String[]
    inc = include_parent
    for h in hosts
        if is_parent_host_name(h)
            inc = true
        else
            push!(kept, h)
        end
    end
    empty!(hosts)
    append!(hosts, kept)
    return inc
end

function _hostinfo_parsed(;
        show_help::Bool,
        show_version::Bool,
        cli_session,
        include_parent::Bool,
        hosts::Vector{String},
        julia,
    )
    return (
        show_help = show_help,
        show_version = show_version,
        cli_session = cli_session,
        include_parent = include_parent,
        hosts = hosts,
        julia = julia,
    )
end

function show_hostinfo_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("hostinfo"); io = io)
    print_help_lines(
        io,
        "Show host identity, reachability, Julia, OS, CPU, and RAM.",
        "Per-host labeled layout (inspired by InteractiveUtils.versioninfo).",
        "Does not start a job. Missing fields print as `-`, not 0.",
        "A reachable host with missing Julia is still ok (exit 0).",
        "A failed host still gets a row; other hosts still print; exit 1.",
        "Requested rows go to stdout, including --quiet.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) hostinfo [parent] [child:NAME...]",
        "  hostinfo parent child:host1 child:host2",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  --julia PATH        remote Julia (default: auto-detect)",
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
        "Details: docs (API hostinfo). See also: pool, setup.",
        "Collection: DistSSHRun.DistSSHBase.collect_host_facts; print: print_hostinfo.",
    )
    return nothing
end

function parse_hostinfo_args(args::Vector{String})
    _reject_unknown_cli_options(
        args,
        "hostinfo";
        valued = ("--julia",),
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
    julia = nothing

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if cli_match(c, ["-h", "--help"])
            cli_consume!(c)
            return _hostinfo_parsed(;
                show_help = true,
                show_version = cli_session.show_version,
                cli_session = cli_session,
                include_parent = include_parent,
                hosts = hosts,
                julia = julia,
            )
        elseif cli_match(c, ["--local", "-l"]) || startswith(arg, "--local:") || startswith(arg, "-l:")
            throw_removed_local_flag(arg)
        elseif arg == "--parenthost" || arg == "--masterhost" || arg == "--parent"
            throw(
                ArgumentError(
                    "hostinfo: pass the token `parent` (e.g. hostinfo parent child:host1), not `--parenthost`.",
                )
            )
        elseif arg == "--probe" || arg == "--gb-per-worker" || arg == "--mem-headroom" ||
                arg == "--parent-gb" || arg == "--master-gb"
            throw(ArgumentError("hostinfo: worker-count sizing was removed; this command reports host facts only"))
        elseif arg == "--julia"
            julia = cli_take_value!(c, arg)
        elseif !startswith(arg, "-")
            let p = parse_placement_token(arg)
                push!(hosts, p.role === :parent ? PARENT_HOST_NAME : p.name)
            end
            cli_consume!(c)
        else
            throw(ArgumentError(_unknown_cli_option_message("hostinfo", arg)))
        end
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true)
    include_parent = _absorb_parent_hosts!(hosts, include_parent)
    apply_shared_cli_flags!(cli_session)

    return _hostinfo_parsed(;
        show_help = false,
        show_version = cli_session.show_version,
        cli_session = cli_session,
        include_parent = include_parent,
        hosts = hosts,
        julia = julia,
    )
end
