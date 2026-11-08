# Explicit snapshot selection, local deployment record, and host validation.
# Snapshot IDs are remote `runs/<run_id>/` leaves under the resolved deploy root.

const _SNAPSHOT_RECORD_SCHEMA = 1
const _SNAPSHOT_RECORD_NAME = "last-snapshot.toml"
const _SNAPSHOT_RECORD_LOCK = ReentrantLock()

"""Resolved source for preparation, execution, and collect path mapping."""
struct SnapshotSelection
    source_kind::Symbol
    snapshot_id::Union{Nothing, String}
    deploy_root::String
    work_root::String
    content_tree_hash::Union{Nothing, String}
    hosts::Vector{String}
end
public SnapshotSelection

function Base.show(io::IO, sel::SnapshotSelection)
    print(io, "SnapshotSelection(")
    print(io, "source_kind=", repr(sel.source_kind))
    print(io, ", snapshot_id=", repr(sel.snapshot_id))
    print(io, ", deploy_root=", repr(sel.deploy_root))
    print(io, ", work_root=", repr(sel.work_root))
    print(io, ", content_tree_hash=", repr(sel.content_tree_hash))
    print(io, ", hosts=", sel.hosts)
    return print(io, ")")
end

"""Validate a snapshot ID as a single safe path component (`validate_run_id`)."""
function validate_snapshot_id(snapshot_id::AbstractString)::String
    s = String(snapshot_id)
    (occursin('/', s) || occursin('\\', s) || occursin('\0', s) || s == "." || s == "..") &&
        throw(
        ArgumentError(
            "snapshot id must be a single path component matching YYYYMMDDTHHMMSSZ-xxxxxx, got $(repr(s))",
        ),
    )
    return validate_run_id(s)
end
public validate_snapshot_id

const _CONTENT_TREE_HASH_RE = r"^[0-9a-fA-F]{40}$"

"""True when `hash` is a 40-digit hex Git tree hash (`git-sha1`)."""
function _valid_content_tree_hash(hash::AbstractString)::Bool
    return occursin(_CONTENT_TREE_HASH_RE, String(hash))
end

function _snapshot_src_logical(deploy_root::AbstractString, snapshot_id::AbstractString)::String
    return _posix_join(String(deploy_root), "runs", validate_snapshot_id(snapshot_id), "src")
end

function _snapshot_leaf_logical(deploy_root::AbstractString, snapshot_id::AbstractString)::String
    return _posix_join(String(deploy_root), "runs", validate_snapshot_id(snapshot_id))
end

function _snapshot_record_dir(env_dir::AbstractString)::String
    return joinpath(canonical_local_path(env_dir), ".distsshkit")
end

function _snapshot_record_path(env_dir::AbstractString)::String
    return joinpath(_snapshot_record_dir(env_dir), _SNAPSHOT_RECORD_NAME)
end

function _sorted_host_aliases(hosts::AbstractVector{<:AbstractString})::Vector{String}
    out = String[_record_host_alias(h) for h in hosts]
    return sort!(unique!(out))
end

function _hosts_covered(
        have::AbstractVector{<:AbstractString},
        need::AbstractVector{<:AbstractString},
    )::Bool
    have_set = Set{String}(_sorted_host_aliases(have))
    return all(h -> h in have_set, _sorted_host_aliases(need))
end

"""Strip surrounding space and a trailing `/` so `/srv/app` and `/srv/app/` match."""
function _normalize_deploy_root(path::AbstractString)::String
    return rstrip(strip(String(path)), '/')
end

"""True when two deploy-root spellings name the same tree after normalization."""
function _deploy_roots_equivalent(a::AbstractString, b::AbstractString)::Bool
    return _normalize_deploy_root(a) == _normalize_deploy_root(b)
end

