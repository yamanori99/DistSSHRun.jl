#!/usr/bin/env julia
# Optional: compare Test Summary totals from serial runtests.jl and parallel.jl
# (jobs=1) for the same DISTSSH_TEST_GROUP. Not run in CI (doubles wall time).
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const JULIA = Base.julia_cmd()
const TEST_PROJ = joinpath(REPO_ROOT, "test")

function _run_capture(cmd::Cmd)::String
    return read(cmd, String)
end

const _ANSI = r"\e\[[0-9;]*[A-Za-z]"

function _strip_ansi(s::AbstractString)::String
    return replace(String(s), _ANSI => "")
end

function _parse_summary(output::AbstractString)
    line = nothing
    for l in split(output, '\n')
        s = _strip_ansi(strip(l))
        occursin(r"^\s*Overall\s+\|", s) || continue
        line = s
    end
    line === nothing && error("no Overall Test Summary row in output")
    rhs = strip(split(line, "|", limit = 2)[2])
    nums = parse.(Int, split(rhs))
    length(nums) < 3 &&
        error("unexpected Test Summary line: $(line)")
  return (;
        pass = nums[1],
        broken = nums[2],
        total = nums[3],
        raw = line,
    )
end

function main()
    runtests = joinpath(REPO_ROOT, "test", "runtests.jl")
    parallel = joinpath(REPO_ROOT, "test", "parallel.jl")
    serial_out = _run_capture(`$JULIA --project=$TEST_PROJ $runtests`)
    parallel_out = _run_capture(`$JULIA --project=$TEST_PROJ $parallel --jobs=1`)
    serial = _parse_summary(serial_out)
    parallel = _parse_summary(parallel_out)
    if serial.pass != parallel.pass ||
       serial.broken != parallel.broken ||
       serial.total != parallel.total
        io = IOBuffer()
        println(io, "runtests versus parallel summary mismatch:")
        println(io, "  runtests: ", serial.raw)
        println(io, "  parallel: ", parallel.raw)
        error(String(take!(io)))
    end
    println(
        "summary parity: Pass=$(serial.pass) Broken=$(serial.broken) Total=$(serial.total)",
    )
    return nothing
end

main()