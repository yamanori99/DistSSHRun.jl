# lint-allow parsing and filtering (included into Main).

const KNOWN_LINT_RULES = Set{String}()
# Documented form: `# lint-allow: <rule-id> -- <reason>` alone or after code.
const LINT_ALLOW_LINE_RE = r"(?:^|\s)#\s*lint-allow:\s*([a-z0-9-]+)\s*--\s*(.+)\s*$"
# Near-miss: mentions lint-allow but is not the documented form.
const LINT_ALLOW_LOOSE_RE = r"(?:^|\s)#\s*lint-allow\b"

function register_lint_rules!(names)
    for n in names
        push!(KNOWN_LINT_RULES, String(n))
    end
    return
end

lint_rule_id_known(id::AbstractString) = id in KNOWN_LINT_RULES

function parse_lint_allow_line(line::AbstractString)
    m = match(LINT_ALLOW_LINE_RE, line)
    m === nothing && return nothing
    rule = String(m.captures[1])
    reason = strip(String(m.captures[2]))
    return (rule, reason)
end

function lint_allow_line_malformed(line::AbstractString)::Bool
    occursin(LINT_ALLOW_LOOSE_RE, line) || return false
    return parse_lint_allow_line(line) === nothing
end

function lint_allow_reason_valid(reason::AbstractString)
    r = strip(reason)
    length(r) < 20 && return false
    low = lowercase(r)
    for bad in (
            "todo",
            "fixme",
            "tbd",
            "n/a",
            "na",
            "none",
            "xxx",
            "placeholder",
            "temporary",
            "temp",
        )
        low == bad && return false
    end
    occursin(r"^\.\.\.+$", r) && return false
    return true
end

function lint_allow_line_style(line::AbstractString)
    parsed = parse_lint_allow_line(line)
    parsed === nothing && return nothing
    s = strip(line)
    startswith(s, "#") && return (:full, parsed)
    return (:inline, parsed)
end

function lint_allow_marker_valid(parsed)
    rid, reason = parsed
    lint_rule_id_known(rid) || return false
    return lint_allow_reason_valid(reason)
end

function comment_allow_markers(src::AbstractString)
    markers = Tuple{Int, Symbol, String, String}[]
    lines = split(src, '\n'; keepempty = true)
    for tok in tokenize(src)
        kind(tok) == K"Comment" || continue
        text = untokenize(tok, src)
        parsed = parse_lint_allow_line(text)
        parsed === nothing && continue
        startb = Int(first(tok.range)) + 1
        line = line_of(src, startb)
        1 <= line <= length(lines) || continue
        line_txt = lines[line]
        # Bytes of this line before the comment: code remains => inline.
        line_start = 1
        for i in 1:(line - 1)
            line_start += ncodeunits(lines[i]) + 1
        end
        prefix = startb > line_start ? src[line_start:(startb - 1)] : ""
        style = occursin(r"\S", prefix) ? :inline : :full
        rule, reason = parsed
        push!(markers, (line, style, rule, reason))
    end
    return markers
end

function lint_allow_active(src::AbstractString, line::Int, rule::AbstractString)
    for (ml, style, rid, reason) in comment_allow_markers(src)
        lint_allow_marker_valid((rid, reason)) || continue
        rid == rule || continue
        style == :inline && ml == line && return true
        style == :full && ml == line - 1 && return true
    end
    return false
end

function lint_allow_line_is_marker(line::AbstractString, rule::AbstractString)::Bool
    style = lint_allow_line_style(line)
    style === nothing && return false
    rid, _ = style[2]
    rid == rule || return false
    return lint_allow_marker_valid(style[2])
end

function comment_line_is_lint_allow(line::AbstractString)::Bool
    style = lint_allow_line_style(line)
    return style !== nothing
end

function lines_in_string_literals(src::AbstractString)
    in_str = falses(length(src) == 0 ? 1 : count(==('\n'), src) + 1)
    tree = parse_tree(src)
    function walk(node)
        k = kind(node)
        if k == K"string" || k == K"cmdstring"
            r = byte_range(node)
            a = line_of(src, Int(first(r)))
            b = line_of(src, Int(last(r)))
            for i in a:b
                1 <= i <= length(in_str) && (in_str[i] = true)
            end
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return
    end
    walk(tree)
    return in_str
end

function filter_lint_allows!(hits, root::AbstractString)
    kept = Tuple{String, Int, String}[]
    for (path, line, rule) in hits
        full = joinpath(root, path)
        isfile(full) || (push!(kept, (path, line, rule)); continue)
        src = read(full, String)
        lint_allow_active(src, line, rule) && continue
        push!(kept, (path, line, rule))
    end
    empty!(hits)
    append!(hits, kept)
    return
end

function collect_lint_allow_markers(root::AbstractString)
    out = Tuple{String, Int, String, String}[]
    for path in readlines(Cmd(`git -C $root ls-files`; ignorestatus = true))
        skipped_path(path) && continue
        endswith(path, ".jl") || endswith(path, ".sh") || continue
        full = joinpath(root, path)
        isfile(full) || continue
        src = read(full, String)
        if endswith(path, ".jl")
            for (i, _style, rule, reason) in comment_allow_markers(src)
                push!(out, (path, i, rule, reason))
            end
            continue
        end
        for (i, line) in enumerate(split(src, '\n'; keepempty = true))
            parsed = parse_lint_allow_line(line)
            parsed === nothing && continue
            rule, reason = parsed
            push!(out, (path, i, rule, reason))
        end
    end
    return out
end

function lint_unknown_or_bad_allows(root::AbstractString)
    n = 0
    for path in readlines(Cmd(`git -C $root ls-files`; ignorestatus = true))
        skipped_path(path) && continue
        endswith(path, ".jl") || endswith(path, ".sh") || continue
        full = joinpath(root, path)
        isfile(full) || continue
        src = read(full, String)
        in_str = endswith(path, ".jl") ? lines_in_string_literals(src) : falses(0)
        lines = split(src, '\n'; keepempty = true)
        for (i, line) in enumerate(lines)
            if endswith(path, ".jl") && i <= length(in_str) && in_str[i]
                continue
            end
            lint_allow_line_malformed(line) || continue
            println(
                stderr,
                "lint: $(path):$(i): lint-allow must be `# lint-allow: <rule> -- <reason>`",
            )
            n += 1
        end
    end
    for (path, line, rule, reason) in collect_lint_allow_markers(root)
        if !lint_rule_id_known(rule)
            println(stderr, "lint: $(path):$(line): lint-allow unknown rule id $(rule)")
            n += 1
            continue
        end
        if !lint_allow_reason_valid(reason)
            println(stderr, "lint: $(path):$(line): lint-allow reason too short or placeholder")
            n += 1
        end
    end
    return n
end

function lint_allow_summary_new(root::AbstractString, files::Dict{String, Vector{Hunk}})
    added = Set{Tuple{String, Int, String, String}}()
    for (path, hunks) in files
        full = joinpath(root, path)
        isfile(full) || continue
        lines = split(read(full, String), '\n'; keepempty = true)
        for i in added_lines(hunks)
            1 <= i <= length(lines) || continue
            parsed = parse_lint_allow_line(lines[i])
            parsed === nothing && continue
            rule, reason = parsed
            push!(added, (path, i, rule, reason))
        end
    end
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) && return 0
    isempty(added) && return 0
    io = open(summary, "a")
    try
        println(io, "## New lint-allow markers")
        for (path, line, rule, reason) in sort!(collect(added))
            println(io, "- `$(path):$(line)` **$(rule)** — $(reason)")
        end
    finally
        close(io)
    end
    return 0
end
