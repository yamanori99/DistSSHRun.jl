# File selection under one directory. `.gitignore` via GitIgnore.jl, plus the
# ship excludes `.git` and `.distsshkit` by name. The git index is not read,
# so a force-added file that `.gitignore` names is not selected.
# GitIgnore is loaded on first use, not at module import.

const _GITIGNORE_PKG = Base.PkgId(
    Base.UUID("a0010394-fc0d-43eb-a3e0-33caa976912f"),
    "GitIgnore",
)

const _PROJECTISH_NAMES = (
    "Project.toml",
    "JuliaProject.toml",
    "Manifest.toml",
    "JuliaManifest.toml",
)

const SHIP_MAX_BYTES_DEFAULT = 256 * 1024 * 1024
const SHIP_FILE_WARN_BYTES = 50 * 1024 * 1024
const SHIP_WARN_TOTAL_BYTES_DEFAULT = 100 * 1024 * 1024
const _SHIP_WARN_FILE_ENV = "DISTSSHKIT_SHIP_WARN_FILE_BYTES"
const _SHIP_WARN_TOTAL_ENV = "DISTSSHKIT_SHIP_WARN_TOTAL_BYTES"

function _gitignore_mod()
    return Base.require(_GITIGNORE_PKG)
end

function _reject_newline(rel::AbstractString)
    occursin('\n', rel) || return nothing
    throw(
        ArgumentError(
            "cannot ship a path that contains a newline ($(repr(rel))). Rename it and retry.",
        )
    )
end

function _unshippable(path::AbstractString)::Bool
    islink(path) && return false
    isdir(path) && return false
    isfile(path) && return false
    return true
end

function _projectish_name(name::AbstractString)::Bool
    name in _PROJECTISH_NAMES && return true
    if (startswith(name, "Manifest-v") || startswith(name, "JuliaManifest-v")) &&
            endswith(name, ".toml")
        return true
    end
    return false
end

"""Relative paths under `root` that `.gitignore` keeps, not yet sorted."""
function gitignore_paths(root::AbstractString)::Vector{String}
    root_c = canonical_local_path(root)
    GitIgnore = _gitignore_mod()
    matcher = Base.invokelatest(GitIgnore.IgnoreMatcher, root_c; excludes = false)
    out = String[]
    stack = String[root_c]
    while !isempty(stack)
        cur = pop!(stack)
        names = try
            readdir(cur; join = false, sort = false)
        catch
            throw(ArgumentError("ship-tree: cannot read directory $cur"))
        end
        for name in names
            name == ".git" && continue
            name == ".distsshkit" && continue
            child = joinpath(cur, name)
            rel = replace(relpath(child, root_c), '\\' => '/')
            is_dir = isdir(child) && !islink(child)
            Base.invokelatest(GitIgnore.isignored, matcher, rel, is_dir) && continue
            _reject_newline(rel)
            push!(out, rel)
            is_dir && push!(stack, child)
        end
    end
    unique!(out)
    return out
end

"""True when `rel` (relative to `root`) is ignored. A missing matcher ignores nothing."""
function path_ignored(root::AbstractString, rel::AbstractString, is_dir::Bool)::Bool
    GitIgnore = _gitignore_mod()
    matcher = Base.invokelatest(GitIgnore.IgnoreMatcher, canonical_local_path(root); excludes = false)
    shown = replace(String(rel), '\\' => '/')
    return Base.invokelatest(GitIgnore.isignored, matcher, shown, is_dir)
end

function _with_parents(rels::Vector{String})::Vector{String}
    extras = String[]
    for rel in rels
        d = dirname(rel)
        while !isempty(d) && d != "." && d != "/"
            push!(extras, d)
            d = dirname(d)
        end
    end
    return unique!(vcat(rels, extras))
end

"""
Selected paths under `root`, relative to `root`, including ancestor directories.

`omit` paths are relative to `root`. A path equal to an omit entry, or under it,
is dropped. That is how declared inputs stay out of a Run ship.
"""
function selected_paths(
        root::AbstractString;
        omit::Vector{String} = String[],
    )::Vector{String}
    root_c = canonical_local_path(root)
    rels = _with_parents(gitignore_paths(root_c))
    filter!(rel -> !_unshippable(joinpath(root_c, rel)), rels)
    if !isempty(omit)
        covered = Set(replace(String(r), '\\' => '/') for r in omit)
        filter!(rels) do rel
            rel in covered && return false
            any(c -> startswith(rel, c * "/"), covered) && return false
            return true
        end
    end
    sort!(rels)
    isempty(rels) && throw(ArgumentError("nothing to ship from $root_c"))
    return rels
end

"""
    send_paths(root; omit=String[]) -> Vector{String}

Relative paths under `root` that a ship tar for this directory contains,
sorted. Same rules as [`selected_paths`](@ref): each `.gitignore` under
`root`, ancestor directories of kept paths, `.git` and `.distsshkit`
dropped, unshippable nodes omitted. `omit` drops declared inputs
(Run passes `.distsshkit/inputs.toml` paths).
"""
send_paths(root::AbstractString; omit::Vector{String} = String[])::Vector{String} =
    selected_paths(root; omit = omit)

function warn_excluded_project_files(
        root::AbstractString,
        listed::Vector{String};
        warn::Function = print,
    )
    root_c = canonical_local_path(root)
    present = Set{String}(replace(String(rel), '\\' => '/') for rel in listed)
    hits = String[]
    stack = String[root_c]
    while !isempty(stack)
        cur = pop!(stack)
        names = try
            readdir(cur; join = false, sort = false)
        catch
            continue
        end
        for name in names
            name == ".git" && continue
            name == ".distsshkit" && continue
            child = joinpath(cur, name)
            rel = replace(relpath(child, root_c), '\\' => '/')
            if _projectish_name(name) && (isfile(child) || islink(child))
                rel in present || push!(hits, rel)
            end
            isdir(child) && !islink(child) && push!(stack, child)
        end
    end
    isempty(hits) && return nothing
    sort!(unique!(hits))
    shown = join(hits, ", ")
    noun = length(hits) == 1 ? "file is" : "files are"
    warn("Warning: $shown $noun excluded by .gitignore and will not be shipped.\n")
    return nothing
end

function _warn_limit(name::AbstractString, default::Integer)::Int
    raw = get(ENV, name, nothing)
    raw === nothing && return Int(default)
    n = tryparse(Int, strip(raw))
    if n === nothing || n < 0
        throw(ArgumentError("$name must be a non-negative integer, got $(repr(raw))"))
    end
    return n
end
