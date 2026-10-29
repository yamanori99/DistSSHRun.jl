# setup! — Julian mirror of `julia -m DistSSHKit setup --<mode>`.

const _SETUP_BANG_MODES = (
    :delete,
    :ship_tree,
    :clone,
    :sync,
    :pull,
    :instantiate,
    :juliaup,
    :juliaup_update,
    :check,
    :runtest,
    :cleanup,
    :prune,
)

"""
    setup!(session::KitSession, mode::Symbol; kwargs...) -> SyncResult
    setup!(session::KitSession, modes::Symbol...) -> SyncResult

Prepare SSH hosts — same jobs as `julia -m DistSSHKit setup --…`.

| `mode` | CLI | Notes |
| --- | --- | --- |
| `:delete` | `--delete` | Destructive. Requires `confirm_path`. `session.yes` does not delete |
| `:ship_tree` | `--ship-tree` | Tar of the git file list into `runs/<run_id>/src/` |
| `:clone` | `--clone` | Requires `repo=`; clone runs **on the remote** |
| `:sync` | `--sync` | Push the local branch to origin, then detach each remote at that commit; confirm unless `session.yes`. A dirty tree is refused |
| `:pull` | `--pull` | Detach each remote at the local commit. Does not push to origin and does not run `git pull`; confirm unless `session.yes`. A dirty tree is refused |
| `:instantiate` | `--instantiate` | `julia=` (default `"auto"`) |
| `:juliaup` | `up` | Align Julia via juliaup on `child:NAME` and/or `parent` (`\$HOME/.juliaup` or Homebrew); confirm unless `session.yes`. Tip if kit parent patch lags channel latest |
| `:juliaup_update` | `up update` | `juliaup update` on those hosts (no `default`); confirm unless `session.yes` |
| `:check` | `--check` | `ignore_julia_version=`, `check_code_sync=` |
| `:runtest` | `--runtest` | job `Pkg.test()` on remotes; `julia=` |
| `:cleanup` | `--cleanup` | Kill stale workers (no confirm) |
| `:prune` | `--prune` | `.distsshkit` go/drive/setup/runs leaves. Requires `confirm_path`. `session.yes` does not delete. `older_days=`, `id=` |

Confirmations for other modes follow `session.yes` (CLI `-y`). `:delete` and
`:prune` authorize only `confirm_path`: a `String` when the session has one
SSH host, or a `Dict` of host alias => path. A host with no key is left in
place. An unknown key is an error. A mismatch throws
[`ConfirmPathMismatch`](@ref). These two modes do not read stdin. Any other
mode rejects `confirm_path`. Multiple modes run in order and stop on the first failure:

```julia
session = KitSession(workers=["child:user@h1"], remote="~/proj", yes=true)
setup!(session, :ship_tree, :instantiate)
setup!(session, :check; ignore_julia_version=true)
```

[`sync!`](@ref) / [`instantiate!`](@ref) remain as thin aliases for the common
deploy steps. Prefer `setup!` when you want the full CLI vocabulary in one place.
"""
function setup!(
        session::KitSession,
        mode::Symbol;
        repo::Union{Nothing, AbstractString} = nothing,
        julia::AbstractString = "auto",
        ignore_julia_version::Bool = false,
        check_code_sync::Bool = true,
        older_days::Union{Nothing, Integer} = nothing,
        id::Union{Nothing, AbstractString} = nothing,
        confirm_path = nothing,
        gitignore::Bool = true,
        allow_external_symlinks::Bool = false,
    )::SyncResult
    if !gitignore
        throw(ArgumentError("setup! gitignore is not valid on setup!(session, :$(mode))"))
    end
    _setup_bang_preflight!(session, mode; repo = repo)
    hosts = _setup_bang_host_list(session)
    if isempty(hosts)
        throw(ArgumentError(explain_no_hosts(; surface = hint_surface(session), kind = :ssh)))
    end
    validate_setup_hosts(hosts; allow_parent = setup_mode_allows_parent(mode))
    bound_plan = _setup_bind_confirm_path!(session, mode, confirm_path, hosts)
    log_dir = setup_log_dir(session.project)
    step = setup_progress_step_name(mode)
    return _with_kit_inproc_run!(:setup) do
        apply_session_env!(session)
        with_kit_setup_progress(
            log_dir,
            step;
            path_anchor = session.project,
        ) do
            _setup_one!(
                session,
                mode;
                repo = repo,
                julia = julia,
                ignore_julia_version = ignore_julia_version,
                check_code_sync = check_code_sync,
                older_days = older_days,
                id = id,
                bound_plan = bound_plan,
                gitignore = gitignore,
                allow_external_symlinks = allow_external_symlinks,
            )
        end
    end
