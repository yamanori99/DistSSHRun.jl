#!/usr/bin/env julia
# Test double for setup `ssh HOST REMOTE_SCRIPT` (see DISTSSH_TEST_SSH).
const _FAKE_SSH_ARBITRARY_DEST = false
include(joinpath(@__DIR__, "fake_ssh_impl.jl"))
