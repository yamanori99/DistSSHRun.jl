#!/usr/bin/env julia
"""
Differential test: `DistSSHBase._shell_status` vs the Lean `shellStatus` model.

Requires `lake build` in `formal/DistSSHBase` so `shell_status_batch` exists.
"""

using Random
using Pkg

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", ".."))
const FORMAL_ROOT = joinpath(REPO_ROOT, "formal", "DistSSHBase")
const LEAN_BATCH = joinpath(FORMAL_ROOT, ".lake", "build", "bin", "shell_status_batch")

const EXIT_RANGE = -5:300
const SIGNAL_RANGE = -2:31
const NCASES = 10_000
const RNG = MersenneTwister(0xD1572355)

Pkg.activate(joinpath(REPO_ROOT, "lib", "DistSSHBase"); io = devnull)
Pkg.instantiate(; io = devnull)
using DistSSHBase

function lean_batch_status(pairs::Vector{Tuple{Int, Int}})::Vector{Int}
    ispath(LEAN_BATCH) ||
        error("missing $LEAN_BATCH — run `lake build` in formal/DistSSHBase")
    stdin = IOBuffer()
    for (ec, ts) in pairs
        println(stdin, ec, " ", ts)
    end
    seekstart(stdin)
    out = read(pipeline(`$LEAN_BATCH`; stdin = stdin), String)
    lines = split(strip(out), '\n')
    length(lines) == length(pairs) ||
        error("expected $(length(pairs)) Lean results, got $(length(lines))")
    return parse.(Int, lines)
end

function main()
    pairs = [(rand(RNG, EXIT_RANGE), rand(RNG, SIGNAL_RANGE)) for _ in 1:NCASES]
    julia_out = [DistSSHBase._shell_status(ec, ts) for (ec, ts) in pairs]
    lean_out = lean_batch_status(pairs)
    mismatches = findall(i -> julia_out[i] != lean_out[i], eachindex(pairs))
    if !isempty(mismatches)
        i = first(mismatches)
        ec, ts = pairs[i]
        error(
            "mismatch at case $i: exitcode=$ec termsignal=$ts " *
            "julia=$(julia_out[i]) lean=$(lean_out[i])",
        )
    end
    println("differential ok: $NCASES cases matched")
    return nothing
end

main()