end

function setup!(session::KitSession, mode::Symbol, more::Symbol...; kwargs...)
    modes = (mode, more...)
    if !isempty(kwargs) && length(modes) > 1
        throw(
            ArgumentError(
                "setup! with multiple modes does not take keyword arguments; " *
                    "call setup!(session, mode; …) per step, or pass modes that need no kwargs. " *
                    "Pass confirm_path only on setup!(session, :delete) or setup!(session, :prune)",
            )
        )
    end
    return _with_kit_inproc_run!(:setup) do
        _setup_bang_run_modes!(session, modes; kwargs...)
    end
end

function _setup_bang_run_modes!(session::KitSession, modes; kwargs...)
    result = SyncResult(false, HostResult[]; ok = true)
    for m in modes
        result = setup!(session, m; kwargs...)
        result.ok || return result
    end
    return result
end

"""Non-empty clone URL, or throw."""
function _setup_clone_url(
        repo::Union{Nothing, AbstractString};
        surface::Symbol = :api,
    )::String
    repo === nothing && throw(
        ArgumentError(
            explain_clone_repo_required(; surface = surface),
        )
    )
    url = strip(String(repo))
    isempty(url) && throw(ArgumentError("setup! :clone repo= must be a non-empty git URL"))
    return url
end

function _setup_bang_preflight!(
        session::KitSession,
        mode::Symbol;
        repo::Union{Nothing, AbstractString} = nothing,
    )
    mode === :rsync && _throw_rsync_removed()
    mode in _SETUP_BANG_MODES || throw(
        ArgumentError(
            "setup! mode must be one of $(_SETUP_BANG_MODES), got $(repr(mode))",
        )
    )
    if mode === :clone
        _setup_clone_url(repo; surface = hint_surface(session))
    end
    return nothing
end

"""True when a confirm path contains a newline, carriage return, or NUL."""
function _confirm_path_control_char(raw::AbstractString)::Bool
    return any(c -> c == '\n' || c == '\r' || c == '\0', String(raw))
end

"""
    ConfirmPathMismatch(mode, given, expected)

`setup!` `:delete` or `:prune` received a `confirm_path` that is not the
remote target. `mode` is `:delete` or `:prune`. `given` is the path that was
passed. `expected` is the target. Do not copy `expected` into a retry.
"""
struct ConfirmPathMismatch <: Exception
    mode::Symbol
    given::String
    expected::String
end

function Base.showerror(io::IO, err::ConfirmPathMismatch)
    print(io, "ConfirmPathMismatch: setup! confirm_path for :")
    print(io, err.mode)
    print(io, " does not match ")
    print(io, repr(err.expected))
    print(io, " (got ")
    print(io, repr(err.given))
    print(io, "). See help setup.")
    return nothing
end

"""
    normalize_remote_confirm_path(path) -> String

Syntactic form of a remote confirm path. Strips a trailing `/` except on
`/`, collapses `//` and `/./`, rejects `..`, and writes a relative path as
`~/…`. Does not expand `~` and does not call `expanduser`, `abspath`, or
`realpath`.

# Examples
```jldoctest
julia> using DistSSHRun

julia> DistSSHRun.normalize_remote_confirm_path("~/App.jl/")
"~/App.jl"

julia> DistSSHRun.normalize_remote_confirm_path("App.jl")
"~/App.jl"
```
"""
function normalize_remote_confirm_path(path::AbstractString)::String
    raw = String(path)
    _confirm_path_control_char(raw) && throw(
        ArgumentError("setup! confirm_path cannot contain a newline or NUL. See help setup."),
    )
    s = strip(raw)
    isempty(s) && throw(
        ArgumentError("setup! confirm_path must be a non-empty path. See help setup."),
    )
    collapsed = _collapse_remote_confirm_path(s)
    if collapsed === nothing
        if any(part -> part == "..", split(s, '/'))
            throw(
                ArgumentError(
                    "setup! confirm_path must not contain .. . See help setup.",
                )
            )
        end
        throw(
            ArgumentError(
                "setup! confirm_path must be a non-empty path. See help setup.",
            )
        )
    end
    return collapsed
end

public ConfirmPathMismatch
public normalize_remote_confirm_path