"""Read the local last-snapshot record, or `nothing` when absent or unreadable."""
function read_last_snapshot_record(
        env_dir::AbstractString,
    )::Union{Nothing, Dict{String, Any}}
    path = _snapshot_record_path(env_dir)
    isfile(path) || return nothing
    raw = try
        TOML.parsefile(path)
    catch
        return nothing
    end
    raw isa AbstractDict || return nothing
    schema = get(raw, "schema", nothing)
    schema isa Integer || return nothing
    Int(schema) == _SNAPSHOT_RECORD_SCHEMA || return nothing
    return Dict{String, Any}(String(k) => v for (k, v) in raw)
end
public read_last_snapshot_record

function _record_matches_selection(
        rec::AbstractDict,
        deploy_root::AbstractString,
        hosts::AbstractVector{<:AbstractString},
    )::Bool
    stored_root = get(rec, "deploy_root", nothing)
    stored_root isa AbstractString || return false
    _deploy_roots_equivalent(stored_root, deploy_root) || return false
    stored_hosts = get(rec, "hosts", nothing)
    stored_hosts isa AbstractVector || return false
    return _hosts_covered(String[String(h) for h in stored_hosts], hosts)
end

"""
Write the local last-snapshot convenience record.

Keyed by local package `env_dir` and the resolved deployment root. Stores the
successful host aliases from this ship. Another local deployer can overwrite
this file between commands; pass the returned snapshot ID instead of rereading
it in programmatic workflows. Does not detect local source changes.
"""
function write_last_snapshot_record!(
        env_dir::AbstractString,
        deploy_root::AbstractString,
        hosts::AbstractVector{<:AbstractString},
        snapshot_id::AbstractString;
        content_tree_hash::Union{Nothing, AbstractString} = nothing,
    )::String
    rid = validate_snapshot_id(snapshot_id)
    aliases = _sorted_host_aliases(hosts)
    isempty(aliases) && throw(ArgumentError("last-snapshot record needs at least one host"))
    data = Dict{String, Any}(
        "schema" => _SNAPSHOT_RECORD_SCHEMA,
        "deploy_root" => _normalize_deploy_root(deploy_root),
        "hosts" => aliases,
        "snapshot_id" => rid,
        "written_at" => Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z",
    )
    if content_tree_hash isa AbstractString && !isempty(strip(String(content_tree_hash)))
        data["content_tree_hash"] = String(content_tree_hash)
    end
    dest_dir = _snapshot_record_dir(env_dir)
    dest = _snapshot_record_path(env_dir)
    lock(_SNAPSHOT_RECORD_LOCK) do
        mkpath(dest_dir)
        tmp = dest * ".tmp." * string(getpid()) * "." * bytes2hex(rand(UInt8, 4))
        open(tmp, "w") do io
            TOML.print(io, data)
        end
        mv(tmp, dest; force = true)
    end
    return dest
end
public write_last_snapshot_record!

function clear_last_snapshot_record!(
        env_dir::AbstractString;
        deploy_root::Union{Nothing, AbstractString} = nothing,
    )::Nothing
    path = _snapshot_record_path(env_dir)
    lock(_SNAPSHOT_RECORD_LOCK) do
        isfile(path) || return nothing
        if deploy_root !== nothing
            rec = try
                TOML.parsefile(path)
            catch
                Dict{String, Any}()
            end
            stored = get(rec, "deploy_root", nothing)
            if stored isa AbstractString &&
                    !_deploy_roots_equivalent(stored, deploy_root)
                return nothing
            end
        end
        rm(path; force = true)
    end
    return nothing
end

"""Drop the local last-snapshot convenience default for `deploy_root`.

Call after a successful `:delete`, `:clone`, `:sync`, or `:pull` so a later
instantiate / check / go / drive can select a git checkout at that root. Does
not delete remote `runs/<id>/` leaves. An explicit `--snapshot` still works.
Also clears this process's ship cache when it targeted the same deploy root.
`/srv/app` and `/srv/app/` are the same root.
"""
function forget_last_snapshot_default!(
        local_project::AbstractString,
        deploy_root::AbstractString,
    )::Nothing
    env = resolve_pkg_env(local_project)
    clear_last_snapshot_record!(env.env_dir; deploy_root = String(deploy_root))
    last = last_ship_result()
    if last !== nothing
        stored = get(last, "remote_root", nothing)
        if stored isa AbstractString &&
                _deploy_roots_equivalent(stored, deploy_root)
            _clear_last_ship!()
        end
    end
    return nothing
