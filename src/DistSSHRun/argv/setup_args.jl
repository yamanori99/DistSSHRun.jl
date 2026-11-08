# Grammar (CLI contract):
#
#   julia -m DistSSHKit setup [shared] SUBCOMMAND [options] [child:HOST...]
#
# Top-level `setup` is a preparation/maintenance namespace, not a job runner.
# Exactly one SUBCOMMAND per invocation. Shared kit flags (`-q`, `--yes`,
# `--hosts`, `--hosts-file`, `--version`) may appear anywhere and are peeled
# first. `--` ends option parsing; remaining tokens are hosts.
#
# SUBCOMMAND (canonical names; one per run):
#   ship-tree     transfer/verify only (does not instantiate)
#   instantiate   Pkg.instantiate on the selected snapshot or git work root
#   check         verify selected snapshot / git checkout (not a marker later
#                 executions require)
#   runtest       Pkg.test of the job project
#   cleanup       stale workers
#   clone         git clone onto an empty dest
#   delete        remove the computed remote tree (--confirm-path)
#   prune         kit leaves (--confirm-path; --older-than / --id)
#   remote-root   BOOLEAN mkdir of an absolute --deploy-root PATH (not a
#                 path-valued option; parent must exist; not mkdir -p)
#   sync          git push + detach
#   pull          git detach (no push)
#   requirements  print this page (same as `setup` with no subcommand)
#
# Location:
#   --deploy-root PATH   deployment root override (not snapshot id). Omit to
#                        use DISTRIBUTED_REMOTE_PROJECT_ROOT, else ~/Parent/Repo
#                        from the local package env_dir (workspace Manifest
#                        member maps under that root). Does not rename ENV.
#   --snapshot ID        instantiate / check / runtest only
#
# Legacy (error, not aliases):
#   setup --ship-tree / --instantiate / --check / … → setup <subcommand>
#   --remote-path PATH → --deploy-root PATH
#   --remote-dir → --deploy-root
#   --juliaup / --juliaup-update / --rsync remain removed
#   go / drive --ship-tree stay convenience flags (not this namespace)
#
# Ambiguous combinations fail before remote side effects.

