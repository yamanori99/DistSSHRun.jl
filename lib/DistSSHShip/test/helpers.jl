using TOML
using Test
using DistSSHShip

function _tmp(f)
    dir = mktempdir()
    try
        return f(dir)
    finally
        rm(dir; force = true, recursive = true)
    end
end

function _project!(dir; name = "App", extra = "")
    write(joinpath(dir, "Project.toml"), "name = \"$name\"\n$extra")
    write(joinpath(dir, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
    return dir
end

function _extract(snapshot)
    dest = mktempdir()
    DistSSHShip.Tar.extract(snapshot.tar_path, dest)
    return dest
end

function _local_extract_verified!(
        dest::AbstractString,
        tar_path::AbstractString,
        expect_hash::AbstractString;
        allow_external_symlinks::Bool = false,
        executable_ship_rels::Union{Nothing, AbstractVector{<:AbstractString}} = nothing,
    )
    open(tar_path) do io
        DistSSHShip.Tar.extract(io, dest)
    end
    DistSSHShip.assert_extracted_tree_contained!(
        dest; allow_external_symlinks = allow_external_symlinks,
    )
    DistSSHShip.apply_shipped_tree_file_modes!(dest; executable_rels = executable_ship_rels)
    buf = IOBuffer()
    DistSSHShip.Tar.create(dest, buf)
    seekstart(buf)
    got = String(
        DistSSHShip.Tar.tree_hash(buf; algorithm = "git-sha1", skip_empty = true),
    )
    got == expect_hash ||
        throw(ArgumentError("content_tree_hash mismatch: " * got * " != " * expect_hash))
    return nothing
end

function _minimal_snapshot(project_rel::String)::DistSSHShip.Shipment
    bundle = mktempdir()
    tar_path = joinpath(bundle, "snap.tar")
    src = joinpath(bundle, "src")
    mkdir(src)
    _project!(src)
    open(tar_path, "w") do io
        DistSSHShip.Tar.create(src, io)
    end
    hash = String(DistSSHShip.Tar.tree_hash(tar_path; algorithm = "git-sha1", skip_empty = true))
    bytes = filesize(tar_path)
    files = 2
    return DistSSHShip.Shipment(
        bundle, tar_path, hash, bytes, files, src, src, project_rel,
        String[], String[], String[], Pair{String, String}[], String[],
    )
end
