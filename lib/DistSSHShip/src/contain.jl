# One post-extract symlink walk for `ship`, pull, and `extract_verified!`.
# The source string is evaluated locally and sent to the remote Julia so the
# two sides do not drift. It uses only Base.

const _WALK_SOURCE = """
function distsshship_assert_tree!(root, allow_external)
    allow_external && return nothing
    root = abspath(root)
    sep = Base.Filesystem.path_separator
    function under(path)
        p = abspath(path)
        p == root && return true
        return startswith(p, root * sep)
    end
    function assert_link!(path)
        rel = relpath(abspath(path), root)
        (rel == ".." || startswith(rel, ".." * sep)) &&
            throw(ArgumentError("tar extract refuses escaping symlink " * path))
        pending = rel
        hops = 0
        seen = Set{String}()
        restarted = true
        while restarted
            parts = split(pending, sep)
            current = root
            restarted = false
            for (i, part) in enumerate(parts)
                (isempty(part) || part == ".") && continue
                part == ".." && throw(ArgumentError("tar extract refuses escaping symlink " * path))
                nxt = joinpath(current, String(part))
                islink(nxt) || (current = nxt; continue)
                hops += 1
                hops > 40 && throw(ArgumentError("tar extract refuses symlink loop " * path))
                nxt in seen && throw(ArgumentError("tar extract refuses symlink loop " * path))
                push!(seen, nxt)
                target = readlink(nxt)
                resolved = isabspath(target) ? normpath(target) : normpath(joinpath(dirname(nxt), target))
                under(resolved) || throw(ArgumentError("tar extract refuses escaping symlink " * path))
                rest = String[String(later) for later in parts[(i + 1):end]]
                newrel = relpath(abspath(resolved), root)
                pending = isempty(rest) ? newrel : joinpath(newrel, rest...)
                restarted = true
                break
            end
        end
        return nothing
    end
    for (dir, dirs, files) in walkdir(root)
        for name in dirs
            path = joinpath(dir, name)
            islink(path) && assert_link!(path)
        end
        for name in files
            path = joinpath(dir, name)
            islink(path) && assert_link!(path)
        end
    end
    return nothing
end
"""

const _WALK_MOD = Ref{Module}()

function _walk_module()::Module
    isassigned(_WALK_MOD) && return _WALK_MOD[]
    m = Module(:DistSSHShipWalk)
    include_string(m, _WALK_SOURCE, "distsshship_walk.jl")
    _WALK_MOD[] = m
    return m
end

"""
Refuse a symlink whose target leaves `root`.

`allow_external_symlinks=true` keeps the pack-time `--allow-external-symlinks`
policy and does not walk. This does not `touch` files. Pull still does that
itself.
"""
function assert_extracted_tree_contained!(
        root::AbstractString;
        allow_external_symlinks::Bool = false,
    )
    mod = _walk_module()
    # Look up the binding inside the latest world. Reading it here warns on 1.12+.
    Base.invokelatest() do
        return mod.distsshship_assert_tree!(abspath(String(root)), allow_external_symlinks)
    end
    return nothing
end

"""Remote `julia -e` body: extract stdin, walk, then check `git-sha1`."""
function remote_extract_expr()::String
    return """
    using Tar
    dest = ARGS[1]
    allow = ARGS[2] == "1"
    expected = ARGS[3]
    isdir(dest) || mkdir(dest)
    Tar.extract(stdin, dest)
    $(_WALK_SOURCE)
    distsshship_assert_tree!(dest, allow)
    # `Tar.tree_hash` reads a tar, not a directory. Rebuild one so the hash
    # matches the tar `snapshot` recorded (`git-sha1` ignores mtime and order).
    buf = IOBuffer()
    Tar.create(dest, buf)
    seekstart(buf)
    got = string(Tar.tree_hash(buf; algorithm="git-sha1", skip_empty=true))
    got == expected || error("content_tree_hash mismatch: " * got * " != " * expected)
    """
end