end
public forget_last_snapshot_default!

"""Probe whether `host` has a completed snapshot leaf under `deploy_root`."""
function _probe_snapshot_complete(
        host::AbstractString,
        deploy_root::AbstractString,
        snapshot_id::AbstractString,
    )::NamedTuple
    rid = validate_snapshot_id(snapshot_id)
    abs_root = try
        _probe_expanded_remote_root(host, deploy_root)
    catch e
        e isa InterruptException && rethrow()
        return (
            ok = false,
            reason = "deploy_root",
            message = "could not resolve deploy root on $(host): $(sprint(showerror, e))",
            content_tree_hash = nothing,
        )
    end
    leaf = _posix_join(abs_root, "runs", rid)
    src = _posix_join(leaf, "src")
    stamp = _posix_join(leaf, "run.toml")
    lq = _remote_shell_path_word(leaf)
    sq = _remote_shell_path_word(src)
    tq = _remote_shell_path_word(stamp)
    script = """
    # __DSR_SNAP_COMPLETE__
    if test ! -d $lq; then
      printf 'missing\\n'
      exit 0
    fi
    if test ! -f $tq; then
      printf 'legacy\\n'
      exit 0
    fi
    if test ! -f $sq/Project.toml && test ! -f $sq/JuliaProject.toml; then
      printf 'no_project\\n'
      exit 0
    fi
    n_schema=\$(grep -c '^schema = ' $tq || true)
    n_writer=\$(grep -c '^writer = ' $tq || true)
    n_kind=\$(grep -c '^kind = ' $tq || true)
    n_complete=\$(grep -c '^complete = ' $tq || true)
    n_algo=\$(grep -c '^algorithm = ' $tq || true)
    n_hash=\$(grep -c '^content_tree_hash = ' $tq || true)
    if [ "\$n_schema" != 1 ] || [ "\$n_writer" != 1 ] || [ "\$n_kind" != 1 ] ||
       [ "\$n_complete" != 1 ] || [ "\$n_algo" != 1 ] || [ "\$n_hash" != 1 ]; then
      printf 'stamp\\n'
      exit 0
    fi
    if ! grep -Eq '^schema = 1\$' $tq; then
      printf 'stamp\\n'
      exit 0
    fi
    if ! grep -Eq '^writer = "DistSSHRun [^"]*"\$' $tq; then
      printf 'stamp\\n'
      exit 0
    fi
    if ! grep -Eq '^kind = "ship"\$' $tq; then
      printf 'stamp\\n'
      exit 0
    fi
    if ! grep -Eq '^complete = true\$' $tq; then
      printf 'incomplete\\n'
      exit 0
    fi
    if ! grep -Eq '^algorithm = "git-sha1"\$' $tq; then
      printf 'stamp\\n'
      exit 0
    fi
    hash=\$(grep -E '^content_tree_hash = "' $tq | head -n 1 | sed -E 's/^content_tree_hash = "([0-9a-fA-F]+)"\$/\\1/')
    case "\$hash" in
      [0-9a-fA-F][0-9a-fA-F]*)
        if [ \${#hash} -eq 40 ]; then
          printf 'ok\\n'
          printf '%s\\n' "\$hash"
          exit 0
        fi
        ;;
    esac
    printf 'stamp\\n'
    exit 0
    """
    code, out = _remote_shell_status(String(host), script)
    code == 0 || return (
        ok = false,
        reason = "probe",
        message = "snapshot probe failed on $(host): $(strip(out))",
        content_tree_hash = nothing,
    )
    lines = split(strip(out), '\n'; keepempty = false)
    isempty(lines) && return (
        ok = false,
        reason = "probe",
        message = "empty snapshot probe on $(host)",
        content_tree_hash = nothing,
    )
    status = String(lines[1])
    status == "ok" || return (
        ok = false,
        reason = status,
        message = "snapshot $(rid) on $(host): $(status)",
        content_tree_hash = nothing,
    )
    hash = length(lines) >= 2 ? strip(String(lines[2])) : ""
    _valid_content_tree_hash(hash) || return (
        ok = false,
        reason = "stamp",
        message = "snapshot $(rid) on $(host): missing or invalid content_tree_hash",
        content_tree_hash = nothing,
    )
    return (
        ok = true,
        reason = "ok",
        message = "",
        content_tree_hash = hash,
    )
