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

const CHURN_GENERATED_BEGIN = "<!-- CHURN_GENERATED_BEGIN -->"
const CHURN_GENERATED_END = "<!-- CHURN_GENERATED_END -->"

function render_churn_markdown(
        report,
        chart_prefix::AbstractString;
        include_heading::Bool = true,
    )::String
    lines = String[]
    if include_heading
        push!(lines, "## Source churn", "")
    end
    append!(
        lines,
        [
            "Lines are non-blank `*.jl` under `src/` and `lib/*/src/`, grouped by package and area.",
            "Columns use git history through `$(report.head_sha[1:7])` as of $(report.head_date) (JST).",
            "Areas list only directories that hold at least one `*.jl` directly and show any 7d or 30d added/deleted lines.",
            "",
            "**(root files)** lists `.jl` files sitting directly in a package `src/` directory, not in a subfolder.",
            "",
            "![30-day churn summary]($chart_prefix/churn-summary.png)",
            "",
            "![Weekly churn]($chart_prefix/churn-weekly.png)",
            "",
            "![Net churn heatmap]($chart_prefix/churn-heatmap.png)",
            "",
            "Interactive charts (hover for values): [summary]($chart_prefix/churn-summary.html) · [weekly]($chart_prefix/churn-weekly.html) · [heatmap]($chart_prefix/churn-heatmap.html).",
            "",
        ],
    )
    pkgs = unique(r.package for r in report.areas)
    for pkg in sort(collect(pkgs))
        pkg_rows = filter(r -> r.package == pkg, report.areas)
        push!(lines, "### $pkg")
        push!(
            lines,
            "| area | files | LOC | +7d | −7d | net7 | +30d | −30d | net30 | %≥30d old | last touch |",
        )
        push!(lines, "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
        root_files = String[]
        for row in pkg_rows
            net7 = row.added_7 - row.deleted_7
            net30 = row.added_30 - row.deleted_30
            row.area == "(root files)" && append!(root_files, row.root_files)
            push!(
                lines,
                "| $(row.area) | $(row.files) | $(row.loc) | $(row.added_7) | $(row.deleted_7) | $net7 | $(row.added_30) | $(row.deleted_30) | $net30 | $(round(row.stale_pct; digits = 1)) | $(fmt_date(row.last_touch)) |",
            )
        end
        if !isempty(root_files)
            sort!(unique!(root_files))
            push!(lines, "")
            push!(lines, "*(root files)*: $(join(root_files, ", ")).")
        end
        push!(lines, "")
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

function splice_churn_generated(docs_path::AbstractString, section::AbstractString)
    isfile(docs_path) || error("missing docs page: $docs_path")
    text = read(docs_path, String)
    b = findfirst(CHURN_GENERATED_BEGIN, text)
    b === nothing && error("missing $CHURN_GENERATED_BEGIN in $docs_path")
    e = findfirst(CHURN_GENERATED_END, text)
    e === nothing && error("missing $CHURN_GENERATED_END in $docs_path")
    first(e) < last(b) && error("churn markers out of order in $docs_path")
    head = text[begin:(first(b) - 1)]
    tail = text[(last(e) + 1):end]
    body = strip(section)
    write(
        docs_path,
        head * CHURN_GENERATED_BEGIN * "\n\n" * body * "\n\n" * CHURN_GENERATED_END * tail,
    )
    return nothing
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
