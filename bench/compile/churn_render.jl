#!/usr/bin/env julia
# Source churn report for bench-data.
#
#   julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl \
#       --out-dir /path/churn --append-readme /path/README.md

include(joinpath(@__DIR__, "churn_compute.jl"))
using .ChurnCompute
include(joinpath(@__DIR__, "churn_report.jl"))
include(joinpath(@__DIR__, "churn_charts.jl"))
include(joinpath(@__DIR__, "churn_charts_html.jl"))

function parse_cli_args()::Tuple{String, Union{Nothing, String}}
    out_dir = nothing
    readme = nothing
    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--out-dir"
            i < length(ARGS) || error("missing value for --out-dir")
            out_dir = ARGS[i + 1]
            i += 2
        elseif arg == "--append-readme"
            i < length(ARGS) || error("missing value for --append-readme")
            readme = ARGS[i + 1]
            i += 2
        else
            error("unexpected argument: $arg")
        end
    end
    out_dir === nothing && error("missing --out-dir")
    return out_dir, readme
end

function main()
    out_dir, readme = parse_cli_args()
    mkpath(out_dir)
    report = compute_churn()
    chart_dir = joinpath(out_dir, "charts")
    write_churn_charts(report, chart_dir)
    write_churn_html_charts(report, chart_dir)
    write_churn_csv(report, joinpath(out_dir, "summary.csv"))
    report_prefix = relpath(chart_dir, abspath(out_dir))
    report_md = render_churn_markdown(report, report_prefix)
    open(joinpath(out_dir, "report.md"), "w") do io
        write(io, report_md)
    end
    if readme !== nothing
        readme_prefix = relpath(chart_dir, dirname(abspath(readme)))
        readme_md = render_churn_markdown(report, readme_prefix)
        splice_churn_section(readme, readme_md)
    end
    println(stderr, "wrote churn report to ", out_dir)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
