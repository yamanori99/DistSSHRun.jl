#!/usr/bin/env julia
# Rebuild bench-data/README.md from history/<slot>/*.toml.
#
#   julia --startup-file=no bench/compile/report.jl \
#       --history /path/history --readme /path/README.md [--summary "$GITHUB_STEP_SUMMARY"]

using TOML

function arg_value(flag::String)::String
    i = findfirst(==(flag), ARGS)
    i === nothing && error("missing $flag")
    i < length(ARGS) || error("missing value for $flag")
    return ARGS[i + 1]
end

function optional_arg(flag::String)::Union{Nothing, String}
    i = findfirst(==(flag), ARGS)
    i === nothing && return nothing
    i < length(ARGS) || error("missing value for $flag")
    return ARGS[i + 1]
end

function load_history(dir::AbstractString)::Dict{String, Vector{Dict{String, Any}}}
    groups = Dict{String, Vector{Dict{String, Any}}}()
    isdir(dir) || return groups
    for (root, _, names) in walkdir(dir)
        for name in names
            endswith(name, ".toml") || continue
            data = TOML.parsefile(joinpath(root, name))
            slot = string(get(data, "slot", "local"))
            push!(get!(groups, slot, Dict{String, Any}[]), data)
        end
    end
    for rows in values(groups)
        sort!(rows; by = row -> string(get(row, "time", "")))
    end
    return groups
end

function utc_day(row)::String
    stamp = string(get(row, "time", ""))
    return length(stamp) >= 10 ? stamp[1:10] : stamp
end

function latest_per_day(rows)::Vector{Dict{String, Any}}
    by_day = Dict{String, Dict{String, Any}}()
    for row in rows
        day = utc_day(row)
        existing = get(by_day, day, nothing)
        if existing === nothing || string(get(row, "time", "")) > string(get(existing, "time", ""))
            by_day[day] = row
        end
    end
    return [by_day[day] for day in sort(collect(keys(by_day)))]
end

function last_utc_days(rows, ndays::Int)::Vector{Dict{String, Any}}
    daily = latest_per_day(rows)
    return length(daily) <= ndays ? daily : daily[(end - ndays + 1):end]
end

function command_order()::Vector{String}
    data = TOML.parsefile(joinpath(@__DIR__, "commands.toml"))
    specs = data["command"]
    specs isa AbstractDict && (specs = [specs])
    return [string(spec["name"]) for spec in specs]
end

function csv_cell(value)::String
    text = string(value)
    q = '"'
    needs = occursin(q, text) || occursin(r"[,\n\r]", text)
    needs || return text
    return string(q, replace(text, q => q * q), q)
end

function fnum(x)::String
    x === nothing && return ""
    return string(round(Float64(x); digits = 2))
end

function inum(row, key)::String
    haskey(row, key) || return ""
    return string(Int(row[key]))
end

function command_wall(row, name::String)::Union{Nothing, Float64}
    for cmd in get(row, "commands", [])
        string(get(cmd, "name", "")) == name || continue
        return Float64(cmd["wall_sec"])
    end
    return nothing
end

function write_summary_csv(groups::Dict{String, Vector{Dict{String, Any}}}, path::AbstractString)
    names = command_order()
    header = vcat(
        ["date", "commit", "slot", "julia", "os", "arch", "full precompile s", "pkg precompile s", "using s"],
        [name * " wall s" for name in names],
    )
    lines = String[join((csv_cell(item) for item in header), ',')]
    rows = Dict{String, Any}[]
    for slot in sort(collect(keys(groups)))
        for row in groups[slot]
            push!(rows, row)
        end
    end
    sort!(rows; by = row -> string(get(row, "time", "")))
    for row in rows
        sha = string(get(row, "commit", ""))
        cells = String[
            utc_day(row),
            sha,
            string(get(row, "slot", "")),
            string(get(row, "julia", "")),
            string(get(row, "os_name", get(row, "os", ""))),
            string(get(row, "arch", "")),
            fnum(get(row, "precompile_full_sec", nothing)),
            fnum(get(row, "precompile_pkg_sec", nothing)),
            fnum(get(row, "using_sec", nothing)),
        ]
        for name in names
            wall = command_wall(row, name)
            push!(cells, wall === nothing ? "" : fnum(wall))
        end
        push!(lines, join((csv_cell(item) for item in cells), ','))
    end
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        write(io, join(lines, '\n') * '\n')
    end
    println(stderr, "wrote ", path)
    return nothing
end

function command_names(rows)::Vector{String}
    names = String[]
    for row in rows
        for cmd in get(row, "commands", [])
            name = string(get(cmd, "name", ""))
            name in names || push!(names, name)
        end
    end
    return names
end

function top_map(row, command::String)::Dict{String, Float64}
    found = Dict{String, Float64}()
    for cmd in get(row, "commands", [])
        string(get(cmd, "name", "")) == command || continue
        for item in get(cmd, "top", [])
            found[string(item["signature"])] = Float64(item["ms"])
        end
    end
    return found
end

function host_label(row)::String
    haskey(row, "os_name") || return ""
    os = string(row["os_name"])
    arch = string(get(row, "arch", ""))
    return strip(isempty(arch) ? os : os * " " * arch)
end

