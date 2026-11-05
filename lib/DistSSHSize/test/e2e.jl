#!/usr/bin/env julia
# SSH entry for DistSSHSize. The package has no remote behavior yet.
#
#   testenv/docker-ssh/scripts/up.sh
#   DISTSSHKIT_SSH_E2E=1 julia --project=lib/DistSSHSize lib/DistSSHSize/test/e2e.jl

using Test
using DistSSHSize

if get(ENV, "DISTSSHKIT_SSH_E2E", "") != "1"
    @info "Skipping SSH E2E (set DISTSSHKIT_SSH_E2E=1 to enable)"
    exit(0)
end

@testset "DistSSHSize SSH" verbose = true begin
end
