#!/usr/bin/env julia
# Source churn report for bench-data and developer docs.
#
#   julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl \
#       --out-dir /path/churn \
#       --append-docs docs/src/source_churn.md \
#       --docs-chart-base https://raw.githubusercontent.com/ORG/REPO/bench-data/churn/charts

include(joinpath(@__DIR__, "churn_compute.jl"))
using .ChurnCompute
include(joinpath(@__DIR__, "churn_report.jl"))
include(joinpath(@__DIR__, "churn_charts.jl"))
include(joinpath(@__DIR__, "churn_charts_html.jl"))

function parse_cli_args()::Tuple{String, Union{Nothing, String}, Union{Nothing, String}}
    out_dir = nothing
    docs = nothing
    docs_chart_base = nothing
    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--out-dir"
            i < length(ARGS) || error("missing value for --out-dir")
            out_dir = ARGS[i + 1]
            i += 2
        elseif arg == "--append-docs"
            i < length(ARGS) || error("missing value for --append-docs")
            docs = ARGS[i + 1]
            i += 2
        elseif arg == "--docs-chart-base"
            i < length(ARGS) || error("missing value for --docs-chart-base")
            docs_chart_base = ARGS[i + 1]
            i += 2
        else
            error("unexpected argument: $arg")
        end
    end
    out_dir === nothing && error("missing --out-dir")
    docs !== nothing && docs_chart_base === nothing &&
        error("missing --docs-chart-base (required with --append-docs)")
    return out_dir, docs, docs_chart_base
end

function main()
    out_dir, docs, docs_chart_base = parse_cli_args()
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
    if docs !== nothing
        chart_base = something(docs_chart_base)
        docs_md = render_churn_markdown(report, chart_base; include_heading = false)
        splice_churn_generated(docs, docs_md)
    end
    println(stderr, "wrote churn report to ", out_dir)
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
