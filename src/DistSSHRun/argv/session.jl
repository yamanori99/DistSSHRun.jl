# Shared CLI session flags for drive / setup / size / go.

"""One-line meaning of `--require-git` (drive opt-in git parity)."""
const REQUIRE_GIT_MEANING = "opt-in git parity (off by default)"

"""Setup `git-sync --skip-git-guard`: deploy when the local tree may be dirty."""
const SETUP_SKIP_GIT_GUARD_MEANING =
    "git-sync only: skip local dirty check; deploy record marks dirty=true."

"""Shared collect-mode labels for help / docs."""
const COLLECT_MODE_HELP = """
Collect modes:
  post-run-new       drive after main(): files newer than run start (sentinel)
  collect-missing    drive --collect-missing / collect!(merge=false): absent locally
  collect-overwrite  drive --collect-overwrite / collect!(merge=true): merge remote tree
  slot-overwrite     go after each remote slot: Tar the whole slot directory
Pull-back uses stdlib Tar. Remote mtimes are not kept. File modes are not kept
(0644, or 0755 if the file is executable). The remote Julia executable is
--julia, or auto-detect. An escaping symlink is refused.
"""

const KIT_QUIET_FLAG_HELP =
    "-q, --quiet         hide terminal detail"
const KIT_PROGRESS_FLAG_HELP =
    "--progress          live status (TTY default)"
const KIT_VERBOSE_FLAG_HELP =
    "--verbose           full detail (non-TTY default)"
const KIT_TIME_HELP =
    "A time table prints after the run (-q hides it). Replay: progress DIR"
const KIT_HOSTS_FLAG_HELP =
    "--hosts CSV         quote `N*host` machine tokens (bare host = 1 worker)"
const KIT_HEAD_WORKERS_FLAG_HELP =
    "--head-workers N    LocalManager workers on this machine (drive; ENV DISTSSH_HEAD_WORKERS)"
const KIT_HEAD_SLOTS_FLAG_HELP =
    "--head-slots N      head subprocess slots on this machine (go only)"
const KIT_MACHINE_FILE_FLAG_HELP =
    "--machine-file PATH Julia machine-file subset (one line per `N*host`)"
const KIT_QUIET_ENV_HELP =
    "DISTSSH_QUIET                  Same as --quiet"
const KIT_PROGRESS_ENV_HELP =
    "DISTSSH_PROGRESS               Same as --progress"
const KIT_VERBOSE_ENV_HELP =
    "DISTSSH_VERBOSE                Same as --verbose"
const KIT_HOSTS_ENV_HELP =
    "DISTSSH_HOSTS                  Same as --hosts"
const KIT_SKIP_PKILL_ENV_HELP =
    "DISTSSH_SKIP_GLOBAL_WORKER_PKILL  skip drive leftover tagged remote pkill"
const KIT_JOBS_ENV_HELP =
    "DISTSSH_JOBS                   max concurrent host jobs (default 1)"
"""Drive opt-in: workers exit when the controller (master) stops answering heartbeats."""
const DRIVE_UNSAFE_MASTER_SILENCE_EXIT_FLAG_HELP =
    "--unsafe-master-silence-exit  opt-in worker self-exit when the controller (master) is silent"
const DRIVE_UNSAFE_MASTER_SILENCE_EXIT_ENV_HELP =
    "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT  Same as --unsafe-master-silence-exit"
const DRIVE_HEARTBEAT_DEADLINE_ENV_HELP =
    "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC  required positive seconds when self-exit is on"
const DRIVE_HEARTBEAT_INTERVAL_ENV_HELP =
    "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC  heartbeat ping interval (default 30)"

"""CLI default when no verbosity flag/env is set: live bar on a TTY, else verbose."""
kit_cli_auto_verbosity(; live::Union{Nothing, Bool} = nothing)::Symbol =
    something(live, kit_stdout_is_live()) ? :progress : :verbose

