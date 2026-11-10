# Standalone: julia --project=lib/DistSSHShip --startup-file=no -e 'using Test; include("lib/DistSSHShip/test/ship_record_read.jl")'
using Test
using TOML
using DistSSHShip

const _FAKE_SETUP_SSH = abspath(
    joinpath(@__DIR__, "..", "..", "DistSSHBase", "test", "fixtures", "fake_setup_ssh.jl"),
)

include(joinpath(@__DIR__, "..", "..", "DistSSHBase", "test", "support.jl"))

function _record_read_env(state_dir::AbstractString)
    return merge(
        _fake_setup_remote_env(state_dir),
        Dict("DISTSSH_TEST_SSH" => _FAKE_SETUP_SSH),
    )
end

function _record_tree(host::AbstractString, state_dir::AbstractString)
    slot = replace(host, r"[@:/]" => "_")
    return joinpath(state_dir, slot, "tree")
end

function _record_distssh(host::AbstractString, state_dir::AbstractString)
    dir = joinpath(_record_tree(host, state_dir), ".distssh")
    mkpath(dir)
    return dir
end

function _minimal_snapshot(project_rel::AbstractString)::DistSSHShip.Shipment
    bundle = mktempdir()
    tar_path = joinpath(bundle, "snap.tar")
    src = joinpath(bundle, "src")
    mkdir(src)
    write(joinpath(src, "Project.toml"), "name = \"App\"\n")
    write(
        joinpath(src, "Manifest.toml"),
        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
    )
    open(tar_path, "w") do io
        DistSSHShip.Tar.create(src, io)
    end
    hash = String(DistSSHShip.Tar.tree_hash(tar_path; algorithm = "git-sha1", skip_empty = true))
    return DistSSHShip.Shipment(
        bundle, tar_path, hash, filesize(tar_path), 2, src, src, project_rel, String[], String[],
    )
end

const _EXTRACT_DEST = "/stage/tree"

@testset "ship record remote read (fake SSH)" verbose = true begin
    @testset "fail-closed when test -f returns non-1 error" begin
        snap = _minimal_snapshot(".")
        try
            legacy = DistSSHShip.build_ship_record(snap; complete = true, transfer_id = "legacy")
            _with_tempdir() do state_dir
                host = "record.testfail"
                distssh = _record_distssh(host, state_dir)
                write(joinpath(distssh, "ship.toml"), sprint(TOML.print, legacy))
                write(joinpath(distssh, "shipment.toml"), sprint(TOML.print, legacy))
                env = merge(
                    _record_read_env(state_dir),
                    Dict(
                        "DISTSSH_TEST_SHIP_RECORD_TEST_FAIL" => "shipment.toml",
                        "DISTSSH_TEST_SHIP_RECORD_TEST_FAIL_CODE" => "127",
                    ),
                )
                withenv(env...) do
                    @test_throws ArgumentError DistSSHShip.read_ship_record(host, _EXTRACT_DEST)
                    @test_throws ArgumentError DistSSHShip.read_ship_record_status(
                        host, _EXTRACT_DEST,
                    )
                end
            end
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end

    @testset "fail-closed when shipment read errors but legacy is complete" begin
        snap = _minimal_snapshot(".")
        try
            legacy = DistSSHShip.build_ship_record(snap; complete = true, transfer_id = "legacy")
            _with_tempdir() do state_dir
                host = "record.readfail"
                distssh = _record_distssh(host, state_dir)
                write(joinpath(distssh, "ship.toml"), sprint(TOML.print, legacy))
                write(joinpath(distssh, "shipment.toml"), "present-but-unreadable\n")
                env = merge(
                    _record_read_env(state_dir),
                    Dict("DISTSSH_TEST_SHIP_RECORD_CAT_FAIL" => "shipment.toml"),
                )
                withenv(env...) do
                    @test_throws ArgumentError DistSSHShip.read_ship_record(host, _EXTRACT_DEST)
                    @test_throws ArgumentError DistSSHShip.read_ship_record_status(
                        host, _EXTRACT_DEST,
                    )
                end
            end
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end

    @testset "current shipment.toml present and valid" begin
        snap = _minimal_snapshot(".")
        try
            current = DistSSHShip.build_ship_record(snap; complete = true, transfer_id = "current")
            _with_tempdir() do state_dir
                host = "record.current"
                distssh = _record_distssh(host, state_dir)
                write(joinpath(distssh, "shipment.toml"), sprint(TOML.print, current))
                legacy = DistSSHShip.build_ship_record(snap; complete = true, transfer_id = "legacy")
                write(joinpath(distssh, "ship.toml"), sprint(TOML.print, legacy))
                withenv(_record_read_env(state_dir)...) do
                    rec = DistSSHShip.read_ship_record(host, _EXTRACT_DEST)
                    @test rec !== nothing
                    @test rec["transfer_id"] == "current"
                    status, _ = DistSSHShip.read_ship_record_status(host, _EXTRACT_DEST)
                    @test status == :complete
                end
            end
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end

    @testset "missing shipment.toml, legacy ship.toml present" begin
        snap = _minimal_snapshot(".")
        try
            legacy = DistSSHShip.build_ship_record(snap; complete = true, transfer_id = "legacy")
            _with_tempdir() do state_dir
                host = "record.legacyonly"
                distssh = _record_distssh(host, state_dir)
                write(joinpath(distssh, "ship.toml"), sprint(TOML.print, legacy))
                withenv(_record_read_env(state_dir)...) do
                    rec = DistSSHShip.read_ship_record(host, _EXTRACT_DEST)
                    @test rec !== nothing
                    @test rec["transfer_id"] == "legacy"
                    status, _ = DistSSHShip.read_ship_record_status(host, _EXTRACT_DEST)
                    @test status == :complete
                end
            end
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end

    @testset "invalid shipment.toml, valid legacy ship.toml" begin
        snap = _minimal_snapshot(".")
        try
            legacy = DistSSHShip.build_ship_record(snap; complete = true, transfer_id = "legacy")
            _with_tempdir() do state_dir
                host = "record.invalidnew"
                distssh = _record_distssh(host, state_dir)
                write(joinpath(distssh, "shipment.toml"), "not-a-record")
                write(joinpath(distssh, "ship.toml"), sprint(TOML.print, legacy))
                withenv(_record_read_env(state_dir)...) do
                    rec = DistSSHShip.read_ship_record(host, _EXTRACT_DEST)
                    @test rec !== nothing
                    @test rec["transfer_id"] == "legacy"
                end
            end
        finally
            rm(snap.directory; force = true, recursive = true)
        end
    end

    @testset "read path order" begin
        paths = DistSSHShip._ship_record_read_paths(_EXTRACT_DEST)
        @test paths == String[
            "/stage/tree/.distssh/shipment.toml",
            "/stage/tree/.distssh/ship.toml",
        ]
    end
end
