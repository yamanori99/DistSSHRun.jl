#!/usr/bin/env julia
"""
Differential test: `DistSSHBase` vs the Lean model (julia-in-lean).

CI and local:
  julia --project=lib/DistSSHBase formal/diff/shell_status.jl
"""

using Random
using Pkg
using Test

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", ".."))
const FORMAL_ROOT = joinpath(REPO_ROOT, "formal")
const LEAN_BATCH = joinpath(FORMAL_ROOT, ".lake", "build", "bin", "shell_status_batch")

const EXIT_RANGE = -5:300
const SIGNAL_RANGE = -2:31
const NCASES = 10_000
const PROCASES = 500
const RNG = MersenneTwister(0xD1572355)

Pkg.activate(joinpath(REPO_ROOT, "lib", "DistSSHBase"); io = devnull)
Pkg.instantiate(; io = devnull)
using DistSSHBase

function lean_batch(lines::Vector{String})::Vector{String}
    ispath(LEAN_BATCH) || error("missing $LEAN_BATCH — run `lake build` in formal/")
    stdin = IOBuffer()
    for ln in lines
        println(stdin, ln)
    end
    seekstart(stdin)
    out = read(pipeline(`$LEAN_BATCH`; stdin = stdin), String)
    return split(strip(out), '\n')
end

function julia_internal_line(ec::Int, ts::Int)::String
    return "OK $(DistSSHBase._shell_status(ec, ts))"
end

function julia_proc_line(exited::Bool, ec::Int, ts::Int)::String
    if !exited
        return "ERR argumentError shell_status: process has not exited"
    end
    return "OK $(DistSSHBase._shell_status(ec, ts))"
end

function main()
    lines = String[]
    julia_expected = String[]
    pairs = [(rand(RNG, EXIT_RANGE), rand(RNG, SIGNAL_RANGE)) for _ in 1:NCASES]
    for (ec, ts) in pairs
        push!(lines, "i $ec $ts")
        push!(julia_expected, julia_internal_line(ec, ts))
    end
    for _ in 1:PROCASES
        exited = rand(RNG, Bool)
        ec = rand(RNG, EXIT_RANGE)
        ts = rand(RNG, SIGNAL_RANGE)
        push!(lines, "p $(Int(exited)) $ec $ts")
        push!(julia_expected, julia_proc_line(exited, ec, ts))
    end

    lean_out = lean_batch(lines)
    length(lean_out) == length(julia_expected) ||
        error("expected $(length(julia_expected)) Lean lines, got $(length(lean_out))")

    mismatches = findall(i -> julia_expected[i] != lean_out[i], eachindex(lines))
    if !isempty(mismatches)
        i = first(mismatches)
        error("mismatch at line $i: julia=$(julia_expected[i]) lean=$(lean_out[i]) input=$(lines[i])")
    end

    # Live Julia error path on a running child (not representable as static fields alone).
    proc = run(ignorestatus(`sleep 60`); wait = false)
    try
        @test_throws ArgumentError("shell_status: process has not exited") DistSSHBase.shell_status(proc)
    finally
        Base.process_running(proc) && kill(proc, Base.SIGKILL)
        wait(proc)
    end

    println("differential ok: $NCASES internal + $PROCASES modeled proc lines + live not-exited")
    return nothing
end

main()