"""Read exclusive verbosity from env (`DISTSSH_QUIET` / `_PROGRESS` / `_VERBOSE`)."""
function _env_verbosity()::Union{Nothing, Symbol}
    want_quiet = _env_flag("DISTSSH_QUIET")
    want_progress = _env_flag("DISTSSH_PROGRESS")
    want_verbose = _env_flag("DISTSSH_VERBOSE")
    n = count(identity, (want_quiet, want_progress, want_verbose))
    n > 1 && throw(
        ArgumentError(
            "cannot combine DISTSSH_QUIET, DISTSSH_PROGRESS, and DISTSSH_VERBOSE",
        )
    )
    want_quiet && return :quiet
    want_progress && return :progress
    want_verbose && return :verbose
    return nothing
end

"""Removed run-time sync flags delegate to `_reject_run_transfer_cli!`."""
function _kit_set_sync_mode!(
        current::Union{Nothing, Symbol, Bool},
        next::Union{Symbol, Bool};
        source::AbstractString = "kit",
    )
    next === :git_sync && _reject_run_transfer_cli!(String(source), "--git-sync")
    next === :ship_tree && _reject_run_transfer_cli!(String(source), "--ship-tree")
    next === :rsync && _throw_rsync_removed()
    next === :sync && _reject_run_transfer_cli!(String(source), "--sync")
    if current !== nothing && current !== next
        throw(ArgumentError("$source: conflicting removed transfer flags"))
    end
    return next
end

"""Resolve verbosity; `quiet=true` maps to `:quiet`. Rejects quiet+progress/verbose."""
function _resolve_kit_verbosity(;
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
    )::Symbol
    if verbosity !== nothing
        verbosity in (:verbose, :progress, :quiet) ||
            throw(ArgumentError("verbosity must be :verbose, :progress, or :quiet"))
        quiet && verbosity === :progress &&
            throw(ArgumentError("cannot combine --quiet (-q) with --progress"))
        quiet && verbosity === :verbose &&
            throw(ArgumentError("cannot combine --quiet (-q) with --verbose"))
        quiet && verbosity !== :quiet &&
            throw(ArgumentError("quiet=true conflicts with verbosity=$verbosity"))
        return quiet ? :quiet : verbosity
    end
    return quiet ? :quiet : kit_cli_auto_verbosity()
end

"""Runtime CLI session: verbosity, non-interactive mode, shared host list."""
mutable struct CliSharedFlags
    quiet::Bool
    verbosity::Symbol
    yes::Bool
    hosts_file::Union{Nothing, String}
    machine_file::Union{Nothing, String}
    head_workers::Union{Nothing, Int}
    head_slots::Union{Nothing, Int}
    show_version::Bool
    hint_surface::Symbol
    verbosity_explicit::Bool
    hosts_flag::Vector{String}
    hosts_source::Union{Nothing, Symbol}
end

function CliSharedFlags(;
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
        yes::Bool = false,
        hosts_file::Union{Nothing, AbstractString} = nothing,
        machine_file::Union{Nothing, AbstractString} = nothing,
        head_workers::Union{Nothing, Integer} = nothing,
        head_slots::Union{Nothing, Integer} = nothing,
        show_version::Bool = false,
        hint_surface::Symbol = :cli,
        verbosity_explicit::Bool = false,
        hosts_flag::AbstractVector{<:AbstractString} = String[],
        hosts_source::Union{Nothing, Symbol} = nothing,
    )
    v = _resolve_kit_verbosity(; quiet = quiet, verbosity = verbosity)
    hf = hosts_file === nothing ? nothing : String(hosts_file)
    mf = machine_file === nothing ? nothing : String(machine_file)
    lw = head_workers === nothing ? nothing : Int(head_workers)
    lw !== nothing && lw < 0 &&
        throw(ArgumentError("--head-workers must be >= 0, got $lw"))
    ls = head_slots === nothing ? nothing : Int(head_slots)
    ls !== nothing && ls < 0 &&
        throw(ArgumentError("--head-slots must be >= 0, got $ls"))
    surface = _normalize_hint_surface(hint_surface)
    explicit = verbosity_explicit || quiet || verbosity !== nothing
    return CliSharedFlags(
        v === :quiet,
        v,
        yes,
        hf,
        mf,
        lw,
        ls,
        show_version,
        surface,
        explicit,
        String[String(h) for h in hosts_flag],
        hosts_source,
    )
end

function _env_flag(name::AbstractString)::Bool
    v = strip(get(ENV, String(name), ""))
    return v in ("1", "true", "yes", "on")
end

