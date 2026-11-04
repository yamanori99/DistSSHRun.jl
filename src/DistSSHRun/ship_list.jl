# Ship send list: walk the ship root and apply each directory's `.gitignore`.
# GitIgnore.jl 0.1.1 (`IgnoreMatcher(; excludes=false)`). First release 2026-08.
# Rules above the ship root are not read. `.git/info/exclude` is not read.
# `.git` and `.distsshkit` are dropped by name. The index is not consulted.
# Load GitIgnore here, not at DistSSHRun import: a worker may precompile
# DistSSHRun from LOAD_PATH without this dep (same as PrecompileTools).

const _GITIGNORE_PKG = Base.PkgId(
    Base.UUID("a0010394-fc0d-43eb-a3e0-33caa976912f"),
    "GitIgnore",
)

function _ship_gitignore_mod()
    return Base.require(_GITIGNORE_PKG)
end

function _ship_gitignore_visit_dir!(
        out::Vector{String},
        stack::Vector{String},
        GitIgnore,
        root_c::AbstractString,
        cur::AbstractString,
        matcher,
    )
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
        _reject_newline_send_path(rel)
        push!(out, rel)
        is_dir && push!(stack, child)
    end
    return nothing
end

function _ship_gitignore_send_list(root::AbstractString)::Vector{String}
    root_c = canonical_local_path(root)
    GitIgnore = _ship_gitignore_mod()
    # `require` advances world age; call through `invokelatest`.
    matcher0 = Base.invokelatest(GitIgnore.IgnoreMatcher, root_c; excludes = false)
    out = String[]
    stack = String[root_c]
    while !isempty(stack)
        cur = pop!(stack)
        _ship_gitignore_visit_dir!(out, stack, GitIgnore, root_c, cur, matcher0)
    end
    unique!(out)
    isempty(out) && throw(ArgumentError("nothing to send from $root_c"))
    return out
end
