function show_requirements(; io::IO = stdout)
    print_help_chrome(cli_heading("setup"); io = io)
    print_help_lines(
        io,
        "Deploy and check the project on SSH hosts before go / drive.",
        "Recommended: --rsync, --instantiate, --check, then optional --runtest.",
        "Hosts: child:NAME[:N] (same as go / drive / size; :N ignored).",
        "       parent is up, not setup.",
        "Remote path: ~/Parent/RepoName, or --remote-path / ENV.",
        "Git parity is drive --require-git (off by default).",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) setup MODE child:host1 child:host2",
        "  setup --rsync child:host1 child:host2",
        "  setup --instantiate child:host1 child:host2",
        "  setup --check child:host1 child:host2",
        "  setup --runtest child:host1 child:host2",
    )
    print_help_blank(io)
    print_help_section("Modes (one per run)"; io = io)
    print_help_lines(
        io,
        "  --rsync / --clone    empty remote path only",
        "                       --delete first to replace",
        "  --sync / --pull      git update (confirm unless -y)",
        "  --instantiate        Pkg.instantiate on remotes",
        "  --check              SSH, Julia, project, deps",
        "  --runtest            Pkg.test of the job project on remotes",
        "  --cleanup            stale workers",
        "  --delete             remote project tree (needs --confirm-path)",
        "  --prune              .distsshkit go/drive/setup/runs leaves (needs --confirm-path)",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  --repo URL           clone URL (default: origin)",
        "  --remote-path PATH   remote project root",
        "  --julia PATH         remote Julia",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes           skip confirmations except --delete and --prune",
        "  --confirm-path PATH  with --delete or --prune: the computed path (quote ~)",
        "  --hosts CSV          child:NAME[:N] (:N stripped)",
        "  --hosts-file PATH    one token per line (:N stripped)",
        "  --version, -v        print version and exit",
        "  --older-than DAYS    with --prune: mtime at least DAYS old",
        "  --id TOKEN           with --prune: go / runs leaf name contains TOKEN",
    )
    print_help_blank(io)
    print_help_lines(io, "  $(KIT_TIME_HELP)")
    print_help_blank(io)
    print_help_section("Environment"; io = io)
    print_help_lines(
        io,
        "  $(KIT_SKIP_PKILL_ENV_HELP)",
        "  $(KIT_JOBS_ENV_HELP)",
        "  DISTSSHKIT_YES            same as -y; does not authorize --delete or --prune",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (manual/setup). See also: go, drive, size.",
    )
end

function _setup_flag_mode(arg::AbstractString)::Union{Nothing, Symbol}
    arg == "--check" && return :check
    arg == "--pull" && return :pull
    arg == "--sync" && return :sync
    arg == "--instantiate" && return :instantiate
    arg == "--juliaup" && return :juliaup
    arg == "--juliaup-update" && return :juliaup_update
    arg == "--runtest" && return :runtest
    arg == "--cleanup" && return :cleanup
    arg == "--clone" && return :clone
    arg == "--delete" && return :delete
    arg == "--prune" && return :prune
    arg == "--rsync" && return :rsync_push
    arg == "--requirements" && return :requirements
    return nothing
end

function parse_setup_args(args::Vector{String})
    cli_session, args = peel_kit_cli_flags(args)
    mode = nothing
    multi_mode_warned = false
    julia_path = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")  # default to env or auto-detect
    repo_url = nothing
    remote_path_override = nothing
    hosts = String[]
    show_help = false
    ignore_julia_version = false
    older_days = nothing
    prune_id = nothing
    confirm_paths = String[]

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        flag_mode = _setup_flag_mode(arg)
        if flag_mode !== nothing
            if mode !== nothing && !multi_mode_warned
                @warn "Multiple setup modes specified; only the last mode takes effect. Passing more than one mode will be an error in DistSSHRun 0.2."
                multi_mode_warned = true
            end
            mode = flag_mode
            cli_consume!(c)
        elseif arg == "--confirm-path"
            raw = String(cli_take_value!(c, arg))
            _confirm_path_control_char(raw) && throw(
                ArgumentError("--confirm-path cannot contain a newline or NUL"),
            )
            raw = strip(raw)
            isempty(raw) && throw(ArgumentError("--confirm-path needs a non-empty path"))
            push!(confirm_paths, raw)
        elseif arg == "--older-than"
            raw = strip(cli_take_value!(c, arg))
            n = tryparse(Int, raw)
            (n !== nothing && n >= 0) || throw(
                ArgumentError(
                    "--older-than needs a non-negative integer day count, got $(repr(raw))",
                )
            )
            older_days = n
        elseif arg == "--id"
            prune_id = String(strip(cli_take_value!(c, arg)))
            isempty(prune_id) && throw(ArgumentError("--id needs a non-empty token"))
        elseif arg == "--julia"
            julia_path = cli_take_value!(c, arg)
        elseif arg == "--repo"
            repo_url = String(strip(cli_take_value!(c, arg)))
        elseif arg in ("--remote-path", "--remote-dir")
            remote_path_override = String(strip(cli_take_value!(c, arg)))
        elseif arg == "--ignore-julia-version"
            ignore_julia_version = true
            cli_consume!(c)
        elseif cli_match(c, ["-h", "--help"])
            show_help = true
            cli_consume!(c)
        elseif startswith(arg, "-") && length(arg) > 1
            throw(ArgumentError("unknown setup option: $arg"))
        else
            let p = parse_placement_token(arg)
                push!(hosts, p.role === :parent ? PARENT_HOST_NAME : p.name)
            end
            cli_consume!(c)
        end
    end

    append_kit_host_sources!(hosts, cli_session; keep_counts = false, roles = true)
    apply_kit_cli_session!(cli_session)

    if (older_days !== nothing || prune_id !== nothing) && mode !== :prune
        throw(ArgumentError("--older-than / --id only apply to setup --prune"))
    end
    if !isempty(confirm_paths) && mode !== :delete && mode !== :prune
        throw(ArgumentError("--confirm-path only applies to setup --delete or setup --prune"))
    end

    return (
        mode = mode,
        julia_path = julia_path,
        repo_url = repo_url,
        remote_path_override = remote_path_override,
        hosts = hosts,
        show_help = show_help,
        ignore_julia_version = ignore_julia_version,
        older_days = older_days,
        prune_id = prune_id,
        confirm_paths = confirm_paths,
        show_version = cli_session.show_version,
        cli_session = cli_session,
    )
end

show_usage(; io::IO = stdout) = show_requirements(; io)
setup_help_text()::String = sprint(io -> show_requirements(; io))