"""Max concurrent SSH host jobs (`DISTSSH_JOBS`, default 1)."""
function kit_host_jobs()::Int
    raw = strip(get(ENV, "DISTSSH_JOBS", "1"))
    n = tryparse(Int, raw)
    (n === nothing || n < 1) && return 1
    return n
end

"""Call `f(i, host)` for each host, at most `kit_host_jobs()` at once (1 → sequential)."""
function map_host_jobs(f, hosts::Vector{String})
    n = length(hosts)
    n == 0 && return nothing
    jobs = min(kit_host_jobs(), n)
    if jobs == 1
        for i in 1:n
            f(i, hosts[i])
        end
        return nothing
    end
    sem = Base.Semaphore(jobs)
    @sync for i in 1:n
        @async begin
            Base.acquire(sem)
            try
                f(i, hosts[i])
            finally
                Base.release(sem)
            end
        end
    end
    return nothing
end

"""Default session; honors `DISTSSH_QUIET`, `DISTSSH_PROGRESS`, `DISTSSH_VERBOSE`, `DISTSSH_YES`."""
function default_kit_cli_session()::CliSharedFlags
    env_v = _env_verbosity()
    hosts_kw = (;
        yes = _env_flag("DISTSSH_YES"),
        show_version = false,
    )
    env_v === nothing && return CliSharedFlags(; hosts_kw...)
    return CliSharedFlags(;
        quiet = env_v === :quiet,
        verbosity = env_v,
        verbosity_explicit = true,
        hosts_kw...,
    )
end

function apply_shared_cli_flags!(session::CliSharedFlags)
    set_kit_verbosity!(session.verbosity)
    set_kit_noninteractive!(session.yes)
    return session
end

"""Print `DistSSHRun <version>` (same as `julia -m DistSSHKit --version`)."""
function println_kit_version(io::IO = stdout)
    println(io, "DistSSHRun $(dist_ssh_kit_version())")
    return nothing
end

const _KIT_CLI_FLAGS = (
    quiet = ("-q", "--quiet"),
    progress = ("--progress",),
    verbose = ("--verbose",),
    yes = ("-y", "--yes"),
    hosts_file = ("--hosts-file",),
    machine_file = ("--machine-file",),
    head_workers = ("--head-workers",),
    head_slots = ("--head-slots",),
    hosts = ("--hosts",),
    version = ("--version", "-v", "-V"),  # -V kept as deprecated alias
)

function _flag_match(arg::AbstractString, names::Tuple{Vararg{String}})::Bool
    s = String(arg)
    for n in names
        s == n && return true
    end
    return false
end

function _prefix_match(arg::AbstractString, prefixes::Tuple{Vararg{String}})::Bool
    for p in prefixes
        startswith(arg, p) && return true
    end
    return false
end

function _shared_bare_cli_flag(arg::AbstractString)::Bool
    return _flag_match(arg, _KIT_CLI_FLAGS.quiet) ||
        _flag_match(arg, _KIT_CLI_FLAGS.progress) ||
        _flag_match(arg, _KIT_CLI_FLAGS.verbose) ||
        _flag_match(arg, _KIT_CLI_FLAGS.yes) ||
        _flag_match(arg, _KIT_CLI_FLAGS.version)
end

function _shared_valued_cli_flag(arg::AbstractString)::Bool
    return _flag_match(arg, _KIT_CLI_FLAGS.hosts_file) ||
        _flag_match(arg, _KIT_CLI_FLAGS.machine_file) ||
        _flag_match(arg, _KIT_CLI_FLAGS.head_workers) ||
        _flag_match(arg, _KIT_CLI_FLAGS.head_slots) ||
        _flag_match(arg, _KIT_CLI_FLAGS.hosts)
end

"""Unknown `-` option. The second line names `help <command>`, not `--help`."""
function _unknown_cli_option_message(command::AbstractString, arg::AbstractString)::String
    return join_explained_message(
        "unknown $(command) option: $(arg)",
        "Run `$(cli_m()) help $(command)` for flags.",
    )
end

"""CLI location override. Not `DISTRIBUTED_REMOTE_PROJECT_ROOT` and not `session.remote`."""
const DEPLOY_ROOT_FLAG = "--deploy-root"

