#!/usr/bin/env julia
# DistSSHShip arbitrary-dest staging (Queue #362). Shared body in `fake_ssh_impl.jl`.
# `using Tar` stays in this entry point only (not `fake_setup_ssh.jl`).
const _FAKE_SSH_ARBITRARY_DEST = true
using Tar
include(joinpath(@__DIR__, "fake_ssh_impl.jl"))
