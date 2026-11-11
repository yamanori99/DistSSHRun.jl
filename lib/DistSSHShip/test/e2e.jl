#!/usr/bin/env julia
# Real SSH for verified ship and shipment.toml. Not part of Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSH_SSH_E2E=1 julia --project=lib/DistSSHShip lib/DistSSHShip/test/e2e.jl

using Random
using Test
using DistSSHBase
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
const _REMOTE_E2E_PREFIX = "~/distssh-ship-e2e/"

const _E2E_NONCE_BYTES = 16

function _unique_e2e_dest()::String
    return string(_REMOTE_E2E_PREFIX, bytes2hex(rand(UInt8, _E2E_NONCE_BYTES)))
end

function _ensure_e2e_parent!(host::AbstractString)
    pq = DistSSHBase._remote_shell_path_word(_REMOTE_E2E_PREFIX)
    code, err = DistSSHBase._remote_shell_status(String(host), "mkdir -p $pq")
    code == 0 || error("could not create e2e parent on $host: $err")
    return nothing
end

function _assert_dest_prefix(dest::AbstractString)
    raw = strip(String(dest))
    raw == _REMOTE_E2E_PREFIX && throw(ArgumentError("refusing cleanup on e2e prefix root"))
    startswith(raw, _REMOTE_E2E_PREFIX) ||
        throw(ArgumentError("refusing cleanup outside e2e prefix: $(repr(raw))"))
    rest = raw[(ncodeunits(_REMOTE_E2E_PREFIX) + 1):end]
    isempty(rest) && throw(ArgumentError("refusing cleanup on e2e prefix root"))
    occursin("..", rest) && throw(ArgumentError("refusing cleanup when dest contains .."))
    return nothing
end

function _remote_file_exists(host::AbstractString, path::AbstractString)::Bool
    pq = DistSSHBase._remote_shell_path_word(path)
    code, _ = DistSSHBase._remote_shell_status(String(host), "test -f $pq")
    return code == 0
end

function _remote_is_executable(host::AbstractString, path::AbstractString)::Bool
    pq = DistSSHBase._remote_shell_path_word(path)
    code, _ = DistSSHBase._remote_shell_status(String(host), "test -x $pq")
    return code == 0
end

function _remote_rm_rf(host::AbstractString, path::AbstractString)
    pq = DistSSHBase._remote_shell_path_word(path)
    code, err = DistSSHBase._remote_shell_status(String(host), "rm -rf $pq")
    code == 0 || error("could not remove remote $path on $host: $err")
    return nothing
end

function _guarded_remote_rm_rf(host::AbstractString, dest::AbstractString)
    _assert_dest_prefix(dest)
    _remote_rm_rf(host, dest)
    return nothing
end

function _project_tree!(; large_bytes::Int = 0)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"E2EShip\"\n")
    write(
        joinpath(dir, "Manifest.toml"),
        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
    )
    write(joinpath(dir, "marker.jl"), "1\n")
    write(joinpath(dir, "my file.jl"), "2\n")
    write(joinpath(dir, "日本語.txt"), "unicode\n")
    write(joinpath(dir, "run.sh"), "#!/bin/sh\necho ok\n")
    chmod(joinpath(dir, "run.sh"), 0o755)
    symlink("marker.jl", joinpath(dir, "alias.jl"))
    empty_parent = joinpath(dir, "tree_parent")
    mkpath(joinpath(empty_parent, "nested"))
    write(joinpath(empty_parent, "nested", "leaf.txt"), "x\n")
    if large_bytes > 0
        bulk = Vector{UInt8}(undef, large_bytes)
        fill!(bulk, 0x41)
        write(joinpath(dir, "bulk.bin"), bulk)
    end
    return dir
end

function _shipped_project_file(receipt::DistSSHShip.ShipmentReceipt)::String
    if receipt.project_rel == "."
        return joinpath(receipt.dest, "Project.toml")
    end
    return joinpath(receipt.dest, receipt.project_rel, "Project.toml")
end

function _assert_sftp_subsystem!()
    code, out = DistSSHBase._remote_shell_status(
        _host,
        "sudo /usr/sbin/sshd -T 2>/dev/null | grep -E '^subsystem[[:space:]]+sftp '",
    )
    code == 0 && occursin("sftp", out) || error(
        "worker sshd exposes no sftp subsystem (OpenSSH scp needs it). " *
            "testenv/docker-ssh uses the ubuntu:26.04 image default sshd_config; " *
            "inspect /etc/ssh/sshd_config on the worker before changing the image.",
    )
    return nothing
end

