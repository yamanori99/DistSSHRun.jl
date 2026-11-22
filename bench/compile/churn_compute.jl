# Churn metrics from git history. Stdlib + Dates only; load from tests without PlotlyJS.
module ChurnCompute

using Dates

export AreaRow, ChurnReport, RemovedPathRow, area_label, area_row_included, compute_churn, jst_today

const JST_OFFSET = Hour(9)
const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

struct AreaRow
    package::String
    area::String
    files::Int
    loc::Int
    added_7::Int
    deleted_7::Int
    added_30::Int
    deleted_30::Int
    stale_pct::Float64
    last_touch::Union{Date, Nothing}
    root_files::Vector{String}
end

struct RemovedPathRow
    package::String
    path::String
    added_30::Int
    deleted_30::Int
    last_touch::Union{Date, Nothing}
end

struct ChurnReport
    head_sha::String
    head_date::Date
    generated::DateTime
    areas::Vector{AreaRow}
    removed::Vector{RemovedPathRow}
    weekly_nets::Dict{String, Vector{Pair{Date, Int}}}
    weekly_added::Dict{Date, Int}
    weekly_deleted::Dict{Date, Int}
end

function jst_from_utc(t::DateTime)::DateTime
    return t + JST_OFFSET
end

function jst_today(t::DateTime = Dates.now(UTC))::Date
    return Date(jst_from_utc(t))
end

function git_read(cmd::Cmd)::String
    try
        return chomp(read(cmd, String))
    catch err
        isa(err, ProcessFailedException) || rethrow()
        error("git failed: $(err)")
    end
end

function ensure_full_history(repo::AbstractString)
    shallow = git_read(`git -C $repo rev-parse --is-shallow-repository`)
    shallow == "true" && error("shallow git history: checkout needs fetch-depth 0")
    return nothing
end

function head_commit(repo::AbstractString)::String
    return git_read(`git -C $repo rev-parse HEAD`)
end

function package_src_roots(repo::AbstractString)::Vector{Pair{String, String}}
    out = Pair{String, String}[]
    src = joinpath(repo, "src")
    isdir(src) && push!(out, "DistSSHRun" => src)
    lib = joinpath(repo, "lib")
    if isdir(lib)
        for name in sort(readdir(lib))
            pkg_src = joinpath(lib, name, "src")
            isdir(pkg_src) || continue
            push!(out, name => pkg_src)
        end
    end
    return out
end

function entry_basename(package::String)::String
    return string(package, ".jl")
end

"""Assign each `*.jl` under package src roots to package, repo-relative path, and area label."""
function collect_source_files(repo::AbstractString)::Vector{Tuple{String, String, String}}
    rows = Tuple{String, String, String}[]
    for (package, src_root) in package_src_roots(repo)
        for (root, _, names) in walkdir(src_root)
            for name in names
                endswith(name, ".jl") || continue
                abs = joinpath(root, name)
                rel = relpath(abs, repo)
                pkg_rel = relpath(abs, src_root)
                area = area_label(package, pkg_rel)
                push!(rows, (package, rel, area))
            end
        end
    end
    return rows
end

function package_src_dir(package::String)::String
    return package == "DistSSHRun" ? "src" : joinpath("lib", package, "src")
end

function area_label(package::String, pkg_rel::AbstractString)::String
    entry = entry_basename(package)
    pkg_rel == entry && return entry
    if package == "DistSSHRun" && startswith(pkg_rel, "cli/")
        return "cli/"
    end
    d = dirname(pkg_rel)
    if package == "DistSSHRun" && startswith(d, "DistSSHRun/")
        d = d[(length("DistSSHRun/") + 1):end]
    elseif package == "DistSSHRun" && startswith(pkg_rel, "DistSSHRun/")
        d = ""
    end
    if isempty(d) || d == "."
        return "(root files)"
    end
    return endswith(d, "/") ? d : string(d, "/")