function _posix_confirm_parts(path::AbstractString)::Union{Nothing, Vector{String}}
    parts = String[]
    for part in split(String(path), '/')
        isempty(part) && continue
        part == "." && continue
        part == ".." && return nothing
        push!(parts, String(part))
    end
    return parts
end

"""`nothing` when `path` contains `..`. Relative paths become `~/…`."""
function _collapse_remote_confirm_path(path::AbstractString)::Union{Nothing, String}
    s = String(path)
    if startswith(s, "/")
        parts = _posix_confirm_parts(s)
        parts === nothing && return nothing
        return isempty(parts) ? "/" : "/" * join(parts, "/")
    end
    if startswith(s, "~")
        rest = s[nextind(s, 1):end]
        if isempty(rest)
            return "~"
        end
        if startswith(rest, "/")
            parts = _posix_confirm_parts(rest)
            parts === nothing && return nothing
            return isempty(parts) ? "~" : "~/" * join(parts, "/")
        end
        slash = findfirst('/', rest)
        if slash === nothing
            (rest == "." || rest == "..") && return nothing
            return "~" * rest
        end
        user = rest[1:prevind(rest, slash)]
        body = rest[nextind(rest, slash):end]
        (isempty(user) || user == "." || user == "..") && return nothing
        parts = _posix_confirm_parts(body)
        parts === nothing && return nothing
        prefix = "~" * user
        return isempty(parts) ? prefix : prefix * "/" * join(parts, "/")
    end
    parts = _posix_confirm_parts(s)
    parts === nothing && return nothing
    isempty(parts) && return nothing
    return "~/" * join(parts, "/")
end

function _is_login_tilde(path::AbstractString)::Bool
    s = String(path)
    return s == "~" || startswith(s, "~/")
end

function _expand_login_tilde(path::AbstractString, home::AbstractString)::String
    s = String(path)
    _is_login_tilde(s) || return s
    h = rstrip(String(home), '/')
    s == "~" && return h
    rest = s[nextind(s, 2):end]
    return isempty(rest) ? h : h * "/" * rest
end

function _depot_target_strings()::Vector{String}
    raw = String["~/.julia"]
    if !isempty(DEPOT_PATH)
        push!(raw, String(DEPOT_PATH[1]))
    end
    push!(raw, joinpath(homedir(), ".julia"))
    out = String[]
    for path in raw
        push!(
            out, something(
                try
                    normalize_remote_confirm_path(path)
                catch
                    nothing
                end, ""
            )
        )
    end
    return filter(!isempty, out)
end

"""Throw when `path` is the Julia depot. Other dangerous paths use `_checked_remote_dest`."""
function _refuse_depot_target(path::AbstractString)
    norm = try
        normalize_remote_confirm_path(path)
    catch
        return nothing
    end
    if norm in _depot_target_strings()
        throw(
            ArgumentError(
                "refusing to delete the Julia depot $(repr(norm)). See help setup.",
            )
        )
    end
    return nothing
end

function _assert_confirm_target_allowed(path::AbstractString)::String
    dest = _checked_remote_dest(path)
    _refuse_depot_target(dest)
    return dest
end

"""One SSH call: the remote login home. The script is POSIX `sh`."""
function _remote_login_home(host::AbstractString)::String
    script = "printf '%s\\n' \"\$HOME\" # DISTSSHKIT_REMOTE_HOME"
    err_buf = IOBuffer()
    local out::String
    try
        out = String(
            read(
                pipeline(_host_sync_remote_shell_cmd(String(host), script); stderr = err_buf),
                String,
            ),
        )
    catch err
        detail = strip(String(take!(err_buf)))
        throw(
            ArgumentError(
                "could not read \$HOME on $(host) ($(summarize_ssh_error(err; stderr = detail))). See help setup.",
            )
        )
    end
    home = strip(out)
    if isempty(home) || !startswith(home, "/")
        throw(ArgumentError("could not read \$HOME on $(host). See help setup."))
    end
    return rstrip(home, '/')
end