@testset "DistSSHShip SSH" verbose = true begin
    withenv("DISTRIBUTED_SSH_OPTS" => "-F $(_ssh_config) -o RequestTTY=no") do
        @testset "OpenSSH scp prerequisites" begin
            @test_nowarn _assert_sftp_subsystem!()
        end

        _ensure_e2e_parent!(_host)

        @testset "verified ship and record" begin
            dest = _unique_e2e_dest()
            project_dir = _project_tree!(; large_bytes = 4 * 1024 * 1024)
            snap = nothing
            try
                snap = DistSSHShip.pack_tree(project_dir)
                receipt = DistSSHShip.ship(snap, [_host], dest; write_record = true)
                @test receipt.ok
                @test receipt.content_tree_hash == snap.content_tree_hash
                @test _remote_file_exists(_host, _shipped_project_file(receipt))
                @test _remote_file_exists(_host, joinpath(receipt.dest, "marker.jl"))
                @test _remote_file_exists(_host, joinpath(receipt.dest, "my file.jl"))
                @test _remote_file_exists(_host, joinpath(receipt.dest, "日本語.txt"))
                @test _remote_file_exists(_host, joinpath(receipt.dest, "bulk.bin"))
                @test _remote_is_executable(_host, joinpath(receipt.dest, "run.sh"))
                @test _remote_file_exists(_host, joinpath(receipt.dest, "alias.jl"))
                pq = DistSSHBase._remote_shell_path_word(joinpath(receipt.dest, "tree_parent"))
                code_dir, _ = DistSSHBase._remote_shell_status(_host, "test -d $pq")
                @test code_dir == 0
                record_path = DistSSHShip.shipment_record_logical_path(receipt.dest)
                @test _remote_file_exists(_host, record_path)
                status, rec = DistSSHShip.verify_shipment_record(
                    _host, receipt.dest; expect_hash = snap.content_tree_hash,
                )
                @test status == :complete
                @test rec["complete"] === true
                @test rec["content_tree_hash"] == snap.content_tree_hash

                @testset "remote tamper rejects expect_hash" begin
                    tamper = DistSSHBase._remote_shell_path_word(
                        joinpath(receipt.dest, "marker.jl"),
                    )
                    code_t, _ = DistSSHBase._remote_shell_status(
                        _host, "printf '\\n#' >> $tamper",
                    )
                    @test code_t == 0
                    record = DistSSHBase._remote_shell_path_word(
                        DistSSHShip.shipment_record_logical_path(receipt.dest),
                    )
                    wrong = repeat('0', 40)
                    old_h = snap.content_tree_hash
                    code_r, _ = DistSSHBase._remote_shell_status(
                        _host,
                        "sed -i 's/content_tree_hash = \"$old_h\"/content_tree_hash = \"$wrong\"/' $record",
                    )
                    @test code_r == 0
                    err = try
                        DistSSHShip.verify_shipment_record(
                            _host, receipt.dest; expect_hash = snap.content_tree_hash,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("content_tree_hash", err.msg)
                end
            finally
                snap !== nothing && rm(snap.directory; force = true, recursive = true)
                rm(project_dir; force = true, recursive = true)
                try
                    _guarded_remote_rm_rf(_host, dest)
                catch e
                    @warn "remote cleanup failed" exception = e dest = dest
                end
            end
        end

        @testset "non-empty dest is refused" begin
            dest = _unique_e2e_dest()
            project_dir = _project_tree!()
            snap = nothing
            try
                snap = DistSSHShip.pack_tree(project_dir)
                pq = DistSSHBase._remote_shell_path_word(dest)
                code, _ = DistSSHBase._remote_shell_status(
                    _host, "mkdir -p $pq && echo occupied > $pq/occupant.txt",
                )
                @test code == 0
                receipt = DistSSHShip.ship(snap, [_host], dest; write_record = true)
                @test !receipt.ok
                @test length(receipt.hosts) == 1
                @test !receipt.hosts[1].ok
                @test occursin("not empty", receipt.hosts[1].message)
                st, _ = DistSSHShip.read_shipment_record_status(_host, dest)
                @test st != :complete
            finally
                snap !== nothing && rm(snap.directory; force = true, recursive = true)
                rm(project_dir; force = true, recursive = true)
                try
                    _guarded_remote_rm_rf(_host, dest)
                catch e
                    @warn "remote cleanup failed" exception = e dest = dest
                end
            end
        end

        @testset "failed extract leaves no complete record" begin
            dest = _unique_e2e_dest()
            project_dir = mktempdir()
            snap = nothing
            try
                write(joinpath(project_dir, "Project.toml"), "name = \"BadSymlink\"\n")
                write(
                    joinpath(project_dir, "Manifest.toml"),
                    "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
                )
                symlink("/etc/passwd", joinpath(project_dir, "evil"))
                snap = DistSSHShip.pack_tree(project_dir; allow_external_symlinks = true)
                receipt = DistSSHShip.ship(
                    snap, [_host], dest;
                    write_record = true, allow_external_symlinks = false,
                )
                @test !receipt.ok
                st, _ = DistSSHShip.read_shipment_record_status(_host, dest)
                @test st != :complete
            finally
                snap !== nothing && rm(snap.directory; force = true, recursive = true)
                rm(project_dir; force = true, recursive = true)
                try
                    _guarded_remote_rm_rf(_host, dest)
                catch e
                    @warn "remote cleanup failed" exception = e dest = dest
                end
            end
        end
    end
end