function _legacy_remote_path_arg(arg::AbstractString)::Bool
    s = String(arg)
    return s == "--remote-path" || startswith(s, "--remote-path=")
end

function _throw_legacy_remote_path(command::AbstractString)
    throw(
        ArgumentError(
            join_explained_message(
                "$(command) --remote-path was removed; use $(DEPLOY_ROOT_FLAG) PATH.",
                "Run `$(cli_m()) help $(command)` for flags.",
            ),
        )
    )
end

"""User-facing `-m` for setup/go/drive. Queue's entry is not those commands."""
function _kit_user_cli_m()::String
    return cli_entry() === :DistSSHQueue ? "julia -m DistSSHKit" : cli_m()
end

"""`go` / `drive` transfer flags are setup-only (#386)."""
function _throw_go_drive_ship_cli_removed(command::AbstractString, flag::AbstractString)
    return _reject_run_transfer_cli!(command, flag)
end

function _throw_detached_ship_tree_removed()
    throw(
        ArgumentError(
            join_explained_message(
                "execute!(...; detached=true, sync=:ship_tree) cannot pass --ship-tree to go/drive.",
                string(
                    "Call setup!(session, :ship_tree; extra_files=[script]) when the script is outside the project ",
                    "(one file, at _distsshrun_external/<basename>), then setup!(session, :instantiate; run_id=id), ",
                    "then execute!(...; run_id=id). ",
                    "In-process go! / drive! reject sync=:ship_tree the same way.",
                ),
            ),
        )
    )
end

function _parse_deploy_root_value(raw::AbstractString, flag::AbstractString)::String
    any(c -> c == '\n' || c == '\r' || c == '\0' || iscntrl(c), raw) && throw(
        ArgumentError("$(flag) cannot contain a control character"),
    )
    return strip(String(raw))
end

function _take_deploy_root!(c::CliCursor)::String
    return _parse_deploy_root_value(cli_take_value!(c, DEPLOY_ROOT_FLAG), DEPLOY_ROOT_FLAG)
end

function _set_deploy_root!(
        current::Union{Nothing, String},
        next::AbstractString,
        command::AbstractString,
    )::String
    current === nothing || throw(
        ArgumentError("$(command): $(DEPLOY_ROOT_FLAG) given more than once"),
    )
    return String(next)
end

"""
Reject the first unknown `-` option before help and before other flag handling.

`valued` flags consume the next token, so that token is not an option.
A missing value is left for the command parser. `"-"` is an option unless
`bare_dash` is true.
"""
function _reject_unknown_cli_options(
        args::AbstractVector{<:AbstractString},
        command::AbstractString;
        valued::Tuple{Vararg{String}},
        known::Tuple{Vararg{String}},
        prefixes::Tuple{Vararg{String}} = (),
        bare_dash::Bool = false,
    )::Nothing
    i = 1
    n = length(args)
    while i <= n
        arg = String(args[i])
        if _shared_valued_cli_flag(arg) || _flag_match(arg, valued)
            i += 2
            continue
        end
        dashed = startswith(arg, "-") && !(bare_dash && arg == "-")
        if !dashed ||
                _shared_bare_cli_flag(arg) ||
                _flag_match(arg, known) ||
                _prefix_match(arg, prefixes)
            i += 1
            continue
        end
        throw(ArgumentError(_unknown_cli_option_message(command, arg)))
    end
    return nothing
end

function _set_session_verbosity!(session::CliSharedFlags, v::Symbol)
    if session.verbosity_explicit && session.verbosity !== v
        throw(ArgumentError("cannot combine --quiet (-q), --progress, and --verbose"))
    end
    session.verbosity = v
    session.quiet = v === :quiet
    session.verbosity_explicit = true
    return session
end

