# Local path dependencies from Project.toml `[sources]` and Manifest `path`
# entries. Paths are relative to the file that declared them. The remote
# tree keeps that relative position by rooting the tar at the common ancestor
# of the project, the workspace root, and every path dependency.
#
# Transitive: each included path dependency is scanned the same way, including
# its own `[sources]` and its own manifest when it has one. A dependency whose
# directory contains the active project (a workspace member's `path = ".."`)
# is not copied as a second tree.
#
# Absolute paths are refused. They would be resolved on the remote filesystem,
# not inside the shipped tree. An ancestor of `/` or the home directory is
# refused, because that ship would have to be rooted at `$HOME` or the
# filesystem root.

function _toml_path_pairs(data)::Vector{Tuple{String, String}}
    found = Tuple{String, String}[]
    data isa AbstractDict || return found
    for (name, entry) in data
        tables = if entry isa AbstractDict
            Any[entry]
        elseif entry isa AbstractVector
            Any[t for t in entry if t isa AbstractDict]
        else
            continue
        end
        for tab in tables
            raw = get(tab, "path", nothing)
            raw isa AbstractString || continue
            s = strip(String(raw))
            isempty(s) && continue
            push!(found, (String(name), s))
        end
    end
    return found
end

function _source_path_pairs(project_file::AbstractString)::Vector{Tuple{String, String}}
    data = TOML.parsefile(String(project_file))
    sources = get(data, "sources", nothing)
    return _toml_path_pairs(sources)
end

function _manifest_path_pairs(manifest_file::AbstractString)::Vector{Tuple{String, String}}
    data = TOML.parsefile(String(manifest_file))
    if haskey(data, "manifest_format")
        return _toml_path_pairs(get(data, "deps", nothing))
    end
    return _toml_path_pairs(data)
end

function _resolve_decl(declared_file::AbstractString, raw::AbstractString)::String
    expanded = expanduser(String(raw))
    isabspath(expanded) && return canonical_local_path(expanded)
    return canonical_local_path(joinpath(dirname(String(declared_file)), expanded))
end

function _contains_dir(parent::AbstractString, child::AbstractString)::Bool
    p = canonical_local_path(parent)
    c = canonical_local_path(child)
    c == p && return true
    return startswith(c, p * Base.Filesystem.path_separator)
end

"""Common ancestor of absolute paths. `/` when they share no directory."""
function common_ancestor(paths::Vector{String})::String
    isempty(paths) && throw(ArgumentError("common_ancestor needs a path"))
    parts = [String[p for p in split(_posix(abspath(path)), '/'; keepempty = false)] for path in paths]
    n = minimum(length, parts)
    shared = String[]
    for i in 1:n
        piece = parts[1][i]
        all(row -> row[i] == piece, parts) || break
        push!(shared, piece)
    end
    isempty(shared) && return "/"
    return "/" * join(shared, "/")
end

function _anchor_is_unsafe(anchor::AbstractString)::Bool
    a = rstrip(_posix(abspath(anchor)), '/')
    a == "" && return true
    a == "/" && return true
    home = rstrip(_posix(abspath(homedir())), '/')
    return !isempty(home) && a == home
end

struct PathDep
    name::String
    raw::String
    dir::String
    declared_in::String
end

function _workspace_member_dirs(project::ShipProject)::Set{String}
    out = Set{String}()
    root = project.workspace_root
    root isa String || return out
    located = DistSSHBase._located_project_file(root)
    located isa String || return out
    isfile(located) || return out
    data = TOML.parsefile(located)
    ws = get(data, "workspace", nothing)
    ws isa AbstractDict || return out
    listed = get(ws, "projects", Any[])
    listed isa AbstractVector || return out
    for rel in listed
        rel isa AbstractString || continue
        joined = joinpath(root, String(rel))
        ispath(joined) || continue
        push!(out, canonical_local_path(realpath(joined)))
    end
    return out
end

"""
Path dependencies of `project`, transitive, not including a directory that
contains the project.

A sibling workspace member listed in the shared manifest is not a path
dependency of this ship. The workspace project file and the shared manifest
are added by the snapshot, not by walking those siblings.
"""
function path_dependencies(project::ShipProject)::Vector{PathDep}
    found = PathDep[]
    seen = Set{String}()
    members = _workspace_member_dirs(project)
    queue = Tuple{String, Union{Nothing, String}}[(project.project_file, project.manifest)]
    while !isempty(queue)
        declared, manifest = pop!(queue)
        pairs = Tuple{String, String, String}[]
        for (name, raw) in _source_path_pairs(declared)
            push!(pairs, (name, raw, String(declared)))
        end
        if manifest isa String && isfile(manifest)
            for (name, raw) in _manifest_path_pairs(manifest)
                push!(pairs, (name, raw, String(manifest)))
            end
        end
        for (name, raw, declared_file) in pairs
            if isabspath(expanduser(raw))
                throw(
                    ArgumentError(
                        "Source path $raw for $name is absolute. Workers resolve it on their own filesystem, so it would not be the staged tree.",
                    )
                )
            end
            location = _resolve_decl(declared_file, raw)
            ispath(location) || throw(
                ArgumentError(
                    "Source path $location for $name does not exist. Workers would not see this path.",
                )
            )
            isdir(location) || throw(
                ArgumentError(
                    "Source path $location for $name is not a directory. Workers would not see this path.",
                )
            )
            target = canonical_local_path(realpath(location))
            if _contains_dir(target, project.project_dir) && target != project.project_dir
                continue
            end
            target == project.project_dir && continue
            target in members && continue
            target in seen && continue
            push!(seen, target)
            push!(found, PathDep(name, raw, target, declared_file))
            located = Base.locate_project_file(target)
            located isa AbstractString || continue
            dep_abs = abspath(String(located))
            isfile(dep_abs) || continue
            dep_manifest = DistSSHBase.manifest_path(dep_abs)
            push!(queue, (dep_abs, dep_manifest isa String ? dep_manifest : nothing))
        end
    end
    return found
end

"""
Directory the tar is rooted at so every relative path dependency still
resolves. Refuses `\$HOME` and the filesystem root.
"""
function ship_anchor(project::ShipProject, deps::Vector{PathDep})::String
    paths = String[project.project_dir]
    project.workspace_root isa String && push!(paths, project.workspace_root)
    if project.manifest isa String
        push!(paths, dirname(project.manifest))
    end
    for dep in deps
        push!(paths, dep.dir)
        written = _resolve_decl(dep.declared_in, dep.raw)
        push!(paths, written)
    end
    anchor = common_ancestor(paths)
    if _anchor_is_unsafe(anchor)
        throw(
            ArgumentError(
                "path dependencies would require shipping $(anchor == "/" ? "the filesystem root" : "\$HOME") ($(repr(anchor))). " *
                    "Put the project and its path dependencies under a shared directory that is not \$HOME or /.",
            )
        )
    end
    return canonical_local_path(anchor)
end

function project_relpath(project::ShipProject, anchor::AbstractString)::String
    rel = replace(relpath(project.project_dir, canonical_local_path(anchor)), '\\' => '/')
    rel == "" && return "."
    return rel
end
