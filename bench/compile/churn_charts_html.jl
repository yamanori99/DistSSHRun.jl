# Interactive churn charts (stdlib only; Plotly.js from CDN).

using Dates

const CHURN_PLOTLY_CDN = "https://cdn.plot.ly/plotly-2.35.2.min.js"
const CHURN_HTML_MAX_BYTES = 200_000

function json_escape(text::AbstractString)::String
    out = IOBuffer()
    for char in text
        if char == '"'
            print(out, "\\\"")
        elseif char == '\\'
            print(out, "\\\\")
        elseif char == '\n'
            print(out, "\\n")
        elseif char == '\r'
            print(out, "\\r")
        elseif char == '<'
            print(out, "\\u003c")
        else
            print(out, char)
        end
    end
    return String(take!(out))
end

function json_encode(value)::String
    value === nothing && return "null"
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(value)
    value isa AbstractFloat && return string(value)
    if value isa AbstractString
        return "\"" * json_escape(value) * "\""
    end
    if value isa AbstractDict
        parts = String[]
        for (key, item) in value
            push!(parts, json_encode(string(key)) * ":" * json_encode(item))
        end
        return "{" * join(parts, ",") * "}"
    end
    if value isa AbstractVector
        return "[" * join((json_encode(item) for item in value), ",") * "]"
    end
    error("cannot encode $(typeof(value))")
end

function html_escape(text)::String
    return replace(
        string(text),
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
    )
end

function churn_area_labels(report)::Vector{String}
    return ["$(r.package) / $(r.area)" for r in report.areas]
end

function plotly_page(title::AbstractString, traces, layout, div_id::AbstractString)::String
    return """
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>$(html_escape(title))</title>
      <script src="$(CHURN_PLOTLY_CDN)"></script>
      </head>
      <body style="margin:0;font-family:system-ui,sans-serif;">
      <div id="$(html_escape(div_id))" style="width:100%;min-height:90vh;"></div>
      <script>
      const data = $(json_encode(traces));
      const layout = $(json_encode(layout));
    const config = {responsive: true, displayModeBar: true};
    Plotly.newPlot($(json_encode(div_id)), data, layout, config);
      </script>
      </body>
      </html>
      """
end

function summary_html_traces(report)
    labels = churn_area_labels(report)
    added = [r.added_30 for r in report.areas]
    deleted = [r.deleted_30 for r in report.areas]
    net = [r.added_30 - r.deleted_30 for r in report.areas]
    neg = [-d for d in deleted]
    traces = [
        Dict(
            "type" => "bar",
            "orientation" => "h",
            "x" => added,
            "y" => labels,
            "name" => "+30d",
            "marker" => Dict("color" => "#3b82f6"),
            "hovertemplate" => "%{y}<br>+30d: %{x} lines<extra></extra>",
        ),
        Dict(
            "type" => "bar",
            "orientation" => "h",
            "x" => neg,
            "y" => labels,
            "name" => "−30d",
            "marker" => Dict("color" => "#ef4444"),
            "hovertemplate" => "%{y}<br>−30d: %{customdata} lines<extra></extra>",
            "customdata" => deleted,
        ),
        Dict(
            "type" => "scatter",
            "mode" => "markers",
            "x" => net,
            "y" => labels,
            "name" => "net",
            "marker" => Dict("symbol" => "diamond", "size" => 8, "color" => "#111827", "line" => Dict("width" => 1, "color" => "#ffffff")),
            "hovertemplate" => "%{y}<br>net: %{x} lines<extra></extra>",
        ),
    ]
    layout = Dict(
        "title" => Dict("text" => "30-day churn by area"),
        "xaxis" => Dict("title" => "lines"),
        "yaxis" => Dict("autorange" => "reversed"),
        "barmode" => "overlay",
        "height" => max(360, 18 * length(labels)),
        "margin" => Dict("l" => 220),
    )
    return traces, layout
