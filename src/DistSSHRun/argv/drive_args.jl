# Drive CLI argument parsing and help (module-owned; Main CLI re-exports).

function _parse_worker_token(spec::AbstractString)
    return split_worker_token(String(spec))
end

"""Parse `--flag:N` / `-f:N` into `N`; return `nothing` if `arg` is not that form."""
function _drive_flag_int_suffix(
        arg::String,
        prefixes::Union{Tuple{Vararg{String}}, AbstractVector{String}},
    )::Union{Nothing, Int}
    for prefix in prefixes
        prefix_str = String(prefix)
        if !startswith(arg, prefix_str) || length(arg) <= length(prefix_str) || arg[length(prefix_str) + 1] != ':'
            continue
        end
        suffix = arg[(length(prefix_str) + 2):end]
        isempty(suffix) &&
            throw(ArgumentError("$(prefix_str) requires a worker count (e.g. $(prefix_str) 2 or $(prefix_str):2)"))
        return parse(Int, suffix)
    end
    return nothing
end

function _parse_drive_flag_count(flag::String, args::Vector, i::Int)::Int
    i >= length(args) &&
        throw(ArgumentError("$flag requires a worker count (e.g. $flag 2 or $(flag):2)"))
    value = String(args[i + 1])
    if endswith(value, ".jl")
        throw(
            ArgumentError(
                "$flag requires a worker count before the script (e.g. $flag 2 script.jl)",
            )
        )
    end
    try
        return parse(Int, value)
    catch
        throw(ArgumentError("$flag worker count must be an integer, got $(repr(value))"))
    end
end

function _drive_set_parent_workers!(
        parent_workers::Int,
        count::Int,
        source::String,
    )::Int
    parent_workers > 0 &&
        throw(
        ArgumentError(
            "duplicate parent worker spec ($source); use one of $(PARENT_HOST_NAME):N",
        )
    )
    count < 1 &&
        throw(ArgumentError("parent worker count must be >= 1, got $count"))
    return count
end

function _drive_push_host_token!(
        hosts::Vector{Tuple{String, Union{Int, Nothing}}},
        parent_workers::Int,
        token::AbstractString,
        parent_listed::Ref{Bool},
    )::Int
    p = parse_placement_token(String(token))
    p.n === nothing && throw(
        ArgumentError(explain_bare_placement_tokens([token]; surface = :cli)),
    )
    if p.role === :parent
        parent_listed[] = true
        n = p.n
        n === 0 && return parent_workers
        return _drive_set_parent_workers!(
            parent_workers,
            n,
            String(token),
        )
    end
    push!(hosts, (p.name, p.n))
    return parent_workers
end