end

function _probe_git_project_at_root(
        host::AbstractString,
        deploy_root::AbstractString,
    )::Bool
    abs_root = try
        _probe_expanded_remote_root(host, deploy_root)
    catch e
        e isa InterruptException && rethrow()
        return false
    end
    rq = _remote_shell_path_word(abs_root)
    script = """
    # __DSR_SNAP_GIT__
    if test -f $rq/Project.toml || test -f $rq/JuliaProject.toml; then
      printf 'yes\\n'
    else
      printf 'no\\n'
    fi
    exit 0
    """
    code, out = _remote_shell_status(String(host), script)
    code == 0 || return false
    return startswith(strip(out), "yes")
end

function _selection_error(msg::AbstractString)
    return ArgumentError(String(msg))
end

function _validate_snapshot_on_hosts!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        snapshot_id::AbstractString,
    )::String
    rid = validate_snapshot_id(snapshot_id)
    isempty(hosts) && throw(_selection_error("snapshot selection needs at least one host"))
    hash = nothing
    problems = String[]
    for host in hosts
        probe = _probe_snapshot_complete(host, deploy_root, rid)
        if !probe.ok
            push!(problems, "$(host): $(probe.message)")
            continue
        end
        got = probe.content_tree_hash
        if !(got isa AbstractString) || !_valid_content_tree_hash(got)
            push!(problems, "$(host): missing or invalid content_tree_hash")
            continue
        end
        if hash === nothing
            hash = String(got)
        elseif String(got) != hash
            push!(
                problems,
                "$(host): content_tree_hash $(got) != $(hash)",
            )
        end
    end
    isempty(problems) || throw(
        _selection_error(
            "snapshot $(rid) is not selectable on every host:\n  " *
                join(problems, "\n  "),
        ),
    )
    hash isa AbstractString || throw(
        _selection_error(
            "snapshot $(rid) is not selectable: no content_tree_hash on any host",
        ),
    )
    return String(hash)
end

function _validate_git_on_hosts!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
    )::Nothing
    isempty(hosts) && throw(_selection_error("git source selection needs at least one host"))
    missing = String[]
    for host in hosts
        _probe_git_project_at_root(host, deploy_root) || push!(missing, String(host))
    end
    isempty(missing) || throw(
        _selection_error(
            "no completed snapshot selected and deploy root has no Project.toml on: " *
                join(missing, ", ") *
                ". Pass --snapshot ID after setup ship-tree, or deploy a git checkout.",
        ),
    )
    return nothing
end