end

function weekly_html_traces(report)
    weeks = sort(unique(union(keys(report.weekly_added), keys(report.weekly_deleted))))
    if isempty(weeks)
        weeks = [report.head_date]
    end
    labels = string.(weeks)
    pos = [get(report.weekly_added, wk, 0) for wk in weeks]
    neg_del = [get(report.weekly_deleted, wk, 0) for wk in weeks]
    neg = [-d for d in neg_del]
    net = [pos[i] - neg_del[i] for i in eachindex(weeks)]
    traces = [
        Dict(
            "type" => "bar",
            "x" => labels,
            "y" => pos,
            "name" => "+",
            "marker" => Dict("color" => "#3b82f6"),
            "hovertemplate" => "week %{x}<br>added: %{y}<extra></extra>",
        ),
        Dict(
            "type" => "bar",
            "x" => labels,
            "y" => neg,
            "name" => "−",
            "marker" => Dict("color" => "#ef4444"),
            "hovertemplate" => "week %{x}<br>removed: %{customdata}<extra></extra>",
            "customdata" => neg_del,
        ),
        Dict(
            "type" => "scatter",
            "mode" => "markers+lines",
            "x" => labels,
            "y" => net,
            "name" => "net",
            "line" => Dict("color" => "#111827"),
            "hovertemplate" => "week %{x}<br>net: %{y}<extra></extra>",
        ),
    ]
    layout = Dict(
        "title" => Dict("text" => "Weekly churn (all areas)"),
        "barmode" => "relative",
        "xaxis" => Dict("title" => "week start (JST)"),
        "yaxis" => Dict("title" => "lines"),
        "height" => 420,
    )
    return traces, layout
end

function heatmap_html_traces(report)
    weeks = sort(unique(wk for pairs in values(report.weekly_nets) for (wk, _) in pairs))
    if isempty(weeks)
        weeks = [report.head_date]
    end
    labels = churn_area_labels(report)
    z = Vector{Vector{Float64}}()
    for row in report.areas
        key = "$(row.package)/$(row.area)"
        pairs = get(report.weekly_nets, key, Pair{Date, Int}[])
        by_week = Dict(pairs)
        push!(z, Float64[get(by_week, wk, 0) for wk in weeks])
    end
    traces = [
        Dict(
            "type" => "heatmap",
            "z" => z,
            "x" => string.(weeks),
            "y" => labels,
            "colorscale" => "RdBu",
            "zmid" => 0,
            "hovertemplate" => "%{y}<br>week %{x}<br>net: %{z}<extra></extra>",
        ),
    ]
    layout = Dict(
        "title" => Dict("text" => "Weekly net churn heatmap"),
        "height" => max(360, 16 * length(labels)),
        "margin" => Dict("l" => 220),
    )
    return traces, layout
end

function write_churn_html_chart(traces, layout, path::AbstractString, title::AbstractString, div_id::AbstractString)
    html = plotly_page(title, traces, layout, div_id)
    length(html) > CHURN_HTML_MAX_BYTES && error("HTML too large ($(length(html)) bytes): $path")
    write(path, html)
    return nothing
end

function write_churn_html_charts(report, out_dir::AbstractString)
    mkpath(out_dir)
    s_tr, s_lo = summary_html_traces(report)
    w_tr, w_lo = weekly_html_traces(report)
    h_tr, h_lo = heatmap_html_traces(report)
    write_churn_html_chart(s_tr, s_lo, joinpath(out_dir, "churn-summary.html"), "Source churn — summary", "churn-summary")
    write_churn_html_chart(w_tr, w_lo, joinpath(out_dir, "churn-weekly.html"), "Source churn — weekly", "churn-weekly")
    write_churn_html_chart(h_tr, h_lo, joinpath(out_dir, "churn-heatmap.html"), "Source churn — heatmap", "churn-heatmap")
    return nothing
end
