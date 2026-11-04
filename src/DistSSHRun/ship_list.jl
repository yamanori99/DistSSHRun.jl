# Ship send list: walk `env_dir` and apply each directory's `.gitignore`.
# GitIgnore.jl 0.1.1 (`IgnoreMatcher(; excludes=false)`). First release 2026-08.
# 2026-11-02: watch send-list surprises; the matcher may still disagree with git.
# `.git` and `.distsshkit` are dropped by name. A nested `.git` starts a new
# matcher so parent rules do not apply inside that directory. The index is
# not consulted.
# Load GitIgnore here, not at DistSSHRun import: a worker may precompile
# DistSSHRun from LOAD_PATH without this dep (same as PrecompileTools).

const _GITIGNORE_PKG = Base.PkgId(
    Base.UUID("a0010394-fc0d-43eb-a3e0-33caa976912f"),
    "GitIgnore",
)

function _ship_gitignore_mod()
    return Base.require(_GITIGNORE_PKG)
end

function _nested_git_root(path::AbstractString)::Bool
    g = joinpath(path, ".git")
    return isdir(g) || isfile(g)
end

function _ship_gitignore_visit_dir!(
        out::Vector{String},
        stack::Vector{Tuple{String, Any, String}},
        GitIgnore,
        root_c::AbstractString,
        cur::AbstractString,
        matcher,
        match_root::AbstractString,
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
        nested = is_dir && _nested_git_root(child)
        if !nested
            from_m = replace(relpath(child, match_root), '\\' => '/')
            Base.invokelatest(GitIgnore.isignored, matcher, from_m, is_dir) && continue
        end
        _reject_newline_send_path(rel)
        push!(out, rel)
        if is_dir
            if nested
                child_m = Base.invokelatest(GitIgnore.IgnoreMatcher, child; excludes = false)
                push!(stack, (child, child_m, child))
            else
                push!(stack, (child, matcher, match_root))
            end
        end
    end
    return nothing
end

function _ship_gitignore_send_list(root::AbstractString)::Vector{String}
    root_c = canonical_local_path(root)
    GitIgnore = _ship_gitignore_mod()
    # `require` advances world age; call through `invokelatest`.
    matcher0 = Base.invokelatest(GitIgnore.IgnoreMatcher, root_c; excludes = false)
    out = String[]
    stack = Tuple{String, Any, String}[(root_c, matcher0, root_c)]
    while !isempty(stack)
        cur, matcher, match_root = pop!(stack)
        _ship_gitignore_visit_dir!(out, stack, GitIgnore, root_c, cur, matcher, match_root)
    end
    unique!(out)
    isempty(out) && throw(ArgumentError("nothing to send from $root_c"))
    return out
end
