# Markdown and CSV for the source-churn report.

function csv_cell(value)::String
    text = string(value)
    q = '"'
    needs = occursin(q, text) || occursin(r"[,\n\r]", text)
    needs || return text
    return string(q, replace(text, q => q * q), q)
end

function fmt_date(d)::String
    d === nothing && return ""
    return string(d)
end

function render_churn_markdown(report, chart_prefix::AbstractString)::String
    lines = String[
        "## Source churn",
        "",
        "Lines are non-blank `*.jl` under `src/` and `lib/*/src/`, grouped by package and area.",
        "Columns use git history through `$(report.head_sha[1:7])` as of $(report.head_date) (JST).",
        "",
        "**(root files)** lists `.jl` files sitting directly in a package `src/` directory, not in a subfolder.",
        "",
        "![30-day churn summary]($chart_prefix/churn-summary.png)",
        "",
        "![Weekly churn]($chart_prefix/churn-weekly.png)",
        "",
        "![Net churn heatmap]($chart_prefix/churn-heatmap.png)",
        "",
    ]
    current_pkg = ""
    for row in report.areas
        if row.package != current_pkg
            current_pkg = row.package
            push!(lines, "### $current_pkg")
            push!(
                lines,
                "| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |",
            )
            push!(lines, "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
        end
        net7 = row.added_7 - row.deleted_7
        net30 = row.added_30 - row.deleted_30
        area_cell = row.area
        if !isempty(row.root_files)
            area_cell = "$(row.area) ($(join(row.root_files, ", ")))"
        end
        push!(
            lines,
            "| $(area_cell) | $(row.files) | $(row.loc) | $(row.added_7) | $(row.deleted_7) | $net7 | $(row.added_30) | $(row.deleted_30) | $net30 | $(round(row.stale_pct; digits = 1)) | $(fmt_date(row.last_touch)) |",
        )
    end
    if !isempty(report.removed)
        push!(lines, "")
        push!(lines, "### Removed paths")
        push!(lines, "Paths with churn in the window but no file at HEAD.")
        push!(lines, "| package | path | +30d | −30d | last touch |")
        push!(lines, "| --- | --- | ---: | ---: | --- |")
        for row in report.removed
            push!(lines, "| $(row.package) | `$(row.path)` | $(row.added_30) | $(row.deleted_30) | $(fmt_date(row.last_touch)) |")
        end
    end
    return join(lines, "\n")
end

function write_churn_csv(report, path::AbstractString)
    open(path, "w") do io
        println(io, "package,area,files,loc,added_7,deleted_7,net_7,added_30,deleted_30,net_30,stale_pct,last_touch_jst")
        for row in report.areas
            println(
                io,
                join(
                    [
                        csv_cell(row.package),
                        csv_cell(row.area),
                        row.files,
                        row.loc,
                        row.added_7,
                        row.deleted_7,
                        row.added_7 - row.deleted_7,
                        row.added_30,
                        row.deleted_30,
                        row.added_30 - row.deleted_30,
                        round(row.stale_pct; digits = 2),
                        fmt_date(row.last_touch),
                    ],
                    ',',
                ),
            )
        end
    end
    return nothing
end
