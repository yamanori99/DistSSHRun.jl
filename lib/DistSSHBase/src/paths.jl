# Local paths and the project directory a host should use.

# Path helpers

"""Absolute local path with `~` expanded (canonical form for file I/O and comparisons)."""
canonical_local_path(path::AbstractString)::String = String(abspath(expanduser(String(path))))

"""Shorten absolute paths by replacing the home directory prefix with `~`."""
short_path(path::String) = let home = expanduser("~")
    startswith(path, home) ? "~" * path[(length(home) + 1):end] : path
end

"""
Paths under `anchor` → `relpath` from `anchor` (POSIX-style separators in the result).
Otherwise fall back to `short_path` (home as `~`).
"""
function display_path(path::AbstractString, anchor::AbstractString)::String
    ap = try
        canonical_local_path(path)
    catch
        return short_path(String(path))
    end
    an = try
        canonical_local_path(anchor)
    catch
        return short_path(String(path))
    end
    ap == an && return "."
    sep = Sys.iswindows() ? '\\' : '/'
    prefix = endswith(an, string(sep)) ? String(an) : an * sep
    if startswith(ap, prefix)
        return String(relpath(ap, an))
    end
    return short_path(String(path))
end

"""Read `name = "..."` from `proj_dir/Project.toml`; return `nothing` if missing or unreadable."""
function project_package_name(proj_dir::AbstractString)::Union{Nothing, String}
    path = joinpath(proj_dir, "Project.toml")
    isfile(path) || return nothing
    try
        m = match(r"name\s*=\s*\"([^\"]+)\"", read(path, String))
        m === nothing && return nothing
        cap = m.captures[1]
        return cap isa AbstractString ? String(cap) : nothing
    catch
        return nothing
    end
end

"""
Walk upward from `start_dir` to find the directory that should be passed to
`Pkg.activate` on workers.

If the first `Project.toml` found is a vendored DistSSHKit, DistSSHQueue, or
DistSSHRun stub (`name` is one of those) and the parent directory also has a
`Project.toml`, skip it and keep walking. Scripts next to that stub then use
the application project root. The folder name does not matter.
"""
function resolve_pkg_project_dir(start_dir::AbstractString)::String
    test_dir = abspath(String(start_dir))
    fallback = dirname(test_dir)
    for _ in 1:24
        pt = joinpath(test_dir, "Project.toml")
        if isfile(pt)
            parent = dirname(test_dir)
            stub = project_package_name(test_dir)
            skip_stub = stub in ("DistSSHKit", "DistSSHQueue", "DistSSHRun") &&
                isfile(joinpath(parent, "Project.toml"))
            skip_stub || return test_dir
        end
        parent = dirname(test_dir)
        parent == test_dir && return fallback
        test_dir = parent
    end
    return fallback
end

"""
Project file Base would use for `project`, or `nothing`.

`project` is a directory or a project file. Names are `Base.project_names`
(`JuliaProject.toml`, then `Project.toml`). A directory is not searched
upward; a workspace member stays that member's file.
"""
function _located_project_file(project::AbstractString)::Union{Nothing, String}
    raw = canonical_local_path(project)
    if isfile(raw) && basename(raw) in Base.project_names
        return raw
    end
    isdir(raw) || return nothing
    located = Base.locate_project_file(raw)
    return located isa String ? String(located) : nothing
end

"""
    manifest_path(project::AbstractString) -> Union{Nothing,String}

Absolute path of the Manifest file Base would use for `project`, or
`nothing` when that lookup finds no file.

`project` is a directory or a project file (`JuliaProject.toml` or
`Project.toml`). The file is whatever `Base.project_file_manifest_path`
returns: the workspace Manifest, an explicit `manifest` entry, then the
first existing name in `Base.manifest_names` (`JuliaManifest-v*`,
`Manifest-v*`, `JuliaManifest.toml`, `Manifest.toml`).

DistSSHQueue `submit` should call this so a versioned Manifest counts as
present. A directory with no project file returns `nothing`.
"""
function manifest_path(project::AbstractString)::Union{Nothing, String}
    project_file = _located_project_file(project)
    project_file isa String || return nothing
    found = Base.project_file_manifest_path(project_file)
    found isa String || return nothing
    return canonical_local_path(found)
end

"""
Pkg environment for `project` (a directory, or a project-file path).

`project_dir` is the directory of the project file Base would use
(`--project`). `manifest` is [`manifest_path`](@ref), or `nothing` when
that lookup finds no file. `env_dir` is the directory of `manifest`, or
`project_dir` when there is no lock. That is the tree `setup --rsync` sends.

Queue: `default_queue_env` (no dedicated `~/.distsshqueue/env`) should return
`env_dir`. `stage_job_tree!` should rsync `env_dir`, and set
`DISTRIBUTED_PROJECT_ROOT` to the staged `project_dir` (relative to that
tree). Serve `--queue-env` is `env_dir`. A job's `--project` stays
`project_dir`, because `env_dir` as `--project` misses `[deps]` that exist
only on the member.
"""
function resolve_pkg_env(project::AbstractString)
    raw = canonical_local_path(project)
    project_file = _located_project_file(raw)
    project_dir = project_file isa String ? canonical_local_path(dirname(project_file)) : raw
    manifest = manifest_path(raw)
    if manifest === nothing
        return (project_dir = project_dir, env_dir = project_dir, manifest = nothing)
    end
    env_dir = canonical_local_path(dirname(manifest))
    return (project_dir = project_dir, env_dir = env_dir, manifest = manifest)
end

"""`--project` value relative to [`resolve_pkg_env`](@ref) `env_dir` (`.` when they match)."""
function julia_project_rel(env)::String
    env.project_dir == env.env_dir && return "."
    return relpath(env.project_dir, env.env_dir)
end


"""True when `path` is `root` or a file/dir under it."""
function _path_is_under(path::AbstractString, root::AbstractString)::Bool
    p = canonical_local_path(path)
    r = canonical_local_path(root)
    p == r && return true
    return startswith(p, r * Base.Filesystem.path_separator)
end

"""Like `_path_is_under` after `realpath`, so `/var` and `/private/var` match."""
function _path_under_resolved(path::AbstractString, root::AbstractString)::Bool
    _path_is_under(path, root) && return true
    p = canonical_local_path(path)
    r = canonical_local_path(root)
    (ispath(p) && ispath(r)) || return false
    return _path_is_under(canonical_local_path(realpath(p)), canonical_local_path(realpath(r)))
end
