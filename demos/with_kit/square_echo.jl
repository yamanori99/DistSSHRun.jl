#!/usr/bin/env julia
# DistSSHRun driver: pmap p→p² and print only (pair with square_file.jl).
#
#   julia --project=. -m DistSSHRun drive parent:2 distsshkit_demos/with_kit/square_echo.jl
#   julia --project=. -m DistSSHRun drive parent:2 distsshkit_demos/with_kit/square_echo.jl --n 4

using Distributed
using DistSSHRun

function init_output_dir!(_)
    return DistSSHRun.resolve_distributed_output_dir!(ARGS, joinpath(@__DIR__, "output"))
end

function main()
    n = 8
    if !isempty(ARGS)
        length(ARGS) == 2 && ARGS[1] == "--n" ||
            error("pass --n N (a bare number looks like parent:N)")
        n = parse(Int, ARGS[2])
    end
    results = pmap(p -> p^2, 1:n)
    return println("param^2: ", results)
end
