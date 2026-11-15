# Source-byte digest for COMPONENT_ID (concatenation order in `_SRC_FILES`).

function src_component_digest(pkg_src_dir::AbstractString, files::Tuple{Vararg{AbstractString}})::String
    ctx = SHA.SHA256_CTX()
    root = String(pkg_src_dir)
    for rel in files
        path = joinpath(root, rel)
        isfile(path) || throw(ArgumentError("src digest: missing source file $(path)"))
        SHA.update!(ctx, read(path))
    end
    return SHA.bytes2hex(SHA.digest!(ctx))
end