"""
Resolve the remote project work root for `hosts` under `deploy_root`.

`snapshot` is an explicit snapshot ID (never falls back). When omitted, a local
last-snapshot record may supply the ID. Otherwise a git checkout at the deploy
root is used when every host has `Project.toml` there. Lexical latest
`runs/*/src` is not consulted.
"""
function resolve_snapshot_selection(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        local_project::AbstractString;
        snapshot::Union{Nothing, AbstractString} = nothing,
        skip_local_record::Bool = false,
    )::SnapshotSelection
    deploy = String(deploy_root)
    host_list = String[String(h) for h in hosts]
    env = resolve_pkg_env(local_project)
    if snapshot !== nothing
        rid = validate_snapshot_id(snapshot)
        hash = _validate_snapshot_on_hosts!(host_list, deploy, rid)
        return SnapshotSelection(
            :snapshot,
            rid,
            deploy,
            _snapshot_src_logical(deploy, rid),
            hash,
            host_list,
        )
    end
    # Same-process ship: use the recorded run_id, still validate on every host.
    last = skip_local_record ? nothing : last_ship_result()
    if last !== nothing && _SHIP_LAYOUT_ACTIVE[] &&
            _last_ship_src_for(host_list, deploy) !== nothing
        rid_raw = get(last, "run_id", nothing)
        if rid_raw isa AbstractString && !isempty(strip(String(rid_raw)))
            rid = validate_snapshot_id(rid_raw)
            hash = _validate_snapshot_on_hosts!(host_list, deploy, rid)
            return SnapshotSelection(
                :snapshot,
                rid,
                deploy,
                _snapshot_src_logical(deploy, rid),
                hash,
                host_list,
            )
        end
    end
    rec = skip_local_record ? nothing : read_last_snapshot_record(env.env_dir)
    if rec !== nothing && _record_matches_selection(rec, deploy, host_list)
        rid_raw = get(rec, "snapshot_id", nothing)
        rid_raw isa AbstractString || throw(
            _selection_error(
                "local last-snapshot record is missing snapshot_id; pass --snapshot ID",
            ),
        )
        rid = validate_snapshot_id(rid_raw)
        hash = _validate_snapshot_on_hosts!(host_list, deploy, rid)
        stored_hash = get(rec, "content_tree_hash", nothing)
        if stored_hash isa AbstractString && !isempty(strip(String(stored_hash)))
            stored = String(stored_hash)
            _valid_content_tree_hash(stored) || throw(
                _selection_error(
                    "local last-snapshot record content_tree_hash is not a 40-digit git-sha1 value; pass --snapshot ID",
                ),
            )
            stored == hash || throw(
                _selection_error(
                    "local last-snapshot record content_tree_hash $(stored) does not match remote $(hash); pass --snapshot ID",
                ),
            )
        end
        return SnapshotSelection(
            :snapshot,
            rid,
            deploy,
            _snapshot_src_logical(deploy, rid),
            hash,
            host_list,
        )
    end
    if rec !== nothing
        # Same deploy root but hosts do not cover: refuse (no silent other ID).
        # A record for a different deploy root is ignored so a second root
        # (git clone path, tilde root, …) can still select its checkout.
        stored_root = get(rec, "deploy_root", nothing)
        if stored_root isa AbstractString &&
                _deploy_roots_equivalent(stored_root, deploy)
            stored_hosts = get(rec, "hosts", nothing)
            if stored_hosts isa AbstractVector &&
                    !_hosts_covered(String[String(h) for h in stored_hosts], host_list)
                throw(
                    _selection_error(
                        "local last-snapshot record hosts $(stored_hosts) do not cover $(host_list); pass --snapshot ID",
                    ),
                )
            end
        end
    end
    _validate_git_on_hosts!(host_list, deploy)
    return SnapshotSelection(
        :git,
        nothing,
        deploy,
        deploy,
        nothing,
        host_list,
    )
end
public resolve_snapshot_selection