"""
Resolved path to pass to `rm` when `given` matches `expected` on `host`.

Equal logical forms do not open SSH. A `~/…` form that differs from an
absolute form reads the remote login home once on `host`.
"""
function resolve_setup_confirm_path(
        mode::Symbol,
        host::AbstractString,
        given::AbstractString,
        expected::AbstractString,
    )::String
    g = normalize_remote_confirm_path(given)
    e = normalize_remote_confirm_path(expected)
    # Two `~/…` forms that already differ cannot become equal by expanding `$HOME`.
    needs_home = g != e &&
        (_is_login_tilde(g) || _is_login_tilde(e)) &&
        !(_is_login_tilde(g) && _is_login_tilde(e))
    if needs_home
        home = _remote_login_home(host)
        g = normalize_remote_confirm_path(_expand_login_tilde(g, home))
        e = normalize_remote_confirm_path(_expand_login_tilde(e, home))
    end
    g == e || throw(ConfirmPathMismatch(mode, strip(String(given)), e))
    return _assert_confirm_target_allowed(g)
end

function _confirm_path_dict(raw::AbstractDict)::Dict{String, String}
    out = Dict{String, String}()
    for (key, value) in pairs(raw)
        key isa AbstractString || throw(
            ArgumentError(
                "setup! confirm_path keys must be host-alias strings. See help setup.",
            )
        )
        value isa AbstractString || throw(
            ArgumentError(
                "setup! confirm_path values must be paths. See help setup.",
            )
        )
        name = String(key)
        haskey(out, name) && throw(
            ArgumentError(
                "setup! confirm_path repeats host $(repr(name)). See help setup.",
            )
        )
        out[name] = String(value)
    end
    return out
end

function _setup_ssh_aliases(hosts::AbstractVector{<:AbstractString})::Vector{String}
    return String[String(host) for host in hosts if !is_parent_host_name(host)]
end

"""`host =>` path to delete. `nothing` when this mode does not take `confirm_path`."""
function _setup_bind_confirm_path!(
        session::KitSession,
        mode::Symbol,
        confirm_path,
        hosts::AbstractVector{<:AbstractString},
    )::Union{Nothing, Dict{String, String}}
    if mode !== :delete && mode !== :prune
        confirm_path === nothing && return nothing
        throw(
            ArgumentError(
                "setup! confirm_path is only valid on setup!(session, :delete) or setup!(session, :prune). See help setup.",
            )
        )
    end
    expected = mode === :delete ?
        remote_delete_root(session.project; cli_override = session.remote) :
        _checked_remote_dest(session_remote_root(session))
    _refuse_depot_target(expected)
    aliases = _setup_ssh_aliases(hosts)
    if confirm_path === nothing
        throw(
            ArgumentError(
                "setup!(session, :$(mode)) requires confirm_path equal to the target $(repr(expected)). " *
                    "A String is only for one host; pass a Dict of host alias => path for more than one. " *
                    "session.yes does not authorize this. See help setup.",
            )
        )
    end
    if confirm_path isa AbstractString
        length(aliases) == 1 || throw(
            ArgumentError(
                "setup! confirm_path as a String is only valid for one host; pass a Dict of host alias => path. See help setup.",
            )
        )
        return Dict(aliases[1] => resolve_setup_confirm_path(mode, aliases[1], confirm_path, expected))
    end
    confirm_path isa AbstractDict || throw(
        ArgumentError(
            "setup! confirm_path must be a String or a Dict of host alias => path. See help setup.",
        )
    )
    raw = _confirm_path_dict(confirm_path)
    isempty(raw) && throw(
        ArgumentError(
            "setup! confirm_path must name at least one host. See help setup.",
        )
    )
    known = Set(aliases)
    for key in keys(raw)
        key in known || throw(
            ArgumentError(
                "setup! confirm_path has unknown host $(repr(key)). Keys are the configured host alias, exact. See help setup.",
            )
        )
    end
    plan = Dict{String, String}()
    for alias in aliases
        haskey(raw, alias) || continue
        plan[alias] = resolve_setup_confirm_path(mode, alias, raw[alias], expected)
    end
    isempty(plan) && throw(
        ArgumentError(
            "setup! confirm_path did not name a host to delete. See help setup.",
        )
    )
    return plan
end

"""Per-host plans for one CLI `--confirm-path` value. Empty `givens` is `nothing`."""
function _setup_confirm_plans(
        hosts::AbstractVector{<:AbstractString},
        mode::Symbol,
        givens::AbstractVector{<:AbstractString},
        expected::AbstractString,
    )::Union{Nothing, Dict{String, String}}
    isempty(givens) && return nothing
    first = nothing
    for given in givens
        plan = Dict{String, String}()
        for host in hosts
            plan[String(host)] = resolve_setup_confirm_path(mode, host, given, expected)
        end
        if first === nothing
            first = plan
        elseif first != plan
            throw(ConfirmPathMismatch(mode, strip(String(given)), expected))
        end
    end
    return first
