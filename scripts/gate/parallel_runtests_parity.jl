#!/usr/bin/env julia
# Fail-closed parity between `test/parallel.jl` and `test/runtests.jl` selection.
# CI runs this immediately before `test/parallel.jl`. Local `Pkg.test()` is unchanged.
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const RUNTESTS = joinpath(REPO_ROOT, "test", "runtests.jl")

using Test
using DistSSHRun
include(joinpath(REPO_ROOT, "test", "support.jl"))

function _parallel_listed_test_count()::Int
    proj = joinpath(REPO_ROOT, "test")
    script = joinpath(REPO_ROOT, "test", "parallel.jl")
    out = read(`$(Base.julia_cmd()) --project=$(proj) $(script) --list`, String)
    n = 0
    for line in split(out, '\n')
        startswith(strip(line), "- ") || continue
        n += 1
    end
    n == 0 && error("parallel --list: no tests listed")
    return n
end

function main()
    runtests_src = read(RUNTESTS, String)
    info = _runtest_assert_parallel_runtests_parity!(runtests_src)
    listed = _parallel_listed_test_count()
    listed == info.n_files ||
        error(
            "parallel --list count ($listed) != runtests selection ($(info.n_files))",
        )
    println(
        "parallel/runtests parity: ",
        info.n_files,
        " file(s), ",
        length(info.parallel_keys),
        " parallel, ",
        length(info.serial_keys),
        " serial",
    )
    return nothing
end

main()