"""Parse `drive` CLI arguments (same shape as other kit CLI parsers)."""
function parse_drive_args(args::Vector{String})
    cli_session, args = peel_kit_cli_flags(args)
    parent_workers = 0
    default_workers = nothing
    julia_exe = nothing
    allow_mismatch = Symbol[]
    skip_hash_check = true  # default: no git parity; --require-git turns checks on
    enable_log = true
    log_dir = nothing
    output_dir = nothing
    explicit_package = nothing
    run_id = nothing
    deploy_root = nothing
    isolated = false
    worker_include = false
    require_git = false
    require_all_hosts = true
    require_all_hosts_cli = false
    best_effort_cli = false
    hosts = Tuple{String, Union{Int, Nothing}}[]
    parent_listed = Ref(false)
    script_path = nothing
    script_args = String[]

    i = 1
    options_done = false
    while i <= length(args)
        arg = String(args[i])
        if options_done
            if endswith(arg, ".jl")
                script_path = arg
                script_args = args[(i + 1):end]
                break
            elseif startswith(arg, "-")
                throw(
                    ArgumentError(
                        "unknown or incomplete drive option: $arg (use parent:N / child:NAME:N, e.g. parent:2 child:host1:4)",
                    )
                )
            else
                parent_workers = _drive_push_host_token!(
                    hosts,
                    parent_workers,
                    arg,
                    parent_listed,
                )
                i += 1
            end
            continue
        end

        if arg == "--parenthost" || startswith(arg, "--parenthost:") ||
                arg == "--masterhost" || startswith(arg, "--masterhost:") ||
                arg == "--parent" || startswith(arg, "--parent:")
            throw(
                ArgumentError(
                    "drive: use `parent:N` (e.g. drive parent:4 script.jl), not a `--parent` flag",
                )
            )
        elseif arg == "--local" || arg == "-l" ||
                startswith(arg, "--local:") || startswith(arg, "-l:")
            throw_removed_local_flag(arg)
        elseif arg == "--workers" || arg == "-w"
            default_workers = _parse_drive_flag_count(arg, args, i)
            i += 2
        elseif startswith(arg, "--workers:") || startswith(arg, "-w:")
            default_workers = _drive_flag_int_suffix(arg, ("--workers", "-w"))
            i += 1
        elseif arg == "--julia" && i < length(args)
            julia_exe = args[i + 1]
            i += 2
        elseif arg == "--allow-mismatch" && i < length(args)
            merge_allow_mismatch!(allow_mismatch, args[i + 1])
            i += 2
        elseif arg in (
                "--sync",
                "--git-sync",
                "--ship-tree",
                "--skip-git-sync",
                "--skip-sync",
                "--skip-git-guard",
                "--allow-external-symlinks",
            )
            _reject_run_transfer_cli!("drive", arg)
            i += 1
        elseif arg == "--sync-script"
            _throw_drive_removed_sync_script_flag!()
        elseif arg == "--worker-include"
            worker_include && throw(
                ArgumentError(
                    "drive: --worker-include specified more than once",
                ),
            )
            worker_include = true
            i += 1
        elseif arg == "--run-id"
            i >= length(args) && throw(ArgumentError("drive: --run-id needs a non-empty id"))
            raw = String(strip(args[i + 1]))
            isempty(raw) && throw(ArgumentError("drive: --run-id needs a non-empty id"))
            run_id = raw
            i += 2
        elseif _legacy_remote_path_arg(arg)
            _throw_legacy_remote_path("drive")
        elseif arg == DEPLOY_ROOT_FLAG
            i >= length(args) && throw(ArgumentError("drive: $(DEPLOY_ROOT_FLAG) requires a value"))
            deploy_root = _set_deploy_root!(
                deploy_root,
                _parse_deploy_root_value(args[i + 1], DEPLOY_ROOT_FLAG),
                "drive",
            )
            i += 2
        elseif arg == "--"
            options_done = true
            i += 1
        elseif arg == "--isolated"
            isolated && throw(ArgumentError("drive: --isolated specified more than once"))
            isolated = true
            i += 1
        elseif arg == "--rsync"
            _throw_rsync_removed()
        elseif arg == "--require-git"
            require_git && throw(ArgumentError("drive: --require-git specified more than once"))
            require_git = true
            skip_hash_check = false
            i += 1
        elseif arg == "--require-all-hosts"
            require_all_hosts_cli && throw(
                ArgumentError(
                    "drive: --require-all-hosts specified more than once",
                )
            )
            best_effort_cli && throw(
                ArgumentError(
                    "drive: cannot combine --require-all-hosts and --best-effort",
                )
            )
            require_all_hosts_cli = true
            require_all_hosts = true
            i += 1
        elseif arg == "--best-effort"
            best_effort_cli && throw(
                ArgumentError(
                    "drive: --best-effort specified more than once",
                )
            )
            require_all_hosts_cli && throw(
                ArgumentError(
                    "drive: cannot combine --require-all-hosts and --best-effort",
                )
            )
            best_effort_cli = true
            require_all_hosts = false
            i += 1
        elseif arg == "--mem-headroom" || arg == "--parent-gb" || arg == "--master-gb" || startswith(arg, "--master-gb:")
            throw(ArgumentError("drive: worker-count sizing was removed; pass explicit parent:N / child:NAME:N"))
        elseif arg == "--no-log"
            enable_log = false
            i += 1
        elseif arg == "--log-dir" && i < length(args)
            log_dir = args[i + 1]
            i += 2
        elseif arg == "--output-dir" && i < length(args)
            output_dir = args[i + 1]
            i += 2
        elseif arg == "--package" && i < length(args)
            p = String(strip(args[i + 1]))
            explicit_package = isempty(p) ? nothing : p
            i += 2
        elseif arg == "--collect" || arg == "--collect-sync"
            throw(
                ArgumentError(
                    "$(arg) was removed; use --collect-missing ROOT HOST... or --collect-overwrite ROOT HOST...",
                )
            )
        elseif arg == "--collect-missing" ||
                arg == "--collect-overwrite"
            flag = arg
            merge = flag == "--collect-overwrite"
            !isempty(hosts) &&
                throw(
                ArgumentError(
                    "host specs before $(flag) are not supported; use $(flag) ROOT HOST..."
                )
            )
            tail = args[(i + 1):end]
            isempty(tail) && throw(ArgumentError("`$(flag)` requires ROOT HOST [HOST...]"))
            for a in tail
                if startswith(a, '-') && length(a) > 1
                    throw(
                        ArgumentError(
                            "`$(flag)` arguments cannot include options like $(repr(a)); put flags before $(flag)"
                        )
                    )
                end
            end
            tree_root = canonical_local_path(tail[1])
            tree_hosts = String[_parse_worker_token(String(x))[1] for x in tail[2:end]]
            isempty(tree_hosts) && throw(ArgumentError("`$(flag)` requires at least one HOST after ROOT"))
            apply_kit_cli_session!(cli_session)
            if julia_exe === nothing
                env_val = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
                julia_exe = env_val == "auto" ? nothing : env_val
            elseif julia_exe == "auto"
                julia_exe = nothing
            end
            return (
                parent_workers = parent_workers,
                default_workers = default_workers,
                julia = julia_exe,
                skip_hash_check = skip_hash_check,
                enable_log = enable_log,
                log_dir = log_dir,
                output_dir = output_dir,
                explicit_package = explicit_package,
                hosts = Tuple{String, Union{Int, Nothing}}[],
                script_path = nothing,
                script_args = String[],
                collect_root = tree_root,
                collect_hosts = tree_hosts,
                collect_overwrite = merge,
                worker_include = worker_include,
                require_all_hosts = require_all_hosts,
                help = false,
                show_version = cli_session.show_version,
                cli_session = cli_session,
                hint_surface = :cli,
                allow_mismatch = allow_mismatch,
                run_id = run_id,
                deploy_root = deploy_root,
                isolated = isolated,
            )
        elseif arg == "--help" || arg == "-h"
            return (
                parent_workers = 0,
                default_workers = nothing,
                julia = nothing,
                skip_hash_check = true,
                enable_log = true,
                log_dir = nothing,
                output_dir = nothing,
                explicit_package = nothing,
                hosts = Tuple{String, Union{Int, Nothing}}[],
                script_path = nothing,
                script_args = String[],
                collect_root = nothing,
                collect_hosts = nothing,
                collect_overwrite = nothing,
                worker_include = false,
                require_all_hosts = false,
                help = true,
                show_version = cli_session.show_version,
                cli_session = cli_session,
                hint_surface = :cli,
                allow_mismatch = allow_mismatch,
                run_id = nothing,
                deploy_root = nothing,
                isolated = false,
            )
        elseif endswith(arg, ".jl")
            script_path = arg
            script_args = args[(i + 1):end]
            break
        elseif startswith(arg, "-")
            throw(
                ArgumentError(
                    "unknown or incomplete drive option: $arg (use parent:N / child:NAME:N, e.g. parent:2 child:host1:4)",
                )
            )
        else
            parent_workers = _drive_push_host_token!(
                hosts,
                parent_workers,
                arg,
                parent_listed,
            )
            i += 1
        end
    end

    if !require_all_hosts_cli && !best_effort_cli
        want_all = _env_flag("DISTSSHKIT_REQUIRE_ALL_HOSTS")
        want_best = _env_flag("DISTSSHKIT_BEST_EFFORT")
        want_all && want_best && throw(
            ArgumentError(
                "drive: cannot combine DISTSSHKIT_REQUIRE_ALL_HOSTS and DISTSSHKIT_BEST_EFFORT",
            )
        )
        want_best && (require_all_hosts = false)
    end

    if julia_exe === nothing
        env_val = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
        julia_exe = env_val == "auto" ? nothing : env_val
    elseif julia_exe == "auto"
        julia_exe = nothing
    end

    for tok in kit_host_source_tokens(cli_session; keep_counts = true)
        parent_workers = _drive_push_host_token!(
            hosts,
            parent_workers,
            tok,
            parent_listed,
        )
    end

    apply_kit_cli_session!(cli_session)
    if !parent_listed[] && default_workers !== nothing
        parent_workers = _drive_set_parent_workers!(
            parent_workers,
            default_workers,
            "-w",
        )
    end

    return (
        parent_workers = parent_workers,
        default_workers = default_workers,
        julia = julia_exe,
        skip_hash_check = skip_hash_check,
        enable_log = enable_log,
        log_dir = log_dir,
        output_dir = output_dir,
        explicit_package = explicit_package,
        hosts = hosts,
        script_path = script_path,
        script_args = script_args,
        collect_root = nothing,
        collect_hosts = nothing,
        collect_overwrite = nothing,
        worker_include = worker_include,
        require_all_hosts = require_all_hosts,
        help = false,
        show_version = cli_session.show_version,
        cli_session = cli_session,
        hint_surface = :cli,
        allow_mismatch = allow_mismatch,
        run_id = run_id,
        deploy_root = deploy_root,
        isolated = isolated,
    )
