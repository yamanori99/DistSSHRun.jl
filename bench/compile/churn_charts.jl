# PNG charts for source churn (PlotlyJS + Kaleido).

using Dates
using PlotlyJS

function area_labels(report)::Vector{String}
    return ["$(r.package) / $(r.area)" for r in report.areas]
end

function write_churn_summary_chart(report, path::AbstractString)
    labels = area_labels(report)
    added = [r.added_30 for r in report.areas]
    deleted = [-r.deleted_30 for r in report.areas]
    net = [r.added_30 - r.deleted_30 for r in report.areas]
    trace_add = bar(; x=added, y=labels, orientation="h", name="+30d", marker_color="#3b82f6")
    trace_del = bar(; x=deleted, y=labels, orientation="h", name="−30d", marker_color="#ef4444")
    trace_net = scatter(;
        x=net,
        y=labels,
        mode="markers",
        name="net",
        marker=attr(symbol="line-ns", size=10, color="#111827"),
    )
    layout = Layout(;
        title="30-day churn by area",
        xaxis=attr(title="lines"),
        yaxis=attr(autorange="reversed"),
        barmode="overlay",
        height=max(360, 18 * length(labels)),
        margin=attr(l=220),
    )
    p = Plot([trace_add, trace_del, trace_net], layout)
    savefig(p, path)
    return nothing
end

function write_churn_weekly_chart(report, path::AbstractString)
    weeks = sort(unique(union(keys(report.weekly_added), keys(report.weekly_deleted))))
    if isempty(weeks)
        weeks = [report.head_date]
    end
    labels = string.(weeks)
    pos = [get(report.weekly_added, wk, 0) for wk in weeks]
    neg = [-get(report.weekly_deleted, wk, 0) for wk in weeks]
    net = [get(report.weekly_added, wk, 0) - get(report.weekly_deleted, wk, 0) for wk in weeks]
    trace_add = bar(; x=labels, y=pos, name="+", marker_color="#3b82f6")
    trace_del = bar(; x=labels, y=neg, name="−", marker_color="#ef4444")
    trace_net = scatter(; x=labels, y=net, mode="markers+lines", name="net", line=attr(color="#111827"))
    layout = Layout(;
        title="Weekly churn (all areas)",
        barmode="relative",
        xaxis=attr(title="week start (JST)"),
        yaxis=attr(title="lines"),
        height=420,
    )
    p = Plot([trace_add, trace_del, trace_net], layout)
    savefig(p, path)
    return nothing
end

function write_churn_heatmap(report, path::AbstractString)
    weeks = sort(unique(wk for pairs in values(report.weekly_nets) for (wk, _) in pairs))
    if isempty(weeks)
        weeks = [report.head_date]
    end
    labels = area_labels(report)
    z = Vector{Vector{Float64}}()
    for row in report.areas
        key = "$(row.package)/$(row.area)"
        pairs = get(report.weekly_nets, key, Pair{Date, Int}[])
        by_week = Dict(pairs)
        push!(z, Float64[get(by_week, wk, 0) for wk in weeks])
    end
    trace = heatmap(; z=z, x=string.(weeks), y=labels, colorscale="RdBu", zmid=0)
    layout = Layout(;
        title="Weekly net churn heatmap",
        height=max(360, 16 * length(labels)),
        margin=attr(l=220),
    )
    p = Plot([trace], layout)
    savefig(p, path)
    return nothing
end

function write_churn_charts(report, out_dir::AbstractString)
    mkpath(out_dir)
    write_churn_summary_chart(report, joinpath(out_dir, "churn-summary.png"))
    write_churn_weekly_chart(report, joinpath(out_dir, "churn-weekly.png"))
    write_churn_heatmap(report, joinpath(out_dir, "churn-heatmap.png"))
    return nothing
end