end

"""Keep rows with churn in the 7d or 30d window; omit placeholder parent dirs with no direct `.jl` files."""
function area_row_included(row::AreaRow)::Bool
    return row.added_7 + row.deleted_7 + row.added_30 + row.deleted_30 > 0
end

function count_code_lines(path::AbstractString)::Int
    isfile(path) || return 0
    n = 0
    for line in eachline(path)
        isempty(strip(line)) || (n += 1)
    end
    return n
end

function parse_commit_times(repo::AbstractString, since::AbstractString)::Dict{String, DateTime}
    text = read(`git -C $repo log --since=$since --pretty=format:%H%x09%at`, String)
    out = Dict{String, DateTime}()
    for line in eachsplit(text, '\n'; keepempty = false)
        hash, secs = split(line, '\t'; limit = 2)
        out[hash] = Dates.unix2datetime(parse(Int, secs))
    end
    return out
end

"""Rename edges old=>new within a single commit (parent to child)."""
function commit_renames(repo::AbstractString, commit::AbstractString)::Dict{String, String}
    out = Dict{String, String}()
    text = read(`git -C $repo show -M --name-status --pretty=format: $commit`, String)
    for line in eachsplit(text, '\n'; keepempty = false)
        m = match(r"^R\d+\t(.+)\t(.+)$", line)
        m === nothing && continue
        out[m.captures[1]] = m.captures[2]
    end
    return out
end

function path_at_head(renames::Dict{String, String}, path::AbstractString)::String
    seen = Set{String}()
    p = String(path)
    while haskey(renames, p)
        p in seen && error("rename cycle at $path")
        push!(seen, p)
        p = renames[p]
    end
    return p
end

"""Pure rename pairs in a commit (numstat lines `-` `-` with rename summary)."""
function move_only_paths(repo::AbstractString, commit::AbstractString)::Set{String}
    text = read(`git -C $repo show -M --numstat --summary --pretty=format: $commit`, String)
    rename_old = String[]
    for line in eachsplit(text, '\n'; keepempty = false)
        m = match(r"^rename from (.+)$", line)
        m !== nothing && push!(rename_old, m.captures[1])
        m2 = match(r"^rename to (.+)$", line)
        m2 !== nothing && continue
        m3 = match(r"^-\t-\t(.+)$", line)
        if m3 !== nothing
            push!(rename_old, m3.captures[1])
        end
    end
    numstat_rename = Set{String}()
    for line in eachsplit(text, '\n'; keepempty = false)
        m = match(r"^(\d+|-)\t(\d+|-)\t(.+)$", line)
        m === nothing && continue
        path = m.captures[3]
        path === nothing && continue
        occursin(r" => ", path) && continue
        a, d = m.captures[1], m.captures[2]
        (a == "-" || d == "-") && (path in rename_old) && push!(numstat_rename, path)
    end
    return numstat_rename
end

struct NumstatLine
    commit::String
    added::Int
    deleted::Int
    path::String
end

function parse_numstat_log(repo::AbstractString, since::AbstractString)::Vector{NumstatLine}
    cmd = `git -C $repo log -M --numstat --pretty=format:--%H --since=$since`
    text = read(cmd, String)
    lines = NumstatLine[]
    commit = ""
    for line in eachsplit(text, '\n'; keepempty = false)
        if startswith(line, "--")
            commit = strip(line[3:end])
            continue
        end
        isempty(commit) && continue
        m = match(r"^(\d+|-)\t(\d+|-)\t(.+)$", line)
        m === nothing && continue
        path = m.captures[3]
        path === nothing && continue
        occursin(r" => ", path) && continue
        a_raw, d_raw = m.captures[1], m.captures[2]
        a = a_raw === nothing || a_raw == "-" ? 0 : parse(Int, a_raw)
        d = d_raw === nothing || d_raw == "-" ? 0 : parse(Int, d_raw)
        push!(lines, NumstatLine(commit, a, d, path))
    end
    return lines