end

"""Print `drive --help` (same chrome as `julia -m DistSSHKit drive -h`)."""
function show_drive_usage(; io::IO = stdout)
    print_help_chrome(cli_heading("drive"); io = io)
    print_help_lines(
        io,
        "Driver + Distributed workers (pmap), then collect new files.",
        "Remotes: setup ship-tree or setup git-clone, then setup instantiate.",
        "Then drive --run-id ID (or last-ship.toml / git checkout).",
    )
    print_help_blank(io)
    print_help_section("Usage"; io = io)
    print_help_lines(
        io,
        "  $(cli_m_project()) drive [workers...] DRIVER.jl",
        "  drive parent:4 child:host1:8 jobs.jl",
        "  drive --collect-missing ROOT HOST...",
    )
    print_help_blank(io)
    print_help_section("Workers"; io = io)
    print_help_lines(
        io,
        "  parent:N / child:NAME:N  required :N (no tokens → parent:1)",
        "  omit :N             error (pass parent:N / child:NAME:N)",
        "  $(KIT_HOSTS_FLAG_HELP)",
        "  --hosts-file PATH   one token per line",
    )
    print_help_blank(io)
    print_help_section("Options"; io = io)
    print_help_lines(
        io,
        "  -w, --workers N     parent:N when no parent token is listed",
        "  --deploy-root PATH  remote deployment root (location, not snapshot id).",
        "                      Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT, else the",
        "                      ~/Parent/RepoName layout from the local env_dir.",
        "  --run-id ID       use runs/<ID>/src under the deploy root",
        "                      (after setup ship-tree + setup instantiate)",
        "  --worker-include    re-include the full driver on workers (default: defs only)",
        "  --require-git       $(REQUIRE_GIT_MEANING)",
        "  --require-all-hosts listed parent/child tokens must join, stay, and collect (default)",
        "  --best-effort       allow a partial run (missing join is not a failure)",
        "  --output-dir PATH   result root (default: {script}/.distsshkit/drive/<stem>_<UTC>/; must be missing or empty)",
        "  --isolated          run the driver in a child process (default: this process)",
        "  --julia PATH        remote Julia",
        "  --allow-mismatch F  waive julia, distssh, and/or manifest (comma list)",
        "  SSH workers: project-root cwd, bind 127.0.0.1, tunnel unless DISTSSHKIT_SSH_TUNNEL=0.",
        "  --no-log            skip drive_*.log",
        "  $(KIT_QUIET_FLAG_HELP)",
        "  $(KIT_PROGRESS_FLAG_HELP)",
        "  $(KIT_VERBOSE_FLAG_HELP)",
        "  -y, --yes           skip confirmations",
        "  --version, -v       print version and exit",
        "  -h, --help          this help",
    )
    print_help_blank(io)
    print_help_lines(io, "  $(KIT_TIME_HELP)")
    print_help_blank(io)
    print_help_section("Collect"; io = io)
    print_help_lines(
        io,
        "  After main(): post-run-new (files newer than run start).",
        "  Later: --collect-missing / --collect-overwrite ROOT HOST...",
        "  Pass --run-id ID so collect maps onto that ship, not a newer one.",
        "  With DISTSSHKIT_RUN_DIR, omitted recovery uses that run's provenance.selection.",
        "  Pull-back uses Tar. Remote mtimes and file modes are not kept.",
        "  Modes are 0644, or 0755 if executable. Remote Julia is --julia or auto-detect.",
        "  Escaping symlinks are refused.",
        "  Skip auto-collect: DISTRIBUTED_SKIP_COLLECT=1",
    )
    print_help_blank(io)
    print_help_section("Environment"; io = io)
    print_help_lines(
        io,
        "  $(KIT_HOSTS_ENV_HELP)",
        "  JULIA_DISTRIBUTED_EXE        default remote Julia",
        "  DISTSSHKIT_QUIET / PROGRESS / VERBOSE / YES",
        "  $(KIT_SKIP_PKILL_ENV_HELP)",
        "  $(KIT_JOBS_ENV_HELP)",
        "  $(KIT_REQUIRE_ALL_HOSTS_ENV_HELP)",
        "  $(KIT_BEST_EFFORT_ENV_HELP)",
        "  DISTRIBUTED_SKIP_COLLECT=1 skip post-run collect",
    )
    print_help_blank(io)
    return print_help_lines(
        io,
        "Details: docs (manual/drive). See also: setup, hostinfo, go.",
    )
end

drive_help_text()::String = sprint(io -> show_drive_usage(; io))
