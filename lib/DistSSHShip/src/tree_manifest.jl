# Per-file git blob digests and read-only enforcement for shipped trees.

using SHA

const _SHIPPED_FILE_MODE = 0o444

"""Git SHA-1 blob digest of a regular file's contents (same as `Tar` tree hashing)."""
function git_blob_digest(path::AbstractString)::String
    p = String(path)
    isfile(p) || throw(ArgumentError("git_blob_digest: not a file: $p"))
    islink(p) && throw(ArgumentError("git_blob_digest: symlink: $p"))
    data = read(p)
    ctx = SHA.SHA1_CTX()
    SHA.update!(ctx, codeunits("blob $(length(data))\0"))
    SHA.update!(ctx, data)
    return bytes2hex(SHA.digest!(ctx))
end

"""Git SHA-1 blob digest of symlink text (link target bytes)."""
function git_link_digest(target::AbstractString)::String
    t = String(target)
    b = codeunits(t)
    ctx = SHA.SHA1_CTX()
    SHA.update!(ctx, codeunits("blob $(length(b))\0"))
    SHA.update!(ctx, b)
    return bytes2hex(SHA.digest!(ctx))
end

function _ship_node_digest(stage::AbstractString, rel::AbstractString)::String
    dest = joinpath(stage, split(rel, '/'; keepempty = false)...)
    if islink(dest)
        return git_link_digest(readlink(dest))
    elseif isfile(dest)
        return git_blob_digest(dest)
    else
        throw(ArgumentError("shipped path is not a file or symlink: $rel"))
    end
end

"""
    content_file_digests(stage, rels) -> Vector{Pair{String,String}}

Sorted `path => git-blob` rows for every file or symlink in `rels` under `stage`.
"""
function content_file_digests(
        stage::AbstractString,
        rels::AbstractVector{<:AbstractString},
    )::Vector{Pair{String, String}}
    rows = Pair{String, String}[]
    for rel in rels
        dest = joinpath(stage, split(rel, '/'; keepempty = false)...)
        isfile(dest) || islink(dest) || continue
        push!(rows, String(rel) => _ship_node_digest(stage, rel))
    end
    sort!(rows; by = first)
    return rows
end

"""Set mode `0444` on every regular file under `stage` listed in `rels` (not symlinks or dirs)."""
function chmod_shipped_files_readonly!(
        stage::AbstractString,
        rels::AbstractVector{<:AbstractString},
    )
    for rel in rels
        dest = joinpath(stage, split(rel, '/'; keepempty = false)...)
        isfile(dest) && !islink(dest) || continue
        chmod(dest, _SHIPPED_FILE_MODE)
    end
    return nothing
end

function _format_diff_paths(paths::AbstractVector{<:AbstractString})::String
    shown = String[string(p) for p in paths]
    if length(shown) <= 12
        return string(join(shown, ", "))
    end
    head = string(join(shown[1:12], ", "))
    return string(head, ", … (", length(shown), " total)")
end

"""
Compare on-disk tree `root` to `expect` digest rows. Returns differing paths.
Skips paths that are not a file or symlink.
"""
function shipped_file_digest_mismatches(
        root::AbstractString,
        expect::AbstractVector{<:Pair{<:AbstractString, <:AbstractString}},
    )::Vector{String}
    hits = String[]
    for (rel, want) in expect
        dest = joinpath(root, split(String(rel), '/'; keepempty = false)...)
        if !(isfile(dest) || islink(dest))
            push!(hits, rel)
            continue
        end
        got = _ship_node_digest(root, String(rel))
        got == String(want) || push!(hits, rel)
    end
    return hits
end

"""Fail when any shipped file is not mode `0444` (regular files only)."""
function shipped_file_mode_violations(
        root::AbstractString,
        rels::AbstractVector{<:AbstractString},
    )::Vector{String}
    hits = String[]
    for rel in rels
        dest = joinpath(root, split(String(rel), '/'; keepempty = false)...)
        isfile(dest) && !islink(dest) || continue
        mode = filemode(dest) & 0o777
        mode == _SHIPPED_FILE_MODE || push!(hits, String(rel))
    end
    return hits
end

function shipped_tree_verify_error(
        where::AbstractString,
        kind::AbstractString,
        paths::AbstractVector{<:AbstractString},
    )::String
    return string(
        "shipped tree ", kind, " on ", where, ": ",
        _format_diff_paths(paths),
    )
end
