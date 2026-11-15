#!/usr/bin/env julia
# Emit one DISTSSH-REPORT/1 line for fake ssh / snapshot ssh doubles.
nonce = length(ARGS) >= 1 ? String(ARGS[1]) : ""
isempty(nonce) && exit(2)
using Pkg
root = normpath(joinpath(@__DIR__, "..", ".."))
Pkg.activate(root)
try
    using DistSSHRun
    println(DistSSHRun.go_handshake_report_frame(nonce))
catch e
    showerror(stderr, e)
    exit(1)
end
