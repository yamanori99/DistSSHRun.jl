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
    "--hosts CSV         parent[:N] / child:NAME[:N]"
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
const KIT_REQUIRE_ALL_HOSTS_ENV_HELP =
    "DISTSSH_REQUIRE_ALL_HOSTS      Same as --require-all-hosts"
const KIT_BEST_EFFORT_ENV_HELP =
    "DISTSSH_BEST_EFFORT            Same as --best-effort"

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
mutable struct KitCliSession
    quiet::Bool
    verbosity::Symbol
    yes::Bool
    hosts_file::Union{Nothing, String}
    show_version::Bool
    hint_surface::Symbol
    verbosity_explicit::Bool
    hosts_flag::Vector{String}
end

function KitCliSession(;
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
        yes::Bool = false,
        hosts_file::Union{Nothing, AbstractString} = nothing,
        show_version::Bool = false,
        hint_surface::Symbol = :cli,
        verbosity_explicit::Bool = false,
        hosts_flag::AbstractVector{<:AbstractString} = String[],
    )
    v = _resolve_kit_verbosity(; quiet = quiet, verbosity = verbosity)
    hf = hosts_file === nothing ? nothing : String(hosts_file)
    surface = _normalize_hint_surface(hint_surface)
    explicit = verbosity_explicit || quiet || verbosity !== nothing
    return KitCliSession(
        v === :quiet,
        v,
        yes,
        hf,
        show_version,
        surface,
        explicit,
        String[String(h) for h in hosts_flag],
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

"""Default session; honors `DISTSSH_QUIET`, `DISTSSH_PROGRESS`, `DISTSSH_VERBOSE`, `DISTSSH_YES`, `DISTSSH_HOSTS_FILE`."""
function default_kit_cli_session()::KitCliSession
    hosts_file = let raw = strip(get(ENV, "DISTSSH_HOSTS_FILE", ""))
        isempty(raw) ? nothing : String(raw)
    end
    env_v = _env_verbosity()
    hosts_kw = (;
        yes = _env_flag("DISTSSH_YES"),
        hosts_file = hosts_file,
        show_version = false,
    )
    env_v === nothing && return KitCliSession(; hosts_kw...)
    return KitCliSession(;
        quiet = env_v === :quiet,
        verbosity = env_v,
        verbosity_explicit = true,
        hosts_kw...,
    )
end

function apply_kit_cli_session!(session::KitCliSession)
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

function _set_session_verbosity!(session::KitCliSession, v::Symbol)
    if session.verbosity_explicit && session.verbosity !== v
        throw(ArgumentError("cannot combine --quiet (-q), --progress, and --verbose"))
    end
    session.verbosity = v
    session.quiet = v === :quiet
    session.verbosity_explicit = true
    return session
end

"""Consume one shared CLI flag from `c`; return `true` if consumed."""
function consume_kit_cli_flag!(c::CliCursor, session::KitCliSession)::Bool
    arg = cli_current(c)
    arg === nothing && return false
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
        return true
    elseif _flag_match(arg, _KIT_CLI_FLAGS.hosts)
        append!(session.hosts_flag, split_hosts_csv(cli_take_value!(c, arg)))
        return true
    end
    return false
end

"""
Split leading shared flags from `args`.

Returns `(session, rest)` where `rest` is every non-flag token (and tokens
following flags that take values other than `--hosts-file` / `--hosts`).
"""
function peel_kit_cli_flags(args::AbstractVector{<:AbstractString})::Tuple{KitCliSession, Vector{String}}
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
        p = parse_placement_token(tok)
        return p.role === :parent ? PARENT_HOST_NAME : p.name
    end
    return split_worker_token(tok)[1]
end

"""`--hosts`, `DISTSSH_HOSTS`, then `--hosts-file` / `DISTSSH_HOSTS_FILE`.

`keep_counts=true` (go / drive) keeps tokens as written. `false` (setup / size)
strips `:N`. Size and setup pass `roles=true` so `child:NAME[:N]` becomes
`NAME` and `parent` stays `parent`.
"""
function kit_host_source_tokens(
        session::KitCliSession;
        keep_counts::Bool = true,
        roles::Bool = false,
    )::Vector{String}
    out = String[_kit_host_token(t, keep_counts; roles = roles) for t in session.hosts_flag]
    for t in split_hosts_csv(get(ENV, "DISTSSH_HOSTS", ""))
        push!(out, _kit_host_token(t, keep_counts; roles = roles))
    end
    hosts_file = session.hosts_file
    if hosts_file !== nothing
        if keep_counts
            append!(out, read_hosts_file_lines(hosts_file; surface = session.hint_surface))
        elseif roles
            for line in read_hosts_file_lines(hosts_file; surface = session.hint_surface)
                push!(out, _kit_host_token(line, false; roles = true))
            end
        else
            append!(out, read_hosts_file(hosts_file; surface = session.hint_surface))
        end
    end
    return out
end

function append_kit_host_sources!(
        hosts::Vector{String},
        session::KitCliSession;
        keep_counts::Bool = true,
        roles::Bool = false,
    )
    append!(hosts, kit_host_source_tokens(session; keep_counts = keep_counts, roles = roles))
    return hosts
end

function append_hosts_file!(hosts::Vector{String}, session::KitCliSession)
    hosts_file = session.hosts_file
    hosts_file === nothing && return hosts
    append!(hosts, read_hosts_file(hosts_file; surface = session.hint_surface))
    return hosts
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