end

function _merge_host_ops(parts)::NamedTuple
    cancelled = false
    succeeded = 0
    failed = 0
    host_results = HostResult[]
    for raw in parts
        cancelled |= raw.cancelled
        succeeded += raw.succeeded
        failed += raw.failed
        append!(host_results, raw.hosts)
    end
    return (; cancelled, succeeded, failed, hosts = host_results)
end

function _confirmed_path_groups(
        hosts::AbstractVector{<:AbstractString},
        plan::Dict{String, String},
    )::Vector{Pair{String, Vector{String}}}
    groups = Dict{String, Vector{String}}()
    order = String[]
    for host in hosts
        name = String(host)
        haskey(plan, name) || continue
        path = plan[name]
        if !haskey(groups, path)
            push!(order, path)
            groups[path] = String[]
        end
        push!(groups[path], name)
    end
    isempty(order) && throw(
        ArgumentError(
            "setup! confirm_path did not name a host to delete. See help setup.",
        )
    )
    return [path => groups[path] for path in order]
end

function _apply_confirmed_delete(
        hosts::AbstractVector{<:AbstractString},
        plan::Dict{String, String},
    )::NamedTuple
    parts = NamedTuple[]
    for (path, group) in _confirmed_path_groups(hosts, plan)
        push!(parts, delete_remotes(group, path; confirm = false))
    end
    return _merge_host_ops(parts)
end

function _apply_confirmed_prune(
        hosts::AbstractVector{<:AbstractString},
        plan::Dict{String, String},
        project::AbstractString;
        older_days::Union{Nothing, Integer} = nothing,
        id::Union{Nothing, AbstractString} = nothing,
        skip_setup::Union{Nothing, AbstractString} = nothing,
    )::NamedTuple
    parts = NamedTuple[]
    include_local = true
    for (path, group) in _confirmed_path_groups(hosts, plan)
        push!(
            parts,
            prune_kit_leaves(
                group,
                path,
                project;
                confirm = false,
                older_days = older_days,
                id = id,
                skip_setup = skip_setup,
                include_local = include_local,
            ),
        )
        include_local = false
    end
    return _merge_host_ops(parts)
end