"""Consume one shared CLI flag from `c`; return `true` if consumed."""
function consume_kit_cli_flag!(c::CliCursor, session::CliSharedFlags)::Bool
    arg = cli_current(c)
    arg === nothing && return false
    reject_legacy_local_placement_flag!(String(arg))
    if _flag_match(arg, _KIT_CLI_FLAGS.quiet)
        _set_session_verbosity!(session, :quiet)
        cli_consume!(c)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.progress)
        _set_session_verbosity!(session, :progress)
        cli_consume!(c)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.verbose)
        _set_session_verbosity!(session, :verbose)
        cli_consume!(c)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.yes)
        session.yes = true
        cli_consume!(c)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.version)
        session.show_version = true
        cli_consume!(c)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.hosts_file)
        session.hosts_file = cli_take_value!(c, arg)
        session.hosts_source === nothing && (session.hosts_source = :hosts_file)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.machine_file)
        next = cli_take_value!(c, arg)
        session.machine_file !== nothing &&
            throw(ArgumentError("$(arg) specified more than once"))
        session.machine_file = next
        session.hosts_source === nothing && (session.hosts_source = :machine_file)
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.head_workers)
        raw = cli_take_value!(c, arg)
        session.head_workers !== nothing &&
            throw(ArgumentError("$(arg) specified more than once"))
        session.head_workers = parse(Int, strip(raw))
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.head_slots)
        raw = cli_take_value!(c, arg)
        session.head_slots !== nothing &&
            throw(ArgumentError("$(arg) specified more than once"))
        session.head_slots = tryparse(Int, strip(String(raw)))
        session.head_slots === nothing &&
            throw(ArgumentError("$(arg) must be an integer, got $(repr(raw))"))
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.hosts)
        append!(session.hosts_flag, split_hosts_csv(cli_take_value!(c, arg)))
        session.hosts_source === nothing && (session.hosts_source = :hosts)
        return true
    end
    return false
end

"""
Split leading shared flags from `args`.

Returns `(session, rest)` where `rest` is every non-flag token (and tokens
following flags that take values other than `--hosts-file` / `--hosts`).
"""
function peel_shared_cli_flags(args::AbstractVector{<:AbstractString})::Tuple{CliSharedFlags, Vector{String}}
    session = default_kit_cli_session()
    rest = String[]
    c = CliCursor(collect(String, args))
    while !cli_at_end(c)
        if consume_kit_cli_flag!(c, session)
            continue
        end
        push!(rest, cli_current(c)::String)
        cli_consume!(c)
    end
    return session, rest
end


function _kit_host_token(
        tok::AbstractString,
        keep_counts::Bool;
        roles::Bool = false,
    )::String
    keep_counts && return String(tok)
    if roles
        return parse_placement_token(tok).name
    end
    return split_worker_token(tok)[1]
end

function _host_input_explicit_sources(session::CliSharedFlags)::Vector{Symbol}
    out = Symbol[]
    !isempty(session.hosts_flag) && push!(out, :hosts)
    session.hosts_file !== nothing && push!(out, :hosts_file)
    session.machine_file !== nothing && push!(out, :machine_file)
    return out
end

function _host_input_coalesce_sources!(session::CliSharedFlags)::Symbol
    explicit = _host_input_explicit_sources(session)
    length(explicit) > 1 && throw(
        ArgumentError(
            "host list from more than one source ($(join(explicit, ", "))); "
                * "use exactly one of --hosts, --hosts-file, or --machine-file",
        ),
    )
    if !isempty(explicit)
        return first(explicit)
    end
    env_hosts = split_hosts_csv(get(ENV, "DISTSSH_HOSTS", ""))
    env_file = let raw = strip(get(ENV, "DISTSSH_HOSTS_FILE", ""))
        isempty(raw) ? nothing : String(raw)
    end
    !isempty(env_hosts) && return :env_hosts
    env_file !== nothing && return :env_file
    return :none
end

