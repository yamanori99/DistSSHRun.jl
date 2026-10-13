#!/usr/bin/env julia
# Real SSH for juliaup status and default. Not part of Pkg.test().
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSHKIT_SSH_E2E=1 julia --project=lib/DistSSHUp lib/DistSSHUp/test/e2e.jl

using Test
using DistSSHUp

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

@testset "DistSSHUp SSH" verbose = true begin
    withenv("DISTRIBUTED_SSH_OPTS" => "-F $(_ssh_config) -o RequestTTY=no") do
        ch = DistSSHUp.juliaup_channel()
        lines = DistSSHUp.juliaup_status_lines("child-1")
        @test !isempty(lines)
        switched = DistSSHUp.juliaup_default_host!("child-1", ch)
        @test switched.host == "child-1"
        @test switched.channel == ch
        again = DistSSHUp.juliaup_status_lines("child-1"; channel = ch)
        @test !isempty(again)
    end
end