function _setup_one!(
        session::KitSession,
        mode::Symbol;
        repo::Union{Nothing, AbstractString} = nothing,
        julia::AbstractString = "auto",
        ignore_julia_version::Bool = false,
        check_code_sync::Bool = true,
        older_days::Union{Nothing, Integer} = nothing,
        id::Union{Nothing, AbstractString} = nothing,
        bound_plan::Union{Nothing, Dict{String, String}} = nothing,
        gitignore::Bool = true,
        allow_external_symlinks::Bool = false,
    )::SyncResult
    if !gitignore
        throw(ArgumentError("setup! gitignore is not valid on setup!(session, :$(mode))"))
    end
    _setup_bang_preflight!(session, mode; repo = repo)
    hosts = _setup_bang_hosts!(session; allow_parent = setup_mode_allows_parent(mode))
    remote_path = session_remote_root(session)
    julia_path = isempty(strip(String(julia))) ? "auto" : String(julia)

    if mode === :delete
        plan = _setup_require_plan(bound_plan)
        touch = _hosts_named_in_plan(hosts, plan)
        preflight_setup_ssh(touch) || return SyncResult(false, HostResult[]; ok = false)
        raw = _apply_confirmed_delete(touch, plan)
        return _sync_result_from_host_op(raw)
    elseif mode === :rsync
        _throw_rsync_removed()
    elseif mode === :ship_tree
        return sync!(
            session;
            mode = :ship_tree,
            allow_external_symlinks = allow_external_symlinks,
        )
    elseif mode === :clone
        ensure_manifest_in_git_worktree!(session.project)
        url = normalize_git_clone_url(_setup_clone_url(repo; surface = hint_surface(session)))
        preflight_setup_ssh(hosts) || return SyncResult(false, HostResult[]; ok = false)
        clone_dest = remote_git_clone_dest(session.project; cli_override = session.remote)
        raw = clone_to_remotes(hosts, clone_dest, url; confirm = !session.yes)
        return _sync_result_from_host_op(raw)
    elseif mode === :sync
        return sync!(session; mode = :sync)
    elseif mode === :pull
        apply_session_env!(session)
        raw = git_sync_project_to_hosts!(
            hosts,
            session.project,
            remote_path;
            do_push = false,
            do_pull = true,
            confirm = !session.yes,
        )
        if raw.cancelled
            return SyncResult(true, HostResult[]; ok = false)
        end
        return SyncResult(false, raw.host_results; ok = raw.ok)
    elseif mode === :instantiate
        return instantiate!(session; julia = julia_path)
    elseif mode === :juliaup || mode === :juliaup_update
        ssh_hosts = setup_juliaup_ssh_hosts(hosts)
        if !isempty(ssh_hosts)
            preflight_setup_ssh(ssh_hosts) || return SyncResult(false, HostResult[]; ok = false)
        end
        raw = mode === :juliaup ?
            juliaup_align_remotes(hosts; confirm = !session.yes) :
            juliaup_update_remotes(hosts; confirm = !session.yes)
        return _sync_result_from_host_op(raw)
    elseif mode === :runtest
        preflight_setup_ssh(hosts) || return SyncResult(false, HostResult[]; ok = false)
        work_path = _work_root_for_hosts(hosts, remote_path)
        raw = runtest_remotes(
            hosts, julia_path, work_path, session.project;
            path_anchor = session.project,
        )
        return _sync_result_from_host_op(raw)
    elseif mode === :check
        work_path = _work_root_for_hosts(hosts, remote_path)
        result = check_prerequisites(
            hosts,
            julia_path,
            work_path,
            session.project;
            path_anchor = session.project,
            require_clean_git = false,
            check_code_sync = check_code_sync,
            ignore_julia_version = ignore_julia_version,
        )
        if result.ok
            print_ok("All prerequisites met.")
            kit_println()
        else
            print_err("Prerequisites not met. Fix issues above and retry.")
            kit_println()
        end
        return SyncResult(false, HostResult[]; ok = result.ok, warnings = result.warnings)
    elseif mode === :cleanup
        raw = cleanup_remote_workers(hosts)
        return _sync_result_from_host_op(raw)
    elseif mode === :prune
        plan = _setup_require_plan(bound_plan)
        touch = _hosts_named_in_plan(hosts, plan)
        preflight_setup_ssh(touch) || return SyncResult(false, HostResult[]; ok = false)
        log_dir = setup_log_dir(session.project)
        raw = _apply_confirmed_prune(
            touch,
            plan,
            session.project;
            older_days = older_days,
            id = id,
            skip_setup = log_dir,
        )
        return _sync_result_from_host_op(raw)
    end
    # Unreachable when `_SETUP_BANG_MODES` stays in sync with branches above.
    throw(ArgumentError("setup! mode $(repr(mode)) is not implemented"))
end

function _setup_require_plan(plan::Union{Nothing, Dict{String, String}})::Dict{String, String}
    plan isa Dict || throw(
        ArgumentError(
            "setup!(session, :delete) and setup!(session, :prune) require confirm_path. See help setup.",
        )
    )
    return plan
end

function _hosts_named_in_plan(
        hosts::AbstractVector{<:AbstractString},
        plan::Dict{String, String},
    )::Vector{String}
    touch = String[]
    for host in hosts
        name = String(host)
        haskey(plan, name) && push!(touch, name)
    end
    return touch
end

"""SSH aliases plus `parent` when a token names the kit parent. Does not touch `ENV`."""
function _setup_bang_host_list(session::KitSession)::Vector{String}
    hosts = copy(session.hosts)
    # `session.hosts` is SSH children only; parent lives on `tokens`.
    # Always surface `parent` so non-juliaup modes hit validate_setup_hosts
    # instead of silently dropping it.
    for t in session.tokens
        pt = try
            parse_placement_token(t)
        catch
            nothing
        end
        pt === nothing && continue
        if pt.role === :parent
            push!(hosts, PARENT_HOST_NAME)
            break
        end
    end
    return hosts
end

function _setup_bang_hosts!(session::KitSession; allow_parent::Bool = false)
    apply_session_env!(session)
    hosts = _setup_bang_host_list(session)
    isempty(hosts) && throw(
        ArgumentError(
            explain_no_hosts(; surface = hint_surface(session), kind = :ssh),
        )
    )
    validate_setup_hosts(hosts; allow_parent = allow_parent)
    return hosts
end

function _sync_result_from_host_op(raw)::SyncResult
    hrs = hasproperty(raw, :hosts) ? collect(HostResult, raw.hosts) : HostResult[]
    return SyncResult(
        raw.cancelled,
        hrs;
        ok = !raw.cancelled && raw.failed == 0,
    )
end