"""Resolved host tokens from exactly one source (CLI wins over env)."""
function placement_source_tokens(
        session::CliSharedFlags;
        keep_counts::Bool = true,
        roles::Bool = false,
        for_setup::Bool = false,
    )::Vector{String}
    _setup_reject_counts!(tok) = for_setup ? reject_setup_worker_count!(tok) : nothing
    source = _host_input_coalesce_sources!(session)
    if source === :hosts
        for t in session.hosts_flag
            _setup_reject_counts!(t)
        end
        return String[_kit_host_token(t, keep_counts; roles = roles) for t in session.hosts_flag]
    elseif source === :hosts_file
        lines = read_hosts_file_lines(session.hosts_file::String; surface = session.hint_surface)
        for line in lines
            _setup_reject_counts!(line)
        end
        if keep_counts
            return lines
        elseif roles
            return String[_kit_host_token(line, false; roles = true) for line in lines]
        else
            return read_hosts_file(session.hosts_file::String; surface = session.hint_surface)
        end
    elseif source === :machine_file
        lines = read_machine_file_lines(session.machine_file::String; surface = session.hint_surface)
        for line in lines
            _setup_reject_counts!(line)
        end
        if keep_counts
            return lines
        elseif roles
            return String[parse_placement_token(line).name for line in lines]
        else
            return String[split_worker_token(line)[1] for line in lines]
        end
    elseif source === :env_hosts
        raw = split_hosts_csv(get(ENV, "DISTSSH_HOSTS", ""))
        for t in raw
            _setup_reject_counts!(t)
        end
        return String[_kit_host_token(t, keep_counts; roles = roles) for t in raw]
    elseif source === :env_file
        hf = String(strip(get(ENV, "DISTSSH_HOSTS_FILE", "")))
        lines = read_hosts_file_lines(hf; surface = session.hint_surface)
        for line in lines
            _setup_reject_counts!(line)
        end
        if keep_counts
            return lines
        elseif roles
            return String[_kit_host_token(line, false; roles = true) for line in lines]
        else
            return read_hosts_file(hf; surface = session.hint_surface)
        end
    else
        return String[]
    end
end

"""Resolved host-list source for `session` (CLI wins over env; never merges `--hosts` with `DISTSSH_HOSTS`)."""
placement_host_source(session::CliSharedFlags)::Symbol = _host_input_coalesce_sources!(session)

function _distssh_hosts_env_tokens()::Vector{String}
    return split_hosts_csv(get(ENV, "DISTSSH_HOSTS", ""))
end

function placement_host_source_label(source::Symbol)::String
    source === :hosts && return "--hosts"
    source === :hosts_file && return "--hosts-file"
    source === :machine_file && return "--machine-file"
    source === :env_hosts && return "DISTSSH_HOSTS"
    source === :env_file && return "DISTSSH_HOSTS_FILE"
    source === :none && return "argv"
    return String(source)
end

"""When CLI names a host list and `DISTSSH_HOSTS` is set, one override line (progress / verbose)."""
function kit_distssh_hosts_override_notice(session::CliSharedFlags)::Union{Nothing, String}
    explicit = _host_input_explicit_sources(session)
    isempty(explicit) && return nothing
    isempty(_distssh_hosts_env_tokens()) && return nothing
    cli = first(explicit)
    cli === :env_hosts && return nothing
    cli === :env_file && return nothing
    label = placement_host_source_label(cli)
    return "DISTSSH_HOSTS is set but overridden by $label"
end

"""
Print resolved host tokens and their source (`hosts (from --hosts): …`).

Skipped when `tokens` is empty, `quiet` is set, or no placement source applies (`:none`).
"""
function writeln_kit_resolved_hosts!(
        session::CliSharedFlags,
        tokens::AbstractVector{<:AbstractString};
        quiet::Bool = session.quiet,
    )
    quiet && return nothing
    isempty(tokens) && return nothing
    source = placement_host_source(session)
    source === :none && return nothing
    notice = kit_distssh_hosts_override_notice(session)
    notice !== nothing && writeln_both(notice)
    label = placement_host_source_label(source)
    writeln_both("hosts (from $label): $(join(tokens, ", "))")
    return nothing
end

function append_kit_host_sources!(
        hosts::Vector{String},
        session::CliSharedFlags;
        keep_counts::Bool = true,
        roles::Bool = false,
        for_setup::Bool = false,
    )
    append!(
        hosts,
        placement_source_tokens(
            session; keep_counts = keep_counts, roles = roles, for_setup = for_setup,
        ),
    )
    return hosts
end

"""Path to the hosts file used for TOML `bind` on this session (`nothing` when not applicable)."""
function hosts_file_path_for_bind(session::CliSharedFlags)::Union{Nothing, String}
    source = placement_host_source(session)
    path = if source === :hosts_file
        session.hosts_file
    elseif source === :env_file
        String(strip(get(ENV, "DISTSSH_HOSTS_FILE", "")))
    elseif session.hosts_file !== nothing
        session.hosts_file
    else
        nothing
    end
    path === nothing && return nothing
    path = String(strip(path))
    isempty(path) && return nothing
    return path
