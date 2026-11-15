#!/usr/bin/env julia
# Emit one DISTSSH-REPORT/1 line for fake ssh / snapshot ssh doubles.
nonce = length(ARGS) >= 1 ? String(ARGS[1]) : ""
isempty(nonce) && exit(2)
root = normpath(joinpath(@__DIR__, "..", ".."))
try
    if !isdefined(Main, :DistSSHRun)
        using Pkg
        Pkg.activate(root)
        using DistSSHRun
    end
    println(DistSSHRun.go_handshake_report_frame(nonce))
catch e
    showerror(stderr, e)
    exit(1)
end
