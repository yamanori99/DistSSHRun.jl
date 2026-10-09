#!/usr/bin/env julia
# DistSSHRun driver: pmap p→p² and write CSV (pair with square_echo.jl).
#
#   julia --project=. -m DistSSHRun drive parent:2 distsshkit_demos/with_kit/square_file.jl
#   julia --project=. -m DistSSHRun drive parent:2 distsshkit_demos/with_kit/square_file.jl --n 4

using Distributed
import TOML

# Direct [deps] only. DistSSHKit if the user added it, otherwise DistSSHRun.
function _demo_package()::Symbol
    proj = Base.current_project()
    proj === nothing && return :DistSSHRun
    raw = TOML.parsefile(proj)
    deps = get(raw, "deps", nothing)
    deps isa AbstractDict && haskey(deps, "DistSSHKit") && return :DistSSHKit
    return :DistSSHRun
end

const _DEMO_PACKAGE = _demo_package()
@eval using $_DEMO_PACKAGE

function init_output_dir!(_)
    pkg = getfield(Main, _DEMO_PACKAGE)
    return pkg.resolve_distributed_output_dir!(ARGS, joinpath(@__DIR__, "output"))
end

function main()
    n = 8
    if !isempty(ARGS)
        length(ARGS) == 2 && ARGS[1] == "--n" ||
            error("pass --n N (a bare number looks like parent:N)")
        n = parse(Int, ARGS[2])
    end
    results = pmap(p -> p^2, 1:n)

    out_path = joinpath(ENV["DISTRIBUTED_OUTPUT_DIR"], "square_results.csv")
    text = "param,result\n"
    for i in 1:n
        text *= "$i,$(results[i])\n"
    end
    write(out_path, text)
    return println("wrote ", out_path)
end