end

"""Per-host bind overrides from TOML on the active hosts file (`bind_overrides=` must not conflict)."""
function hosts_file_bind_overrides(
        session::CliSharedFlags;
        bind_overrides::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
        planned_hosts::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
        command::Union{Nothing, Symbol} = nothing,
    )::Dict{String, String}
    path = hosts_file_path_for_bind(session)
    path === nothing && return resolve_launch_bind_overrides(;
        bind_overrides = bind_overrides,
        surface = session.hint_surface,
        planned_hosts = planned_hosts,
        command = command,
    )
    return resolve_launch_bind_overrides(;
        hosts_file = path,
        bind_overrides = bind_overrides,
        surface = session.hint_surface,
        planned_hosts = planned_hosts,
        command = command,
    )
end

function append_hosts_file!(hosts::Vector{String}, session::CliSharedFlags)
    hosts_file = session.hosts_file
    hosts_file === nothing && return hosts
    append!(hosts, read_hosts_file(hosts_file; surface = session.hint_surface))
    return hosts
end

"""True when CLI host token collection already includes the active hosts file."""
function hosts_file_worker_tokens_merged(source::Union{Nothing, Symbol})::Bool
    return source === :hosts_file || source === :env_file
end

"""
Append hosts-file machine tokens into `tokens` when they are not already merged.

Returns the resolved hosts-file path for bind validation (`nothing` when absent).
"""
function merge_go_hosts_file_worker_tokens!(
        tokens::Vector{String},
        hosts_file::Union{Nothing, AbstractString};
        hosts_file_tokens_merged::Bool,
        surface::Symbol,
        honor_distssh_hosts_file_env::Bool = true,
    )::Union{Nothing, String}
    hf = hosts_file === nothing ? nothing : String(strip(hosts_file))
    if hf === nothing || isempty(hf)
        if isempty(tokens) && honor_distssh_hosts_file_env
            env_hf = strip(get(ENV, "DISTSSH_HOSTS_FILE", ""))
            !isempty(env_hf) && (hf = env_hf)
        else
            return nothing
        end
    end
    hf === nothing && return nothing
    if !hosts_file_tokens_merged
        for line in read_hosts_file_lines(hf; surface = surface)
            push!(tokens, line)
        end
    end
    return hf
end

"""`println` with the same terminal gate as `writeln_both` (setup / size)."""
function kit_println(args...; io::IO = stdout)
    if kit_output_detail()
        println(io, args...)
    end
    if LOG_FILE_HANDLE[] !== nothing
        println(LOG_FILE_HANDLE[], args...)
        flush(LOG_FILE_HANDLE[])
    end
    return nothing
end

"""`print` with the same terminal gate as `writeln_both`."""
function kit_print(args...; io::IO = stdout)
    if kit_output_detail()
        print(io, args...)
    end
    if LOG_FILE_HANDLE[] !== nothing
        print(LOG_FILE_HANDLE[], args...)
        flush(LOG_FILE_HANDLE[])
    end
    return nothing
end

"""
Prompt on stdin; return `true` if confirmed.

The prompt is always written to the terminal (quiet / progress / verbose).
Do not route it through [`kit_print`](@ref) (`:verbose` only).
Pauses the live `\r` progress bar so the prompt is not overwritten.

With `--yes` / `DISTSSH_YES`, always returns `true` without prompting.
`keyword=nothing` → accept `y` / `yes` (case-insensitive).
Otherwise the answer must match `keyword` exactly.
"""
function kit_confirm(prompt::AbstractString; keyword::Union{Nothing, String} = nothing)::Bool
    kit_noninteractive() && return true
    return with_kit_progress_suspended() do
        print(stdout, prompt)
        flush(stdout)
        if LOG_FILE_HANDLE[] !== nothing
            print(LOG_FILE_HANDLE[], prompt)
            flush(LOG_FILE_HANDLE[])
        end
        answer = strip(readline())
        if keyword === nothing
            return lowercase(answer) in ("y", "yes")
        end
        return answer == keyword
    end
end

function kit_confirm!(prompt::AbstractString; keyword::Union{Nothing, String} = nothing)::Bool
    kit_confirm(prompt; keyword = keyword) || return false
    return true
end
