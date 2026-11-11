#!/usr/bin/env julia
# Real SSH for verified ship and shipment.toml. Not part of Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSH_SSH_E2E=1 julia --project=lib/DistSSHShip lib/DistSSHShip/test/e2e.jl

using Random
using Test
using DistSSHShip

if get(ENV, "DISTSSH_SSH_E2E", "") != "1"
    @info "Skipping SSH E2E (set DISTSSH_SSH_E2E=1 to enable)"
    exit(0)
end

const _ssh_config = abspath(
    joinpath(
        @__DIR__, "..", "..", "..", "testenv", "docker-ssh", ".generated", "ssh_config",
    )
)
isfile(_ssh_config) ||
    error("docker-ssh not ready: missing $(_ssh_config). Run testenv/docker-ssh/scripts/up.sh")

const _host = "child-1"

function _remote_file_exists(host::AbstractString, path::AbstractString)::Bool
    pq = DistSSHBase._remote_shell_path_word(path)
    code, _ = DistSSHBase._remote_shell_status(String(host), "test -f $pq")
    return code == 0
end

function _remote_rm_rf(host::AbstractString, path::AbstractString)
    pq = DistSSHBase._remote_shell_path_word(path)
    code, err = DistSSHBase._remote_shell_status(String(host), "rm -rf $pq")
    code == 0 || error("could not remove remote $path on $host: $err")
    return nothing
end

function _project_tree!()
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"E2EShip\"\n")
    write(
        joinpath(dir, "Manifest.toml"),
        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
    )
    write(joinpath(dir, "marker.jl"), "1\n")
    return dir
end

function _shipped_project_file(receipt::DistSSHShip.ShipmentReceipt)::String
    if receipt.project_rel == "."
        return joinpath(receipt.dest, "Project.toml")
    end
    return joinpath(receipt.dest, receipt.project_rel, "Project.toml")
end

@testset "DistSSHShip SSH" verbose = true begin
    withenv("DISTRIBUTED_SSH_OPTS" => "-F $(_ssh_config) -o RequestTTY=no") do
        nonce = bytes2hex(rand(Random.bytes(4)))
        dest = "~/distssh-ship-e2e/$nonce"
        project_dir = _project_tree!()
        snap = nothing
        try
            snap = DistSSHShip.pack_tree(project_dir)
            @testset "verified ship and record" begin
                receipt = DistSSHShip.ship(snap, [_host], dest; write_record = true)
                @test receipt.ok
                @test receipt.content_tree_hash == snap.content_tree_hash
                @test _remote_file_exists(_host, _shipped_project_file(receipt))
                @test _remote_file_exists(_host, joinpath(receipt.dest, "marker.jl"))
                record_path = DistSSHShip.shipment_record_logical_path(receipt.dest)
                @test _remote_file_exists(_host, record_path)
                status, rec = DistSSHShip.verify_shipment_record(
                    _host, receipt.dest; expect_hash = snap.content_tree_hash,
                )
                @test status == :complete
                @test rec["complete"] === true
                @test rec["content_tree_hash"] == snap.content_tree_hash
            end
        finally
            snap !== nothing && rm(snap.directory; force = true, recursive = true)
            rm(project_dir; force = true, recursive = true)
            try
                _remote_rm_rf(_host, dest)
            catch e
                @warn "remote cleanup failed" exception = e dest = dest
            end
        end

        @testset "non-empty dest is refused" begin
            nonce2 = bytes2hex(rand(Random.bytes(4)))
            dest2 = "~/distssh-ship-e2e/$nonce2"
            project_dir2 = _project_tree!()
            snap2 = nothing
            try
                snap2 = DistSSHShip.pack_tree(project_dir2)
                pq = DistSSHBase._remote_shell_path_word(dest2)
                code, _ = DistSSHBase._remote_shell_status(
                    _host, "mkdir -p $pq && echo occupied > $pq/occupant.txt",
                )
                @test code == 0
                receipt = DistSSHShip.ship(snap2, [_host], dest2; write_record = true)
                @test !receipt.ok
                @test length(receipt.hosts) == 1
                @test !receipt.hosts[1].ok
                @test occursin("not empty", receipt.hosts[1].message)
            finally
                snap2 !== nothing && rm(snap2.directory; force = true, recursive = true)
                rm(project_dir2; force = true, recursive = true)
                try
                    _remote_rm_rf(_host, dest2)
                catch e
                    @warn "remote cleanup failed" exception = e dest = dest2
                end
            end
        end
    end
end