function show_requirements(; io::IO = stdout)
    print_help_chrome(cli_heading("setup"); io = io)
    print_help_lines(
        io,
        "Deploy and check the project on SSH hosts before go / drive.",
        "Recommended: ship-tree, instantiate, check, then optional runtest.",
        "  After ship-tree, instantiate/check/go use that snapshot id (local",
        "  last-snapshot record, or pass --snapshot ID). Lexical latest is not used.",
        "  A git checkout at the deploy root remains usable without --snapshot;",
        "  delete/clone/sync/pull clear the matching local last-snapshot record.",
        "Hosts: child:NAME[:N] (same as go / drive; :N ignored).",
        "       parent is up, not setup.",
        "Remote path: omit --deploy-root to use DISTRIBUTED_REMOTE_PROJECT_ROOT,",
        "  else ~/Parent/RepoName from the local package env_dir (a workspace",
        "  Manifest member maps under that root). Pass --deploy-root PATH to override.",
        "Ship creates a missing remote_root when safe: ~/… under home (mode 700),",
        "  or an absolute path when its parent already exists (same leaf rule as",
        "  setup remote-root).",
        "  Absolute roots also refuse /, a single dir under /, . / .., and this home.",
        "setup remote-root still requires an absolute --deploy-root PATH.",
        "--ship-tree walks the project directory you passed and each .gitignore",
        "  there and below (case-sensitive). It does not widen to a workspace Manifest.",
        ".git/info/exclude, core.excludesFile, and a .gitignore above that",
        "  directory are not used. No git binary is run.",
        "A Manifest or path dependency outside that directory is left out, with a warning.",
        "A gitignored Project.toml, JuliaProject.toml, Manifest.toml, or",
        "  JuliaManifest.toml is left out, with one warning.",
        "A gitignored LocalPreferences.toml is left out. Add !LocalPreferences.toml to ship it.",
        "A file over 50 MiB, or a send list over 100 MiB, prints a warning (local sizes).",
        "DISTSSHKIT_SHIP_WARN_FILE_BYTES and DISTSSHKIT_SHIP_WARN_TOTAL_BYTES set those",
        "  limits. An invalid value is an error. The 256 MiB cap still stops the ship.",
        "Declared inputs do not ship.",
        "Ship and collect use Tar. Original mtimes are not kept.",
        "Pull-back touches extracted files. Ship keeps extract-time mtime.",
        "Modes are 0644, or 0755 if executable. push_cache! uses Tar and a remote Julia.",
        "Remote login shell must be POSIX (sh, bash, dash, or zsh).",
        "ssh runs a command as \$SHELL -c, not a login shell.",
        "Distributed starts workers with sh -l -c; that wrap cannot be changed.",
        "fish and csh are unsupported.",
        "fish can silently change quoting (backslashes inside single quotes).",
        "An SSH name must not start with '-' (including user@-host).",
        "A host or remote path must not contain NUL, a newline, or another control character.",
        "Git parity is drive --require-git (off by default).",
        "setup check fails when Julia patch or prerelease differs from this process.",
        "A build suffix alone still passes. --ignore-julia-version turns skew into a warning.",
        "go and drive compare the full VERSION string and the Julia commit.",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) setup SUBCOMMAND child:host1 child:host2",
        "  setup ship-tree child:host1 child:host2",
        "  setup instantiate child:host1 child:host2",
        "  setup check child:host1 child:host2",
        "  setup runtest child:host1 child:host2",
        "  setup ship-tree --deploy-root /abs/deploy child:host1",
        "  setup remote-root --deploy-root /abs/deploy child:host1",
    )
    print_help_blank(io)
    print_help_section("Subcommands (one per run)"; io = io)
    print_help_lines(
        io,
        "  remote-root        create that absolute --deploy-root PATH only",
        "  ship-tree / clone  ship-tree writes runs/<run_id>/src/, out/,",
        "                     and a DistSSHRun run.toml stamp; does not instantiate",
        "                     clone needs an empty remote path",
        "                     delete first to replace a clone dest",
        "  sync / pull        git update (confirm unless -y)",
        "  instantiate        Pkg.instantiate on remotes",
        "  check              SSH, Julia, project, deps (patch and prerelease must match)",
        "  runtest            Pkg.test of the job project on remotes",
        "  cleanup            stale workers",
        "  delete             remote project tree (needs --confirm-path;",
        "                     refuses an unowned Ship run.toml)",
        "  prune              .distsshkit go/drive/setup/runs leaves (needs --confirm-path;",
        "                     same ownership check on those candidates)",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  --repo URL           clone URL (default: origin)",
        "  --deploy-root PATH   remote deployment root (location, not snapshot id).",
        "                       Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT, else the",
        "                       ~/Parent/RepoName layout from the local env_dir.",
        "  --snapshot ID        runs/<ID>/ under that root (instantiate/check/runtest)",
        "  --allow-external-symlinks  with ship-tree: keep escaping symlinks",
        "  --julia PATH         remote Julia",
        "  --ignore-julia-version  warn on Julia version skew instead of failing",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes           skip confirmations except delete and prune",
        "  --confirm-path PATH  with delete or prune: the computed path (quote ~)",
        "  --hosts CSV          child:NAME[:N] (:N stripped)",
        "  --hosts-file PATH    one token per line (:N stripped)",
        "  --version, -v        print version and exit",
        "  --older-than DAYS    with prune: mtime at least DAYS old",
        "  --id TOKEN           with prune: go / runs leaf name contains TOKEN",
    )
    print_help_blank(io)
    print_help_lines(io, "  $(KIT_TIME_HELP)")
    print_help_blank(io)
    print_help_section("Environment"; io = io)
    print_help_lines(
        io,
        "  $(KIT_SKIP_PKILL_ENV_HELP)",
        "  $(KIT_JOBS_ENV_HELP)",
        "  DISTSSHKIT_YES            same as -y; does not authorize delete or prune",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (manual/setup). See also: go, drive, hostinfo.",
    )
end

function _throw_setup_juliaup_removed(flag::AbstractString)
    instead = flag == "--juliaup-update" ?
        "`$(cli_m()) up update`" :
        "`$(cli_m()) up add CHANNEL`, `$(cli_m()) up update CHANNEL`, and `$(cli_m()) up default CHANNEL`"
    throw(
        ArgumentError(
            "setup $flag was removed in 0.2.0; use $instead. See help up.",
        ),
    )
end

function _throw_setup_remote_dir_removed()
    throw(
        ArgumentError(
            "setup --remote-dir was removed; use $(DEPLOY_ROOT_FLAG) PATH. See help setup.",
        ),
    )
end

const _SETUP_SUBCOMMANDS = (
    "check" => :check,
    "pull" => :pull,
    "sync" => :sync,
    "instantiate" => :instantiate,
    "runtest" => :runtest,
    "cleanup" => :cleanup,
    "clone" => :clone,
    "delete" => :delete,
    "prune" => :prune,
    "ship-tree" => :ship_tree,
    "remote-root" => :remote_root,
    "requirements" => :requirements,
)

function _setup_subcommand(arg::AbstractString)::Union{Nothing, Symbol}
    for (name, mode) in _SETUP_SUBCOMMANDS
        arg == name && return mode
    end
    return nothing
end

function _setup_legacy_mode_name(flag::AbstractString)::Union{Nothing, String}
    flag == "--check" && return "check"
    flag == "--pull" && return "pull"
    flag == "--sync" && return "sync"
    flag == "--instantiate" && return "instantiate"
    flag == "--runtest" && return "runtest"
    flag == "--cleanup" && return "cleanup"
    flag == "--clone" && return "clone"
    flag == "--delete" && return "delete"
    flag == "--prune" && return "prune"
    flag == "--ship-tree" && return "ship-tree"
    flag == "--remote-root" && return "remote-root"
    flag == "--requirements" && return "requirements"
    return nothing
end

