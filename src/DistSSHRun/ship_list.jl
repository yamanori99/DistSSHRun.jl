# Ship send list: walk `env_dir` and apply each directory's `.gitignore`.
# GitIgnore.jl 0.1.1 (`IgnoreMatcher(; excludes=false)`). First release 2026-08.
# 2026-11-02: watch send-list surprises; the matcher may still disagree with git.
# `.git` and `.distsshkit` are dropped by name. The index is not consulted.

function _ship_gitignore_send_list(root::AbstractString)::Vector{String}
    root_c = canonical_local_path(root)
    matcher = GitIgnore.IgnoreMatcher(root_c; excludes = false)
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
            _reject_newline_send_path(rel)
            is_dir = isdir(child) && !islink(child)
            GitIgnore.isignored(matcher, rel, is_dir) && continue
            push!(out, rel)
            is_dir && push!(stack, child)
        end
    end
    unique!(out)
    isempty(out) && throw(ArgumentError("nothing to send from $root_c"))
    return out
end
