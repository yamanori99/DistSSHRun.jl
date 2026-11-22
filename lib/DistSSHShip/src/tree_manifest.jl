# Per-file git blob digests and read-only enforcement for shipped trees.

using SHA

const _SHIPPED_FILE_MODE_NONEXEC = 0o444
const _SHIPPED_FILE_MODE_EXEC = 0o555

"""True when the source mode has any execute bit set (`x`)."""
function source_had_execute_bit(mode::Integer)::Bool
    return (Int(mode) & 0o111) != 0
end

"""Pack/extract target mode for a regular file from its source mode before ship chmod."""
function shipped_regular_file_mode(source_mode::Integer)::UInt
    return source_had_execute_bit(source_mode) ?
        _SHIPPED_FILE_MODE_EXEC :
        _SHIPPED_FILE_MODE_NONEXEC
end

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

"""
Set shipped modes on regular files: `0555` when the source had execute bits, else `0444`.
Returns paths shipped as executable.
"""
function chmod_shipped_files_readonly!(
        stage::AbstractString,
        rels::AbstractVector{<:AbstractString},
    )::Vector{String}
    executable = String[]
    for rel in rels
        dest = joinpath(stage, split(rel, '/'; keepempty = false)...)
        isfile(dest) && !islink(dest) || continue
        src_mode = filemode(dest) & 0o777
        target = shipped_regular_file_mode(src_mode)
        chmod(dest, target)
        target == _SHIPPED_FILE_MODE_EXEC && push!(executable, String(rel))
    end
    sort!(executable)
    return executable
end

"""After extract, normalize every regular file to shipped `0444` / `0555` modes."""
function apply_shipped_tree_file_modes!(
        root::AbstractString;
        executable_rels::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    )
    exec = executable_rels === nothing ?
        nothing :
        Set(String[string(r) for r in executable_rels])
    root_abs = abspath(String(root))
    for (dir, _, files) in walkdir(root_abs)
        for name in files
            path = joinpath(dir, name)
            isfile(path) && !islink(path) || continue
            if exec !== nothing
                rel = replace(relpath(path, root_abs), '\\' => '/')
                target = rel in exec ? _SHIPPED_FILE_MODE_EXEC : _SHIPPED_FILE_MODE_NONEXEC
                chmod(path, target)
            else
                mode = filemode(path) & 0o777
                chmod(path, shipped_regular_file_mode(mode))
            end
        end
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

"""
Fail when any shipped regular file is not the expected read-only mode (`0444` or `0555`).
When `executable_rels` is provided, each path must match exactly; otherwise only
non-writable `0444`/`0555` modes are accepted.
"""
function shipped_file_mode_violations(
        root::AbstractString,
        rels::AbstractVector{<:AbstractString};
        executable_rels::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    )::Vector{String}
    exec = executable_rels === nothing ?
        nothing :
        Set(String[string(r) for r in executable_rels])
    hits = String[]
    for rel in rels
        dest = joinpath(root, split(String(rel), '/'; keepempty = false)...)
        isfile(dest) && !islink(dest) || continue
        mode = filemode(dest) & 0o777
        if exec !== nothing
            want = String(rel) in exec ? _SHIPPED_FILE_MODE_EXEC : _SHIPPED_FILE_MODE_NONEXEC
            mode == want || push!(hits, String(rel))
        else
            if (mode & 0o222) != 0
                push!(hits, String(rel))
            elseif mode != _SHIPPED_FILE_MODE_NONEXEC && mode != _SHIPPED_FILE_MODE_EXEC
                push!(hits, String(rel))
            end
        end
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