function _throw_setup_legacy_mode(flag::AbstractString)
    name = _setup_legacy_mode_name(flag)
    name === nothing && return nothing
    throw(
        ArgumentError(
            join_explained_message(
                "setup $(flag) was removed; use `$(cli_m()) setup $(name)`.",
                "Run `$(cli_m()) help setup` for flags.",
            ),
        )
    )
end

function _setup_set_mode!(
        mode_flag::Union{Nothing, String},
        next::Symbol,
        shown::AbstractString,
    )
    if mode_flag !== nothing
        throw(
            ArgumentError(
                join_explained_message(
                    "setup: more than one mode ($(mode_flag) and $(shown))",
                    "Run `$(cli_m()) help setup` for flags.",
                )
            )
        )
    end
    return next, String(shown)
end

function parse_setup_args(args::Vector{String})
    # Unknown options fail before `--help` and before any other flag is applied.
    _reject_unknown_cli_options(
        args,
        "setup";
        valued = (
            "--confirm-path", "--older-than", "--id", "--julia", "--repo",
            "--remote-path", DEPLOY_ROOT_FLAG, "--snapshot",
        ),
        prefixes = ("--remote-path=",),
        known = (
            "--check", "--pull", "--sync", "--instantiate", "--juliaup",
            "--juliaup-update", "--runtest", "--cleanup", "--clone",
            "--delete", "--prune", "--rsync", "--ship-tree", "--remote-root",
            "--remote-dir",
            "--allow-external-symlinks", "--requirements",
            "--ignore-julia-version", "-h", "--help", "--",
        ),
        bare_dash = true,
    )
    cli_session, args = peel_kit_cli_flags(args)
    mode = nothing
    mode_flag::Union{Nothing, String} = nothing
    julia_path = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")  # default to env or auto-detect
    repo_url = nothing
    deploy_root = nothing
    snapshot_id = nothing
    hosts = String[]
    show_help = false
    ignore_julia_version = false
    older_days = nothing
    prune_id = nothing
    confirm_paths = String[]
    allow_external_symlinks = false
    options_done = false

    c = CliCursor(args)
    while !cli_at_end(c)
        arg = cli_current(c)::String
        if options_done
            let p = parse_placement_token(arg)
                push!(hosts, p.role === :parent ? PARENT_HOST_NAME : p.name)
            end
            cli_consume!(c)
            continue
        end
        if arg == "--"
            options_done = true
            cli_consume!(c)
            continue
        end
        sub = _setup_subcommand(arg)
        if sub !== nothing
            mode, mode_flag = _setup_set_mode!(mode_flag, sub, arg)
            cli_consume!(c)
            continue
        end
        _throw_setup_legacy_mode(arg)
        if arg == "--juliaup" || arg == "--juliaup-update"
            _throw_setup_juliaup_removed(arg)
        elseif arg == "--rsync"
            _throw_rsync_removed()
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
        elseif arg == "--remote-dir"
            _throw_setup_remote_dir_removed()
        elseif _legacy_remote_path_arg(arg)
            _throw_legacy_remote_path("setup")
        elseif arg == DEPLOY_ROOT_FLAG
            deploy_root = _set_deploy_root!(
                deploy_root, _take_deploy_root!(c), "setup",
            )
        elseif arg == "--snapshot"
            raw = String(strip(cli_take_value!(c, arg)))
            isempty(raw) && throw(ArgumentError("--snapshot needs a non-empty id"))
            snapshot_id = validate_snapshot_id(raw)
        elseif arg == "--allow-external-symlinks"
            allow_external_symlinks = true
            cli_consume!(c)
        elseif arg == "--ignore-julia-version"
            ignore_julia_version = true
            cli_consume!(c)
        elseif cli_match(c, ["-h", "--help"])
            show_help = true
            cli_consume!(c)
        elseif startswith(arg, "-") && length(arg) > 1
            throw(ArgumentError(_unknown_cli_option_message("setup", arg)))
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
        throw(ArgumentError("--older-than / --id only apply to setup prune"))
    end
    if !isempty(confirm_paths) && mode !== :delete && mode !== :prune
        throw(ArgumentError("--confirm-path only applies to setup delete or setup prune"))
    end
    if snapshot_id !== nothing &&
            mode !== :instantiate && mode !== :check && mode !== :runtest
        throw(
            ArgumentError(
                "--snapshot only applies to setup instantiate, check, or runtest",
            ),
        )
    end

    return (
        mode = mode,
        julia_path = julia_path,
        repo_url = repo_url,
        deploy_root = deploy_root,
        snapshot_id = snapshot_id,
        hosts = hosts,
        show_help = show_help,
        ignore_julia_version = ignore_julia_version,
        older_days = older_days,
        prune_id = prune_id,
        confirm_paths = confirm_paths,
        allow_external_symlinks = allow_external_symlinks,
        show_version = cli_session.show_version,
        cli_session = cli_session,
    )
end

show_usage(; io::IO = stdout) = show_requirements(; io)
setup_help_text()::String = sprint(io -> show_requirements(; io))