end

function scoped_path(path::AbstractString)::Bool
    return (startswith(path, "src/") && endswith(path, ".jl")) ||
        occursin(r"^lib/[^/]+/src/.+\.jl$", path)
end

function package_for_path(path::AbstractString)::Union{Nothing, String}
    m = match(r"^lib/([^/]+)/src/", path)
    m !== nothing && return m.captures[1]
    startswith(path, "src/") && return "DistSSHRun"
    return nothing
end

function build_forward_renames(repo::AbstractString, commits_chrono::Vector{String})::Vector{Dict{String, String}}
    return [commit_renames(repo, c) for c in commits_chrono]
end

function map_to_head(path::AbstractString, commit_idx::Int, commits::Vector{String}, per_commit::Vector{Dict{String, String}})::String
    p = path
    for i in (commit_idx + 1):length(commits)
        for (old, new) in per_commit[i]
            p == old && (p = new)
        end
    end
    return p
end

function blame_staleness(repo::AbstractString, path::AbstractString, cutoff::Date)::Tuple{Int, Int, Union{Date, Nothing}}
    cmd = `git -C $repo blame -w --line-porcelain HEAD -- $path`
    text = try
        read(cmd, String)
    catch err
        if err isa ProcessFailedException
            error("git blame failed for $path: $(err)")
        end
        rethrow()
    end
    total = 0
    stale = 0
    last_touch = nothing
    for line in eachsplit(text, '\n'; keepempty = false)
        m = match(r"^author-time (\d+)$", line)
        m === nothing && continue
        stamp = m.captures[1]
        stamp === nothing && continue
        total += 1
        dt = Date(jst_from_utc(Dates.unix2datetime(parse(Int, stamp))))
        dt <= cutoff && (stale += 1)
        last_touch = if last_touch === nothing
            dt
        else
            max(last_touch, dt)
        end
    end
    return stale, total, last_touch
end

