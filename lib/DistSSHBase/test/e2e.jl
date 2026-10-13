#!/usr/bin/env julia
# Real SSH for host talking only. Not part of Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSHKIT_SSH_E2E=1 julia --project=lib/DistSSHBase lib/DistSSHBase/test/e2e.jl

using Test
using DistSSHBase

if get(ENV, "DISTSSHKIT_SSH_E2E", "") != "1"
    @info "Skipping SSH E2E (set DISTSSHKIT_SSH_E2E=1 to enable)"
    exit(0)
end

const _ssh_config = abspath(
    joinpath(
        @__DIR__, "..", "..", "..", "testenv", "docker-ssh", ".generated", "ssh_config",
    )
)
isfile(_ssh_config) ||
    error("docker-ssh not ready: missing $(_ssh_config). Run testenv/docker-ssh/scripts/up.sh")

const _hosts = ("child-1", "child-2")

@testset "DistSSHBase SSH" verbose = true begin
    withenv("DISTRIBUTED_SSH_OPTS" => "-F $(_ssh_config) -o RequestTTY=no") do
        @testset "julia path" begin
            ctrl = resolve_controller_julia("auto")
            @test isabspath(ctrl)
            @test isfile(ctrl)
            ctrl_ver = DistSSHBase.parse_julia_version(read(`$ctrl --version`, String))
            @test ctrl_ver isa VersionNumber
            for host in _hosts
                found = DistSSHBase.resolve_remote_julia(host, "auto")
                @test found isa AbstractString
                found isa AbstractString || error("expected remote julia path")
                @test isabspath(found) || startswith(found, '/')
                ver = DistSSHBase.get_remote_julia_version(host, found)
                @test ver isa VersionNumber
                @test ver.major == ctrl_ver.major
                @test ver.minor == ctrl_ver.minor
            end
        end

        @testset "run_on_host exitcode" begin
            host = _hosts[1]
            ok = run_on_host(host, ["--version"])
            @test ok.exitcode == 0
            fail = run_on_host(host, ["-e", "exit(3)"])
            @test fail.exitcode == 3
        end
    end
end
