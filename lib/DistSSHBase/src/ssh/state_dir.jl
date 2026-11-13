# Local DistSSH state directory (`.distssh/`; legacy `.distsshkit/` read-only).

const LOCAL_STATE_DIR = ".distssh"
const LEGACY_LOCAL_STATE_DIR = ".distsshkit"

"""Return both state directory base names (ship/rsync exclusion, prune scans)."""
function local_state_dir_names()::NTuple{2, String}
    return (LOCAL_STATE_DIR, LEGACY_LOCAL_STATE_DIR)
end

function is_local_state_dir_name(name::AbstractString)::Bool
    n = String(name)
    return n == LOCAL_STATE_DIR || n == LEGACY_LOCAL_STATE_DIR
end

"""
    resolve_local_state_item(project, parts...) -> String

Absolute path for a state item under `project`. Prefer `.distssh` when it
exists; else legacy `.distsshkit` when it exists; otherwise the new path
(the write target).
"""
function resolve_local_state_item(
        project::AbstractString,
        parts::AbstractString...,
    )::String
    proj = canonical_local_path(project)
    new_path = joinpath(proj, LOCAL_STATE_DIR, parts...)
    ispath(new_path) && return new_path
    legacy_path = joinpath(proj, LEGACY_LOCAL_STATE_DIR, parts...)
    ispath(legacy_path) && return legacy_path
    return new_path
end

"""Absolute `.distssh` root under `project` (write target)."""
function local_state_write_root(project::AbstractString)::String
    return joinpath(canonical_local_path(project), LOCAL_STATE_DIR)
end

"""Project-relative path under `.distssh/` for new artifacts."""
function local_state_relpath(parts::AbstractString...)::String
    return joinpath(LOCAL_STATE_DIR, parts...)
end

"""
    resolve_local_state_dir_name(anchor) -> String

State directory name under `anchor` when reading: `.distssh` if present,
else `.distsshkit` if present, else `.distssh`.
"""
function resolve_local_state_dir_name(anchor::AbstractString)::String
    root = canonical_local_path(anchor)
    isdir(joinpath(root, LOCAL_STATE_DIR)) && return LOCAL_STATE_DIR
    isdir(joinpath(root, LEGACY_LOCAL_STATE_DIR)) && return LEGACY_LOCAL_STATE_DIR
    return LOCAL_STATE_DIR
end

"""
    resolve_local_state_dir(anchor[, kind]) -> String

Absolute state directory beside `anchor` (script dir or project root).
Optional `kind` is `go`, `drive`, `setup`, etc.
"""
function resolve_local_state_dir(
        anchor::AbstractString,
        kind::Union{Nothing, AbstractString, Symbol} = nothing,
    )::String
    name = resolve_local_state_dir_name(anchor)
    base = joinpath(canonical_local_path(anchor), name)
    kind === nothing && return base
    return joinpath(base, String(kind))
end

"""
    resolve_remote_state_item(remote_root, parts...) -> String

Same resolution rules as [`resolve_local_state_item`](@ref) for a known
remote project root (used when the controller can see that tree locally,
e.g. fake SSH tests).
"""
resolve_remote_state_item(
    remote_root::AbstractString,
    parts::AbstractString...,
) = resolve_local_state_item(remote_root, parts...)

"""Remote cache directory for writes (`.distssh/cache/sha256`)."""
function remote_cache_dir(remote_root::AbstractString)::String
    return joinpath(String(remote_root), local_state_relpath("cache", "sha256"))
end

"""Remote cache directory for reads (legacy fallback)."""
function resolve_remote_cache_dir(remote_root::AbstractString)::String
    return resolve_remote_state_item(remote_root, "cache", "sha256")
end