function compute_churn(repo::AbstractString = REPO_ROOT; now::DateTime = Dates.now(UTC))::ChurnReport
    ensure_full_history(repo)
    head = head_commit(repo)
    head_date = jst_today(now)
    since30 = head_date - Day(30)
    since7 = head_date - Day(7)
    since_git = string(since30 - Day(1))
    commit_times = parse_commit_times(repo, since_git)
    commits = sort(collect(keys(commit_times)); by = c -> commit_times[c])
    per_commit = build_forward_renames(repo, commits)
    commit_index = Dict(c => i for (i, c) in enumerate(commits))
    files = collect_source_files(repo)
    head_paths = Set(r[2] for r in files)
    area_files = Dict{Tuple{String, String}, Vector{String}}()
    for (pkg, rel, area) in files
        push!(get!(area_files, (pkg, area), String[]), rel)
    end
    # churn accumulators keyed by (package, head_path)
    add7 = Dict{String, Int}()
    del7 = Dict{String, Int}()
    add30 = Dict{String, Int}()
    del30 = Dict{String, Int}()
    removed_add30 = Dict{String, Int}()
    removed_del30 = Dict{String, Int}()
    path_last_touch = Dict{String, Date}()
    weekly = Dict{String, Dict{Date, Int}}()
    weekly_added = Dict{Date, Int}()
    weekly_deleted = Dict{Date, Int}()
    numstat = parse_numstat_log(repo, since_git)
    for row in numstat
        scoped_path(row.path) || continue
        idx = get(commit_index, row.commit, nothing)
        idx === nothing && continue
        commit_day = jst_today(commit_times[row.commit])
        move_only = move_only_paths(repo, row.commit)
        row.path in move_only && continue
        head_path = map_to_head(row.path, idx, commits, per_commit)
        touch = get(path_last_touch, head_path, nothing)
        path_last_touch[head_path] = if touch === nothing
            commit_day
        else
            max(touch, commit_day)
        end
        is_head = head_path in head_paths
        if !is_head
            key = head_path
            removed_add30[key] = get(removed_add30, key, 0) + row.added
            removed_del30[key] = get(removed_del30, key, 0) + row.deleted
            continue
        end
        add30[head_path] = get(add30, head_path, 0) + row.added
        del30[head_path] = get(del30, head_path, 0) + row.deleted
        if commit_day >= since7
            add7[head_path] = get(add7, head_path, 0) + row.added
            del7[head_path] = get(del7, head_path, 0) + row.deleted
        end
        week_start = commit_day - Day(Dates.dayofweek(commit_day) - 1)
        wk = get!(weekly, head_path, Dict{Date, Int}())
        wk[week_start] = get(wk, week_start, 0) + (row.added - row.deleted)
        weekly_added[week_start] = get(weekly_added, week_start, 0) + row.added
        weekly_deleted[week_start] = get(weekly_deleted, week_start, 0) + row.deleted
    end
    stale_cutoff = head_date - Day(30)
    area_rows = AreaRow[]
    weekly_by_area = Dict{String, Vector{Pair{Date, Int}}}()
    for ((pkg, area), paths) in sort(collect(area_files); by = x -> (x[1][1], x[1][2]))
        src_root = joinpath(repo, package_src_dir(pkg))
        paths = filter(paths) do p
            pkg_rel = relpath(joinpath(repo, p), src_root)
            return area_label(pkg, pkg_rel) == area
        end
        isempty(paths) && continue
        sort!(paths)
        loc = sum(count_code_lines(joinpath(repo, p)) for p in paths)
        a7 = sum(get(add7, p, 0) for p in paths)
        d7 = sum(get(del7, p, 0) for p in paths)
        a30 = sum(get(add30, p, 0) for p in paths)
        d30 = sum(get(del30, p, 0) for p in paths)
        stale_n = 0
        stale_d = 0
        last = nothing
        root_list = String[]
        if area == "(root files)"
            pkg_src = joinpath(repo, package_src_dir(pkg))
            for p in paths
                push!(root_list, relpath(p, pkg_src))
            end
            sort!(root_list)
        end
        for p in paths
            s, t, lt = blame_staleness(repo, p, stale_cutoff)
            stale_n += s
            stale_d += t
            last = if last === nothing
                lt
            elseif lt === nothing
                last
            else
                max(last, lt)
            end
        end
        stale_pct = stale_d == 0 ? 100.0 : 100.0 * stale_n / stale_d
        row = AreaRow(pkg, area, length(paths), loc, a7, d7, a30, d30, stale_pct, last, root_list)
        area_row_included(row) || continue
        push!(area_rows, row)
        area_key = "$pkg/$area"
        wmap = Dict{Date, Int}()
        for p in paths
            for (wk, net) in get(weekly, p, Dict{Date, Int}())
                wmap[wk] = get(wmap, wk, 0) + net
            end
        end
        weekly_by_area[area_key] = sort(collect(wmap); by = first)
    end
    pkgs = sort(unique(r.package for r in area_rows))
    ordered = AreaRow[]
    for pkg in pkgs
        group = filter(r -> r.package == pkg, area_rows)
        sort!(group; by = r -> -(r.added_30 + r.deleted_30), rev = false)
        append!(ordered, group)
    end
    area_rows = ordered
    removed_rows = RemovedPathRow[]
    for path in sort(collect(keys(removed_add30)))
        pkg = package_for_path(path)
        pkg === nothing && continue
        push!(removed_rows, RemovedPathRow(pkg, path, removed_add30[path], removed_del30[path], get(path_last_touch, path, nothing)))
    end
    return ChurnReport(
        head,
        head_date,
        jst_from_utc(now),
        area_rows,
        removed_rows,
        weekly_by_area,
        weekly_added,
        weekly_deleted,
    )
end

end # module