function flags_for(prev, cur)::Vector{String}
    out = String[]
    prev === nothing && return out
    prev_host = host_label(prev)
    cur_host = host_label(cur)
    if !isempty(prev_host) && !isempty(cur_host) && prev_host != cur_host
        push!(out, "host changed $prev_host -> $cur_host")
    end
    jprev = string(get(prev, "julia", ""))
    jcur = string(get(cur, "julia", ""))
    if !isempty(jprev) && !isempty(jcur) && jprev != jcur
        push!(out, "julia $jprev -> $jcur")
    end
    pkg_prev = Float64(prev["precompile_pkg_sec"])
    pkg_cur = Float64(cur["precompile_pkg_sec"])
    if pkg_cur >= pkg_prev * 1.5 && pkg_cur - pkg_prev >= 0.5
        push!(out, "package precompile $(fnum(pkg_prev))s -> $(fnum(pkg_cur))s")
    end
    for name in command_names([prev, cur])
        a = command_wall(prev, name)
        b = command_wall(cur, name)
        (a === nothing || b === nothing) && continue
        if b >= a * 1.5 && b - a >= 1.0
            push!(out, "$name wall $(fnum(a))s -> $(fnum(b))s")
        end
        before = top_map(prev, name)
        after = top_map(cur, name)
        for (sig, ms) in after
            ms < 200 && continue
            old = get(before, sig, nothing)
            grown = old === nothing || ms >= old * 2
            grown || continue
            short = length(sig) > 100 ? sig[1:100] * "..." : sig
            was = old === nothing ? "new" : fnum(old) * " ms"
            push!(out, "$name method $was -> $(fnum(ms)) ms: $short")
        end
    end
    return out
end

function bench_url()::String
    repo = get(ENV, "GITHUB_REPOSITORY", "yamanori99/DistSSHRun.jl")
    owner, name = split(repo, '/')
    # GitHub Pages serves this as HTML. jsDelivr serves .html as text/plain.
    return "https://$(owner).github.io/$(name)/bench.html"
end

function slot_section(slot::String, rows)::Tuple{String, Vector{String}}
    shown = last_utc_days(rows, 30)
    latest = shown[end]
    prev = length(shown) >= 2 ? shown[end - 1] : nothing
    flagged = flags_for(prev, latest)
    names = command_names(shown)
    cols = ["date", "commit", "version", "julia", "os", "arch", "src files", "code lines", "full s", "pkg s", "using s"]
    append!(cols, [name * " s" for name in names])
    header = "| " * join(cols, " | ") * " |"
    sep = "| " * join(fill("---", length(cols)), " | ") * " |"
    body = String[]
    for row in shown
        sha = string(get(row, "commit", ""))
        short = isempty(sha) ? "" : sha[1:min(7, end)]
        stamp = string(get(row, "time", ""))
        day = length(stamp) >= 10 ? stamp[1:10] : stamp
        cells = String[
            day,
            short,
            string(get(row, "version", "")),
            replace(string(get(row, "julia", "")), '|' => '/'),
            replace(string(get(row, "os_name", get(row, "os", ""))), '|' => '/'),
            replace(string(get(row, "arch", "")), '|' => '/'),
            inum(row, "src_files"),
            inum(row, "src_code_lines"),
            fnum(get(row, "precompile_full_sec", nothing)),
            fnum(get(row, "precompile_pkg_sec", nothing)),
            fnum(get(row, "using_sec", nothing)),
        ]
        for name in names
            wall = command_wall(row, name)
            push!(cells, wall === nothing ? "" : fnum(wall))
        end
        push!(body, "| " * join(cells, " | ") * " |")
    end
    opened = slot == "1.13" ? " open" : ""
    parts = String[
        "<details$opened>",
        "<summary>$slot</summary>",
        "",
        header,
        sep,
    ]
    append!(parts, body)
    append!(parts, ["", "</details>", ""])
    return (join(parts, "\n"), flagged)
end

function render(groups)::Tuple{String, Vector{String}}
    all_flags = String[]
    sections = String[]
    for slot in sort(collect(keys(groups)))
        text, flagged = slot_section(slot, groups[slot])
        push!(sections, text)
        for item in flagged
            push!(all_flags, "$slot: $item")
        end
    end
    flag_block = if isempty(all_flags)
        "No sample grew past the watch line."
    else
        join(["- " * item for item in all_flags], "\n")
    end
    readme = """
    # Compile bench

    The charts are on [bench.html]($(bench_url())).

    Precompile time, load time, CLI wall time, `src/**/*.jl` size, and the host
    (OS name, arch, CPU). `code lines` skips blank lines. Each table is the last
    30 UTC days, one row per day (latest sample that day). Full history is in
    [history/summary.csv](history/summary.csv). A row is flagged when, against the
    previous day on the same Julia slot, the host OS or arch changes, the Julia
    version changes, package precompile grows by 1.5x and 0.5s, a command wall grows
    by 1.5x and 1s, or a method of at least 200 ms is new in the top 20 or
    doubles. This does not fail CI. Each slot's table folds. The 1.13
    table starts open.

    ## Flagged

    $flag_block

    $(join(sections, "\n"))
    """
    return (readme, all_flags)
end

include(joinpath(@__DIR__, "charts.jl"))

function main()
    history = arg_value("--history")
    readme = arg_value("--readme")
    summary = optional_arg("--summary")
    groups = load_history(history)
    text, flagged = render(groups)
    open(readme, "w") do io
        write(io, text)
    end
    out_dir = dirname(abspath(readme))
    write_summary_csv(groups, joinpath(history, "summary.csv"))
    write_bench(groups, joinpath(out_dir, "bench.html"))
    if summary !== nothing
        open(summary, "a") do io
            println(io, "## Compile bench")
            if isempty(flagged)
                println(io, "No sample grew past the watch line.")
            else
                for item in flagged
                    println(io, "- ", item)
                end
            end
        end
    end
    println(stderr, "wrote ", readme)
    return nothing
end

main()
