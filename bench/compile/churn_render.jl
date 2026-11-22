#!/usr/bin/env julia
# Source churn report for bench-data.
#
#   julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl \
#       --out-dir /path/churn --append-readme /path/README.md

include(joinpath(@__DIR__, "churn_compute.jl"))
using .ChurnCompute
include(joinpath(@__DIR__, "churn_report.jl"))
include(joinpath(@__DIR__, "churn_charts.jl"))

function arg_value(flag::String)::String
    i = findfirst(==(flag), ARGS)
    i === nothing && error("missing $flag")
    i < length(ARGS) || error("missing value for $flag")
    return ARGS[i + 1]
end

function optional_arg(flag::AbstractString)::Union{Nothing, String}
    i = findfirst(==(flag), ARGS)
    i === nothing && return nothing
    i < length(ARGS) || error("missing value for $flag")
    return ARGS[i + 1]
end

function splice_churn_section(readme_path::AbstractString, section::AbstractString)
    isfile(readme_path) || return open(io -> write(io, section), readme_path, "w")
    text = read(readme_path, String)
    start_m = match(r"\n## Source churn\n", text)
    if start_m === nothing
        open(readme_path, "w") do io
            print(io, text)
            endswith(text, "\n") || println(io)
            println(io)
            write(io, section)
        end
        return nothing
    end
    start_i = last(start_m.offset)
    rest = text[(start_i + length(start_m.match)):end]
    stop = findfirst("\n## ", rest[2:end])
    tail = if stop === nothing
        ""
    else
        rest[(stop + 1):end]
    end
    head = text[1:(start_i - 1)]
    open(readme_path, "w") do io
        write(io, head)
        write(io, section)
        write(io, tail)
    end
    return nothing
end

function main()
    out_dir = arg_value("--out-dir")
    readme = optional_arg("--append-readme")
    mkpath(out_dir)
    report = compute_churn()
    chart_dir = joinpath(out_dir, "charts")
    write_churn_charts(report, chart_dir)
    write_churn_csv(report, joinpath(out_dir, "summary.csv"))
    readme_root = dirname(abspath(something(readme, joinpath(out_dir, "report.md"))))
    rel_prefix = relpath(chart_dir, readme_root)
    md = render_churn_markdown(report, rel_prefix)
    open(joinpath(out_dir, "report.md"), "w") do io
        write(io, md)
    end
    if readme !== nothing
        splice_churn_section(readme, md)
    end
    println(stderr, "wrote churn report to ", out_dir)
    return nothing
end

main()