"""Controller `DISTSSHKIT_RUN_DIR/run.toml` shipped source for collect recovery.

`nothing` when no run dir is set, or when the stamp is not written yet
(in-flight execute). A present DistSSHRun stamp without `provenance.shipped`
is legacy and cannot recover the original source.
"""
function _controller_collect_source()
    rd = kit_run_dir()
    rd === nothing && return nothing
    path = kit_run_toml_path(rd)
    isfile(path) || return nothing
    raw = read_kit_run_toml(rd)
    raw === nothing && throw(
        _selection_error(
            "controller run.toml at $(path) is unreadable; pass --snapshot ID (legacy metadata cannot recover the original source)",
        ),
    )
    _kit_run_toml_owned(raw) || throw(
        _selection_error(
            "controller run.toml is not a DistSSHRun schema 1 stamp; refusing collect recovery",
        ),
    )
    prov = get(raw, "provenance", nothing)
    if !(prov isa AbstractDict)
        throw(
            _selection_error(
                "controller run.toml has no provenance.shipped; pass --snapshot ID (legacy metadata cannot recover the original source)",
            ),
        )
    end
    shipped = get(prov, "shipped", nothing)
    if !(shipped isa AbstractDict)
        throw(
            _selection_error(
                "controller run.toml has no provenance.shipped; pass --snapshot ID (legacy metadata cannot recover the original source)",
            ),
        )
    end
    kind_s = get(shipped, "source_kind", nothing)
    deploy = get(shipped, "deploy_root", nothing)
    work = get(shipped, "work_root", nothing)
    rid_raw = get(shipped, "run_id", nothing)
    source_kind = if kind_s isa AbstractString && String(kind_s) == "git"
        :git
    else
        :snapshot
    end
    rid = if rid_raw isa AbstractString && !isempty(strip(String(rid_raw)))
        validate_snapshot_id(rid_raw)
    else
        nothing
    end
    source_kind === :snapshot && rid === nothing && throw(
        _selection_error(
            "controller provenance.shipped has no run_id; pass --snapshot ID (legacy metadata cannot recover the original source)",
        ),
    )
    deploy_s = deploy isa AbstractString && !isempty(strip(String(deploy))) ?
        String(deploy) : nothing
    work_s = work isa AbstractString && !isempty(strip(String(work))) ?
        String(work) : nothing
    return (
        source_kind = source_kind,
        snapshot_id = rid,
        deploy_root = deploy_s,
        work_root = work_s,
    )
end

"""Snapshot / record policy for collect mapping, honoring controller provenance."""
function _collect_source_plan(
        explicit::Union{Nothing, AbstractString},
    )::NamedTuple{
        (:snapshot, :skip_local_record, :deploy_root),
        Tuple{Union{Nothing, String}, Bool, Union{Nothing, String}},
    }
    snap = explicit === nothing ? nothing : validate_snapshot_id(explicit)
    src = _controller_collect_source()
    src === nothing && return (
        snapshot = snap,
        skip_local_record = false,
        deploy_root = nothing,
    )
    if snap !== nothing
        if src.snapshot_id !== nothing && String(src.snapshot_id) != snap
            throw(
                _selection_error(
                    "controller provenance snapshot $(src.snapshot_id) does not match --snapshot $(snap)",
                ),
            )
        end
        return (
            snapshot = snap,
            skip_local_record = true,
            deploy_root = src.deploy_root,
        )
    end
    if src.source_kind === :git
        return (
            snapshot = nothing,
            skip_local_record = true,
            deploy_root = src.deploy_root,
        )
    end
    return (
        snapshot = src.snapshot_id,
        skip_local_record = true,
        deploy_root = src.deploy_root,
    )
end

"""Process-wide selection used for provenance when an execution did not ship."""
const _ACTIVE_SELECTION = Ref{Union{Nothing, SnapshotSelection}}(nothing)

function _clear_active_selection!()
    _ACTIVE_SELECTION[] = nothing
    return nothing
end

# Hook so `_clear_last_ship!` also drops the active selection.
_CLEAR_SELECTION_HOOK[] = () -> _clear_active_selection!()

function _set_active_selection!(sel::Union{Nothing, SnapshotSelection})
    _ACTIVE_SELECTION[] = sel
    return nothing
end

"""Process-wide [`SnapshotSelection`](@ref) from the last resolve or ship, or `nothing`."""
function active_snapshot_selection()::Union{Nothing, SnapshotSelection}
    return _ACTIVE_SELECTION[]
end
public active_snapshot_selection

"""Deploy root intended for layout when ENV may already be a work root."""
function _layout_intended_deploy_root(
        local_repo::AbstractString,
        sel::Union{Nothing, SnapshotSelection},
    )::String
    env_rr = strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))
    if sel !== nothing && !isempty(env_rr) &&
            _deploy_roots_equivalent(env_rr, sel.work_root)
        # After assign, ENV is the work root; keep the selection's deploy root.
        return String(sel.deploy_root)
    elseif !isempty(env_rr)
        return String(env_rr)
    end
    return remote_deploy_root(local_repo)
end
