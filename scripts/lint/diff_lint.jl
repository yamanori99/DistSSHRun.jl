# Diff lints. JuliaSyntax comes from `.github/runic` (a direct dependency).
# Do not Pkg.add, and do not load a copy from the running process.
#
#   julia --project=.github/runic --startup-file=no scripts/lint/diff_lint.jl <mode>
#   modes: all, banned-words, agents-md, skip-reasons, new-comments, stdlib-compat, self-test, pr-body

using Dates
using JuliaSyntax
using TOML
import Pkg
import JuliaSyntax: byte_range, numchildren, sourcetext, untokenize

const SYNTAX_VERSION = v"1.13.0"

function die(msg)
    println(stderr, "lint: ", msg)
    return exit(1)
end

function repo_root()
    root = dirname(dirname(@__DIR__))
    isfile(joinpath(root, "Project.toml")) || die("repo root not found from $(@__FILE__)")
    return root
end

function line_of(src::AbstractString, byte::Int)
    n = 1
    last = min(byte - 1, ncodeunits(src))
    for i in 1:last
        codeunit(src, i) == UInt8('\n') && (n += 1)
    end
    return n
end

function parse_tree(src::AbstractString)
    return parseall(SyntaxNode, src; version = SYNTAX_VERSION, ignore_warnings = true)
end

function doc_covers(src::AbstractString)
    ranges = UnitRange{Int}[]
    tree = parse_tree(src)
    function walk(node)
        if kind(node) == K"doc"
            for i in 1:numchildren(node)
                child = node[i]
                kind(child) == K"string" || continue
                r = byte_range(child)
                push!(ranges, Int(first(r)):Int(last(r)))
            end
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return
    end
    walk(tree)
    return ranges
end

function in_doc(ranges, b::Int)
    return any(r -> b in r, ranges)
end

function comment_tokens(src::AbstractString)
    docs = doc_covers(src)
    out = Tuple{Int, Int, String}[]
    for tok in tokenize(src)
        kind(tok) == K"Comment" || continue
        r = Int(first(tok.range)):Int(last(tok.range))
        isempty(r) && continue
        in_doc(docs, first(r)) && continue
        push!(out, (line_of(src, first(r)), line_of(src, last(r)), untokenize(tok, src)))
    end
    return out
end

function comment_body(text::AbstractString)
    s = strip(text)
    if startswith(s, "#=")
        s = chop(s; head = 2, tail = endswith(s, "=#") ? 2 : 0)
    elseif startswith(s, "#")
        s = chop(s; head = 1, tail = 0)
    end
    return strip(s)
end

struct Hunk
    oldstart::Int
    oldlen::Int
    newstart::Int
    newlen::Int
    deleted::Vector{String}
end

added_lines(h::Hunk) = h.newlen == 0 ? Set{Int}() : Set(h.newstart:(h.newstart + h.newlen - 1))

function added_lines(hunks::Vector{Hunk})
    out = Set{Int}()
    for h in hunks
        union!(out, added_lines(h))
    end
    return out
end

function register_diff_header!(files::Dict{String, Vector{Hunk}}, line::AbstractString, path::AbstractString)
    m = match(r"^diff --git a/(.+) b/\1$", line)
    if m !== nothing
        c1 = m.captures[1]
        c1 === nothing && return path
        p = String(c1)
        get!(files, p, Hunk[])
        return p
    end
    m2 = match(r"^diff --git a/(\S+) b/(\S+)$", line)
    m2 === nothing && return path
    c1, c2 = m2.captures[1], m2.captures[2]
    (c1 === nothing || c2 === nothing) && return path
    get!(files, String(c1), Hunk[])
    p = String(c2)
    get!(files, p, Hunk[])
    return p
end

function parse_diff(diff::AbstractString)
    files = Dict{String, Vector{Hunk}}()
    path = ""
    cur = nothing
    for line in eachsplit(diff, '\n')
        if startswith(line, "diff --git ")
            cur = nothing
            path = register_diff_header!(files, line, path)
            continue
        elseif startswith(line, "rename from ")
            get!(files, String(line[13:end]), Hunk[])
        elseif startswith(line, "rename to ")
            path = String(line[11:end])
            get!(files, path, Hunk[])
        elseif startswith(line, "--- a/")
            path = line[7:end]
        elseif startswith(line, "+++ b/")
            path = line[7:end]
            get!(files, path, Hunk[])
        elseif startswith(line, "+++ /dev/null")
            get!(files, path, Hunk[])
        elseif startswith(line, "@@ ")
            m = match(r"-(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))?", line)
            m === nothing && continue
            oldstart = Base.parse(Int, m.captures[1])
            oldlen = m.captures[2] === nothing ? 1 : Base.parse(Int, m.captures[2])
            newstart = Base.parse(Int, m.captures[3])
            newlen = m.captures[4] === nothing ? 1 : Base.parse(Int, m.captures[4])
            cur = Hunk(oldstart, oldlen, newstart, newlen, String[])
            push!(get!(files, path, Hunk[]), cur)
        elseif startswith(line, "-") && !startswith(line, "---") && cur !== nothing
            push!(cur.deleted, line[2:end])
        end
    end
    return files
end

function git_rev_parse(root::AbstractString, ref::AbstractString)
    obj = string(strip(ref), "^{commit}")
    return success(
        pipeline(
            `git -C $root rev-parse --verify -q $obj`;
            stdout = devnull,
            stderr = devnull,
        ),
    )
end

function resolve_git_diff_range!(root::AbstractString, range::AbstractString)
    range = strip(range)
    if isempty(range)
        return "origin/main...HEAD"
    end
    if occursin("...", range)
        parts = split(range, "...", limit = 2)
        length(parts) == 2 || throw(
            ErrorException(
                "GATE_DIFF_RANGE=$(repr(range)): expected exactly one \"...\" between base and head; " *
                    "unset GATE_DIFF_RANGE for default origin/main...HEAD, or fix the range",
            ),
        )
        base = strip(parts[1])
        head = strip(parts[2])
        !git_rev_parse(root, base) && throw(
            ErrorException(
                "GATE_DIFF_RANGE=$(repr(range)): base ref $(repr(base)) does not resolve under $(root); " *
                    "unset GATE_DIFF_RANGE for default origin/main...HEAD, or fix the base ref",
            ),
        )
        !git_rev_parse(root, head) && throw(
            ErrorException(
                "GATE_DIFF_RANGE=$(repr(range)): head ref $(repr(head)) does not resolve under $(root); " *
                    "unset GATE_DIFF_RANGE for default origin/main...HEAD, or fix the head ref",
            ),
        )
        return range
    end
    git_rev_parse(root, range) || throw(
        ErrorException(
            "GATE_DIFF_RANGE=$(repr(range)): ref does not resolve under $(root); " *
                "unset GATE_DIFF_RANGE for default origin/main...HEAD, or fix the ref",
        ),
    )
    return range
end

function resolve_git_diff_range(root::AbstractString, range::AbstractString)
    try
        return resolve_git_diff_range!(root, range)
    catch e
        if e isa ErrorException
            die(e.msg)
        end
        rethrow()
    end
end

function git_diff(root::AbstractString)
    raw = strip(get(ENV, "GATE_DIFF_RANGE", ""))
    range = resolve_git_diff_range(root, raw)
    return read(`git -C $root diff -U0 --no-color $range`, String)
end

function skipped_path(path::AbstractString)
    return startswith(path, "scripts/lint/")
end

const EXCUSE_PHRASES = let
    path = joinpath(@__DIR__, "excuse-phrases.toml")
    data = TOML.parsefile(path)
    (
        phrases = get(data, "phrases", String[]),
        word_boundary = Set(String.(get(data, "word_boundary", String[]))),
        prefix_sensitive = Set(String.(get(data, "prefix_sensitive", String[]))),
    )
end

function banned_hit(text::AbstractString)
    for word in EXCUSE_PHRASES.phrases
        word == "for now" && continue
        if word in EXCUSE_PHRASES.prefix_sensitive
            occursin(word, text) && return word
        elseif word in EXCUSE_PHRASES.word_boundary
            occursin(Regex("(?<![A-Za-z0-9_])" * word * "(?![A-Za-z0-9_])"), text) && return word
        else
            occursin(word, text) && return word
        end
    end
    if !occursin("fine for now", text) && occursin("for now", text)
        return "for now"
    end
    return nothing
end

function lint_banned(root, files)
    n = 0
    for (path, hunks) in files
        skipped_path(path) && continue
        added = added_lines(hunks)
        isempty(added) && continue
        full = joinpath(root, path)
        isfile(full) || continue
        src = read(full, String)
        if endswith(path, ".jl")
            for (a, b, text) in comment_tokens(src)
                any(in(added), a:b) || continue
                hit = banned_hit(text)
                hit === nothing && continue
                println(stderr, "lint: $(path):$(a): banned word $(hit)")
                n += 1
            end
        else
            lines = split(src, '\n'; keepempty = true)
            for i in sort!(collect(added))
                1 <= i <= length(lines) || continue
                hit = banned_hit(lines[i])
                hit === nothing && continue
                if hit in BANNED_NEW && !occursin(r"^\s*#", lines[i])
                    continue
                end
                println(stderr, "lint: $(path):$(i): banned word $(hit)")
                n += 1
            end
        end
    end
    return n
end

function ssh_builder_path(path::AbstractString)::Bool
    return replace(String(path), '\\' => '/') == "lib/DistSSHBase/src/ssh/ssh.jl"
end

function ssh_scan_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    endswith(p, ".jl") || return false
    ssh_builder_path(p) && return false
    occursin("/messages/", p) && return false
    occursin("/DistSSHBase/src/hosts/hosts.jl", p) && return false
    occursin("/core/setup/hosts.jl", p) && return false
    startswith(p, "src/") && return true
    return occursin(r"^lib/[^/]+/src/", p)
end

function ssh_argv_hit(line::AbstractString)
    occursin(r"(?i)batchmode", line) && return "BatchMode"
    occursin(r"\[\s*\"ssh\"", line) || return nothing
    occursin("_ssh_cmd", line) && return nothing
    occursin("_host_tool_cmd", line) && return nothing
    occursin("_host_tool_exe", line) && return nothing
    return "raw ssh argv"
end

const SSH_BUILDER_CALLEES = ("_ssh_cmd", "_host_tool_cmd", "_host_tool_exe")

function callee_leaf_name(head)
    if kind(head) == K"."
        numchildren(head) >= 2 || return nothing
        right = head[2]
        kind(right) == K"." && return callee_leaf_name(right)
        return sourcetext(right)
    end
    return sourcetext(head)
end

function ssh_builder_call(node)
    kind(node) == K"call" || return false
    name = callee_leaf_name(node[1])
    name === nothing && return false
    return name in SSH_BUILDER_CALLEES
end

function raw_ssh_argv_node(node)
    k = kind(node)
    if k == K"vect"
        numchildren(node) >= 1 || return false
        return sourcetext(node[1]) == "\"ssh\""
    elseif k == K"ref"
        numchildren(node) >= 2 || return false
        return sourcetext(node[2]) == "\"ssh\""
    end
    return false
end

function node_touches_added(src, node, added)
    isempty(added) && return false
    r = byte_range(node)
    a = line_of(src, Int(first(r)))
    b = line_of(src, Int(last(r)))
    for line in a:b
        line in added && return true
    end
    return false
end

function lint_ssh_argv(root, files, src_for_path)
    n = 0
    for (path, hunks) in files
        ssh_scan_path(path) || continue
        added = added_lines(hunks)
        isempty(added) && continue
        src = src_for_path(path)
        lines = split(src, '\n'; keepempty = true)
        for i in sort!(collect(added))
            1 <= i <= length(lines) || continue
            ssh_argv_hit(lines[i]) == "BatchMode" || continue
            println(stderr, "lint: $(path):$(i): BatchMode")
            n += 1
        end
        tree = parse_tree(src)
        function walk(node, in_builder)
            if in_builder
                for i in 1:numchildren(node)
                    walk(node[i], true)
                end
                return
            end
            if kind(node) == K"call" && ssh_builder_call(node)
                for i in 1:numchildren(node)
                    walk(node[i], true)
                end
                return
            end
            if raw_ssh_argv_node(node) && node_touches_added(src, node, added)
                a = line_of(src, Int(first(byte_range(node))))
                println(stderr, "lint: $(path):$(a): raw ssh argv")
                n += 1
            end
            for i in 1:numchildren(node)
                walk(node[i], false)
            end
            return
        end
        walk(tree, false)
    end
    return n
end

const DRIVE_HOOK_ACCESSORS = (
    "_drive_hook_binding", "_call_drive_script_hook", "_call_drive_script_hook_on_workers",
)

function drive_hooks_scan_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    endswith(p, ".jl") || return false
    return startswith(p, "src/DistSSHRun/core/drive/") || startswith(p, "src/DistSSHRun/drive/")
end

function defined_function_name(node)
    k = kind(node)
    (k == K"function" || k == K"=") || return nothing
    numchildren(node) >= 1 || return nothing
    sig = node[1]
    while (kind(sig) == K"where" || kind(sig) == K"::") && numchildren(sig) >= 1
        sig = sig[1]
    end
    kind(sig) == K"call" || return nothing
    return callee_leaf_name(sig[1])
end

function main_access_node(node)
    k = kind(node)
    if k == K"."
        numchildren(node) >= 2 || return false
        return sourcetext(node[1]) == "Main"
    elseif k == K"call"
        numchildren(node) >= 3 || return false
        callee_leaf_name(node[1]) in ("isdefined", "getfield") || return false
        return sourcetext(node[2]) == "Main"
    end
    return false
end

function lint_drive_hooks(root, files, src_for_path)
    n = 0
    for (path, hunks) in files
        drive_hooks_scan_path(path) || continue
        added = added_lines(hunks)
        isempty(added) && continue
        src = src_for_path(path)
        function walk(node)
            defined_function_name(node) in DRIVE_HOOK_ACCESSORS && return
            if main_access_node(node) && node_touches_added(src, node, added)
                a = line_of(src, Int(first(byte_range(node))))
                println(stderr, "lint: $(path):$(a): driver hook read from Main; use _drive_script_hooks")
                n += 1
                return
            end
            for i in 1:numchildren(node)
                walk(node[i])
            end
            return
        end
        walk(parse_tree(src))
    end
    return n
end

function workflow_job_title(lines, i::Int)
    j = i
    while j >= 1
        m = match(r"^    name:\s*(.+)\s*$", lines[j])
        m === nothing && (j -= 1; continue)
        return strip(m.captures[1], ['"', '\''])
    end
    return nothing
end

function aqua_run_hit(title, line::AbstractString)
    startswith(String(title), "Aqua (") || return nothing
    occursin(r"^\s+run:", line) || return nothing
    occursin("aqua-check.sh", line) && return nothing
    return "Aqua job run is not aqua-check.sh"
end

function lint_aqua_run(root, files)
    n = 0
    for (path, hunks) in files
        startswith(path, ".github/workflows/") && endswith(path, ".yml") || continue
        added = added_lines(hunks)
        isempty(added) && continue
        full = joinpath(root, path)
        isfile(full) || continue
        lines = split(read(full, String), '\n'; keepempty = true)
        for i in sort!(collect(added))
            1 <= i <= length(lines) || continue
            title = workflow_job_title(lines, i)
            title === nothing && continue
            hit = aqua_run_hit(title, lines[i])
            hit === nothing && continue
            println(stderr, "lint: $(path):$(i): $(hit)")
            n += 1
        end
    end
    return n
end

function public_names_in(src::AbstractString)
    names = Set{String}()
    toks = tokenize(src)
    i = 1
    while i <= length(toks)
        if kind(toks[i]) == K"public"
            i += 1
            after_comma = false
            while i <= length(toks)
                k = kind(toks[i])
                if k == K"Identifier"
                    push!(names, untokenize(toks[i], src))
                    after_comma = false
                elseif k == K","
                    after_comma = true
                elseif k == K"NewlineWs"
                    after_comma || break
                elseif k in (K"Whitespace", K"Comment")
                else
                    break
                end
                i += 1
            end
        else
            i += 1
        end
    end
    return names
end

function export_names_in(src::AbstractString)
    names = Set{String}()
    toks = tokenize(src)
    i = 1
    while i <= length(toks)
        if kind(toks[i]) == K"export"
            i += 1
            after_comma = false
            while i <= length(toks)
                k = kind(toks[i])
                if k == K"Identifier"
                    push!(names, untokenize(toks[i], src))
                    after_comma = false
                elseif k == K":"
                    after_comma = false
                elseif k == K","
                    after_comma = true
                elseif k == K"@"
                    i += 1
                    while i <= length(toks)
                        k2 = kind(toks[i])
                        k2 in (K"Identifier", K".", K"Whitespace") || break
                        i += 1
                    end
                    after_comma = false
                elseif k == K"macrocall"
                    i += 1
                    while i <= length(toks)
                        k2 = kind(toks[i])
                        k2 in (K",", K"NewlineWs") && break
                        k2 in (K"Whitespace", K"Comment") || (i += 1; continue)
                        i += 1
                    end
                    after_comma = false
                elseif k == K"NewlineWs"
                    after_comma || break
                elseif k in (K"Whitespace", K"Comment")
                else
                    break
                end
                i += 1
            end
        else
            i += 1
        end
    end
    return names
end

function module_private_names_in(src::AbstractString)
    names = Set{String}()
    for m in eachmatch(r"(?:^|\n)\s*(?:function|const|macro)\s+(_[A-Za-z0-9_]+)", src)
        push!(names, String(m.captures[1]))
    end
    for m in eachmatch(r"(?:^|\n)\s*mutable\s+struct\s+(_[A-Za-z0-9_]+)", src)
        push!(names, String(m.captures[1]))
    end
    return names
end

function public_names(root::AbstractString)
    names = Set{String}()
    for rel in ("src", "ext", "lib")
        base = joinpath(root, rel)
        isdir(base) || continue
        for (dir, _, files) in walkdir(base)
            if rel == "lib" && "src" ∉ split(relpath(dir, base), '/')
                continue
            end
            for file in files
                endswith(file, ".jl") || continue
                body = read(joinpath(dir, file), String)
                union!(names, public_names_in(body))
                union!(names, export_names_in(body))
                union!(names, module_private_names_in(body))
            end
        end
    end
    return names
end

function destructive_lines(src::AbstractString)
    lines = split(src, '\n'; keepempty = true)
    on = false
    out = Set{Int}()
    for (i, line) in enumerate(lines)
        if startswith(line, "## ")
            on = startswith(line, "## Destructive setup")
        end
        on && push!(out, i)
    end
    return out
end

function bare_name(line::AbstractString, name::AbstractString)
    i = firstindex(line)
    while true
        r = findnext(name, line, i)
        r === nothing && return false
        before_i = prevind(line, first(r))
        after_i = nextind(line, last(r))
        before = before_i < firstindex(line) ? ' ' : line[before_i]
        after = after_i > lastindex(line) ? ' ' : line[after_i]
        path = before in ('/', '.') || after in ('/', '.')
        word_before = !(isletter(before) || isdigit(before) || before == '_')
        word_after = !(isletter(after) || isdigit(after) || after == '_')
        if word_before && word_after && !path
            return true
        end
        i = nextind(line, last(r))
    end
    return
end

function lint_agents(root, files)
    hunks = get(files, "AGENTS.md", Hunk[])
    isempty(hunks) && return 0
    added = added_lines(hunks)
    isempty(added) && return 0
    src = read(joinpath(root, "AGENTS.md"), String)
    lines = split(src, '\n'; keepempty = true)
    allow = destructive_lines(src)
    names = public_names(root)
    n = 0
    for i in sort!(collect(added))
        i in allow && continue
        1 <= i <= length(lines) || continue
        for name in names
            if bare_name(lines[i], name)
                println(stderr, "lint: AGENTS.md:$(i): public name $(name) used as an identifier")
                n += 1
                break
            end
        end
    end
    return n
end

function has_version(node)
    stack = [node]
    while !isempty(stack)
        n = pop!(stack)
        if kind(n) == K"Identifier" && sourcetext(n) == "VERSION"
            return true
        end
        for i in 1:numchildren(n)
            push!(stack, n[i])
        end
    end
    return false
end

function macro_reason_string(node)
    numchildren(node) < 2 && return false
    arg = node[2]
    return kind(arg) in (K"string", K"String")
end

function node_touches_added(src, node, added)
    isempty(added) && return false
    r = byte_range(node)
    a = line_of(src, Int(first(r)))
    b = line_of(src, Int(last(r)))
    for line in a:b
        line in added && return true
    end
    return false
end

function truthy_skip_kw(val)
    val === nothing && return false
    kind(val) == K"Bool" && sourcetext(val) == "true" && return true
    has_version(val) && return true
    return false
end

function keyword_name(node)
    # `name=expr` is a `=` node whose first child is the name.
    kind(node) == K"=" || return nothing
    numchildren(node) < 1 && return nothing
    child = node[1]
    kind(child) == K"Identifier" || return nothing
    return sourcetext(child)
end

function keyword_value(node)
    numchildren(node) < 2 && return nothing
    return node[2]
end

function issue_numbers(text::AbstractString)
    return [Base.parse(Int, m.captures[1]) for m in eachmatch(r"#(\d+)", text)]
end

function comments_on(src, a, b)
    return [text for (la, lb, text) in comment_tokens(src) if !(lb < a || la > b)]
end

const issue_lookup = Ref(true)

function issue_check_active()
    issue_lookup[] || return false
    return get(ENV, "GITHUB_ACTIONS", "") == "true" ||
        get(ENV, "GATE_ISSUE_CHECK", "") == "1"
end

function issue_is_open(n::Int)
    issue_check_active() || return true
    repo = get(ENV, "GITHUB_REPOSITORY", "")
    isempty(repo) && die("GITHUB_REPOSITORY is unset")
    token = get(ENV, "GH_TOKEN", get(ENV, "GITHUB_TOKEN", ""))
    out = try
        if isempty(token)
            read(`gh api repos/$(repo)/issues/$(n) --jq .state`, String)
        else
            withenv("GH_TOKEN" => token, "GITHUB_TOKEN" => token) do
                read(`gh api repos/$(repo)/issues/$(n) --jq .state`, String)
            end
        end
    catch
        die("could not read issue #$(n) state")
    end
    return strip(out) == "open"
end

function require_open_issues(src, a, b, path)
    nerr = 0
    for text in comments_on(src, a, b)
        for n in issue_numbers(text)
            if !issue_is_open(n)
                println(stderr, "lint: $(path):$(a): #$(n) is missing or closed")
                nerr += 1
            end
        end
    end
    return nerr
end

function test_macro_name(node)
    numchildren(node) < 1 && return nothing
    head = node[1]
    if kind(head) == K"."
        numchildren(head) >= 2 || return nothing
        return sourcetext(head[2])
    end
    return sourcetext(head)
end

function macro_touches_added(src, node, added)
    isempty(added) && return false
    r = byte_range(node)
    a = line_of(src, Int(first(r)))
    b = line_of(src, Int(last(r)))
    for line in a:b
        line in added && return true
    end
    return false
end

function check_skip_macro(node, src, path)
    numchildren(node) < 1 && return 0
    name = test_macro_name(node)
    name === nothing && return 0
    name in ("test", "test_skip", "test_broken") || return 0
    r = byte_range(node)
    a = line_of(src, Int(first(r)))
    b = line_of(src, Int(last(r)))
    notes = join(comments_on(src, a, b), "\n")
    nums = issue_numbers(notes)
    nerr = 0
    for i in 2:numchildren(node)
        kw = keyword_name(node[i])
        kw == "context" || continue
        println(stderr, "lint: $(path):$(a): do not name a reason field context")
        nerr += 1
    end
    versioned = has_version(node)
    broken = name == "test_broken"
    skip = name == "test_skip"
    if name == "test"
        for i in 2:numchildren(node)
            child = node[i]
            if kind(child) == K"call"
                foreach_call_keyword(
                    child, part -> begin
                        kw = keyword_name(part)
                        kw === nothing && return nothing
                        val = keyword_value(part)
                        if kw == "broken" && val !== nothing && kind(val) == K"Bool" && sourcetext(val) == "true"
                            broken = true
                        elseif kw == "skip"
                            skip = true
                            val !== nothing && has_version(val) && (versioned = true)
                        end
                        return nothing
                    end
                )
            else
                kw = keyword_name(child)
                kw === nothing && continue
                val = keyword_value(child)
                if kw == "broken" && val !== nothing && kind(val) == K"Bool" && sourcetext(val) == "true"
                    broken = true
                elseif kw == "skip"
                    skip = true
                    val !== nothing && has_version(val) && (versioned = true)
                end
            end
        end
    end
    if broken || versioned
        if isempty(nums)
            println(stderr, "lint: $(path):$(a): #N is required")
            nerr += 1
        end
    elseif skip
        if !macro_reason_string(node)
            println(stderr, "lint: $(path):$(a): @test_skip needs a literal reason string in the first argument")
            nerr += 1
        end
    else
        return nerr
    end
    return nerr + require_open_issues(src, a, b, path)
end

function foreach_call_keyword(node, f)
    for i in 2:numchildren(node)
        child = node[i]
        if kind(child) == K"parameters"
            for j in 1:numchildren(child)
                f(child[j])
            end
        else
            f(child)
        end
    end
    return nothing
end

function check_call_test_guard(node, src, path, added)
    node_touches_added(src, node, added) || return 0
    nerr = 0
    broken = false
    skip = false
    versioned = false
    foreach_call_keyword(
        node, part -> begin
            kw = keyword_name(part)
            kw === nothing && return nothing
            val = keyword_value(part)
            if kw == "broken" && val !== nothing && (kind(val) == K"Bool" && sourcetext(val) == "true" || has_version(val))
                broken = true
                versioned = versioned || has_version(val)
            elseif kw == "skip" && truthy_skip_kw(val)
                skip = true
                versioned = versioned || (val !== nothing && has_version(val))
            end
            return nothing
        end
    )
    broken || skip || versioned || return 0
    r = byte_range(node)
    a = line_of(src, Int(first(r)))
    b = line_of(src, Int(last(r)))
    notes = join(comments_on(src, a, b), "\n")
    nums = issue_numbers(notes)
    if broken || versioned
        if isempty(nums)
            println(stderr, "lint: $(path):$(a): broken/skip kwarg guard needs #N")
            nerr += 1
        end
    end
    return nerr + require_open_issues(src, a, b, path)
end

function lint_skips(root, files, src_for_path)
    n = 0
    for (path, hunks) in files
        endswith(path, ".jl") || continue
        skipped_path(path) && continue
        added = added_lines(hunks)
        isempty(added) && continue
        src = src_for_path(path)
        tree = parse_tree(src)
        function walk(node)
            k = kind(node)
            if k == K"macrocall" && macro_touches_added(src, node, added)
                n += check_skip_macro(node, src, path)
            elseif k == K"call" && node_touches_added(src, node, added)
                n += check_call_test_guard(node, src, path, added)
            end
            for i in 1:numchildren(node)
                walk(node[i])
            end
            return
        end
        walk(tree)
    end
    if !isempty(root)
        n += report_hits(collect_loop_skip(root, files, src_for_path; whole = false))
        n += check_ceiling(
            "CEILING_LOOP_SKIP",
            length(collect_loop_skip(root, files, src_for_path; whole = true)),
            CEILING_LOOP_SKIP,
        )
    end
    return n
end

function deleted_doc_covers(src::AbstractString)
    try
        return doc_covers(src)
    catch e
        e isa JuliaSyntax.ParseError || rethrow()
        return UnitRange{Int}[]
    end
end

function deleted_bodies(h::Hunk)
    bodies = Set{String}()
    isempty(h.deleted) && return bodies
    src = join(h.deleted, '\n') * '\n'
    docs = deleted_doc_covers(src)
    toks = collect(tokenize(src))
    for tok in toks
        kind(tok) == K"Comment" || continue
        r = Int(first(tok.range)):Int(last(tok.range))
        isempty(r) && continue
        in_doc(docs, first(r)) && continue
        push!(bodies, comment_body(untokenize(tok, src)))
    end
    if any(tok -> JuliaSyntax.is_error(kind(tok)), toks)
        for line in h.deleted
            line_src = line * '\n'
            for tok in tokenize(line_src)
                kind(tok) == K"Comment" || continue
                push!(bodies, comment_body(untokenize(tok, line_src)))
            end
        end
    end
    return bodies
end

function lint_new_comments(root, files)
    n = 0
    for (path, hunks) in files
        endswith(path, ".jl") || continue
        skipped_path(path) && continue
        full = joinpath(root, path)
        isfile(full) || continue
        src = read(full, String)
        for (a, b, text) in comment_tokens(src)
            hunk = nothing
            for h in hunks
                if any(in(added_lines(h)), a:b)
                    hunk = h
                    break
                end
            end
            hunk === nothing && continue
            comment_body(text) in deleted_bodies(hunk) && continue
            for num in issue_numbers(text)
                if !issue_is_open(num)
                    println(stderr, "lint: $(path):$(a): #$(num) is missing or closed")
                    n += 1
                end
            end
        end
    end
    return n
end

function self_test()
    issue_lookup[] = false
    try
        return self_test_body()
    finally
        issue_lookup[] = true
    end
end

function self_test_body()
    withenv(
        "GITHUB_ACTIONS" => "true",
        "GITHUB_REPOSITORY" => "nobody/no-such-distssh-repo",
        "GH_TOKEN" => "invalid",
        "GITHUB_TOKEN" => "invalid",
    ) do
        issue_is_open(1) || die("self-test: issue lookup ran")
    end
    return self_test_body_inner()
end

function self_test_body_inner()
    return withenv("GATE_DIFF_RANGE" => "", "GATE_DIFF_BASE" => "", "GATE_DIFF_HEAD" => "") do
        self_test_body_main()
    end
end

function self_test_body_main()
    src = """
    # fine for now
    s = \"# fine for now\"
    `# workaround`
    #= delve =#
    \"\"\"
    a docstring # crucial
    \"\"\"
    f
    @test_skip \"git not in PATH\"
    @test_broken \"needs a number\"
    @test g() skip=(VERSION < v\"1.14\")
    function helper()
        @test_broken \"inside helper\"
    end
    """
    comments = comment_tokens(src)
    texts = [t for (_, _, t) in comments]
    any(occursin("fine for now", t) && !occursin("\"", t) for t in texts) || die("self-test: line comment missing")
    any(occursin("workaround", t) for t in texts) && die("self-test: cmdstring was a comment")
    any(occursin("crucial", t) for t in texts) && die("self-test: docstring was a comment")
    any(t -> banned_hit(t) == "fine for now", texts) || die("self-test: banned word")
    tree = parse_tree(src)
    found = String[]
    function walk(node, inside)
        if kind(node) == K"macrocall" && !inside && numchildren(node) >= 1
            push!(found, sourcetext(node[1]))
        end
        next = inside || kind(node) == K"function"
        for i in 1:numchildren(node)
            walk(node[i], next)
        end
        return
    end
    walk(tree, false)
    "test_broken" in found || die("self-test: broken not seen")
    count(==("test_broken"), found) == 1 || die("self-test: helper was counted")
    bare_name("see run_identity now", "run_identity") || die("self-test: identifier")
    bare_name("src/run_identity.jl", "run_identity") && die("self-test: path was an identifier")
    names = public_names_in("public a, b # note\npublic c\n")
    names == Set(["a", "b", "c"]) || die("self-test: public names $(names)")
    public_names_in("public api\ninternal = 1\n") == Set(["api"]) ||
        die("self-test: public statement boundary")
    skip_src = """
    @test_skip \"git not in PATH\"
    @test_skip f(\"x\")
    @test_broken \"needs a number\"
    @test g() skip=(VERSION < v\"1.14\")
    @test h() skip=true
    Test.@test j() skip=true
    @test i() broken=true #1
    function helper()
        @test_broken \"inside helper\"
    end
    """
    for qsrc in (
            "Test.@test_skip \"git not in PATH\"\n",
            "Main.Test.@test_skip \"git not in PATH\"\n",
            "@Test.test_skip \"git not in PATH\"\n",
        )
        test_macro_name(parse_tree(qsrc)[1]) == "test_skip" ||
            die("self-test: qualified macro name $(qsrc)")
    end
    tree2 = parse_tree(skip_src)
    errs = Ref(0)
    function walk2(node)
        if kind(node) == K"macrocall"
            errs[] += check_skip_macro(node, skip_src, "t.jl")
        elseif kind(node) == K"call"
            errs[] += check_call_test_guard(node, skip_src, "t.jl", Set(1:200))
        end
        for i in 1:numchildren(node)
            walk2(node[i])
        end
        return
    end
    walk2(tree2)
    errs[] == 6 || die("self-test: skip errors $(errs[])")
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "src", "DistSSHRun.jl"), "module DistSSHRun\nexport worker_pmap\nend\n")
        write(joinpath(root, "AGENTS.md"), "Use worker_pmap in docs.\n")
        files = Dict("AGENTS.md" => [Hunk(1, 0, 1, 1, String[])])
        lint_agents(root, files) == 1 || die("self-test: agents-md must fail on export name")
    end
    ml = """
    @test long() begin
        1
    end skip=true
    """
    h = Hunk(1, 2, 3, 1, String[])
    lint_skips("", Dict("t.jl" => [h]), path -> path == "t.jl" ? ml : "") == 1 ||
        die("self-test: multiline skip on added tail line")
    ml_untouched = ml * "x = 1\n"
    h_after = Hunk(4, 0, 4, 1, String[])
    lint_skips("", Dict("t.jl" => [h_after]), path -> path == "t.jl" ? ml_untouched : "") == 0 ||
        die("self-test: untouched multiline skip flagged")
    docsrc = "\"\"\"\ndoc\n\"\"\"\nf() = 1\n"
    ranges = doc_line_ranges(docsrc)
    length(ranges) == 1 && 1 in ranges[1] && 3 in ranges[1] && !(4 in ranges[1]) || die("self-test: doc lines $(ranges)")
    bad = "# Pull request\n## Summary\n## Testing\n## Risk\n## Revert\n## Checklist\n- [ ] x\n"
    terr = pr_template_errors(bad)
    any(endswith(e, "title heading") for e in terr) || die("self-test: title heading")
    any(endswith(e, "checklist") for e in terr) || die("self-test: checklist")
    good = "## Summary\n\n## Testing\n\n## Risk\n\n## Revert\n"
    isempty(pr_template_errors(good)) || die("self-test: template $(pr_template_errors(good))")
    summary_only = "## Summary\n\nThe hook stays.\n"
    isempty(pr_template_errors(summary_only)) || die("self-test: summary only $(pr_template_errors(summary_only))")
    short = "tone_instructions: >\n  Brief.\n"
    isempty(coderabbit_tone_errors(short)) || die("self-test: tone $(coderabbit_tone_errors(short))")
    long = "tone_instructions: >\n  " * repeat("a", 251) * "\n"
    any(occursin("250", e) for e in coderabbit_tone_errors(long)) || die("self-test: tone limit")
    listed = ["scripts/check.sh", "CONTRIBUTING.md"]
    dump = "## Summary\n\n## Risk\n\n## Revert\n\n- `scripts/check.sh`\n- `CONTRIBUTING.md`\n"
    any(==("file list"), pr_body_errors(dump, listed)) || die("self-test: pr body file list")
    fenced = "## Summary\n\n## Risk\n\n## Revert\n\n```\nscripts/check.sh\nCONTRIBUTING.md\n```\n"
    any(==("file list"), pr_body_errors(fenced, listed)) || die("self-test: pr body fence")
    short = "## Summary\n\nscripts/check.sh is the gate.\n\n## Testing\n\nRan it.\n\n## Risk\n\nThe hook remains.\n\n## Revert\n\nRevert the merge.\n"
    any(x -> occursin("Testing", x), pr_body_errors(short, listed)) ||
        die("self-test: pr body prose Testing $(pr_body_errors(short, listed))")
    isempty(pr_body_errors(dump, ["scripts/check.sh"])) || die("self-test: pr body one path")
    star = "## Summary\n\n## Risk\n\n## Revert\n\n* `scripts/check.sh`\n* `CONTRIBUTING.md`\n"
    any(==("file list"), pr_body_errors(star, listed)) || die("self-test: pr body star list")
    dup_ai = "## Summary\n\n## Testing\n\nRan it.\n\nGenerative tool: Cursor Agent.\n\nMade with [Cursor](https://cursor.com)\n"
    any(==("duplicate AI attribution (Generative tool and a Made with footer)"), pr_body_hints(dup_ai, "")) ||
        die("self-test: pr body duplicate AI hint")
    dup_other = "## Summary\n\ngenerative tool: SomeTool\n\nmade with SomeTool\n"
    any(x -> startswith(x, "duplicate AI attribution"), pr_body_hints(dup_other, "")) ||
        die("self-test: pr body duplicate AI hint case")
    isempty(pr_body_hints("Generative tool: Cursor Agent.\n", "")) || die("self-test: pr body single AI hint")
    prose = "## Summary\n\nThe fix was made with care.\n\nGenerative tool: SomeTool\n"
    isempty(pr_body_hints(prose, "")) || die("self-test: pr body made with prose")
    lower_env = "## Summary\n\n## Testing\n\nRan on ubuntu 24.04 with julia 1.13.\n"
    isempty(pr_body_hints(lower_env, "")) || die("self-test: pr body lowercase env")
    noenv = "## Summary\n\n## Testing\n\n`./scripts/check.sh` passed.\n"
    env_hints = pr_body_hints(noenv, "Linux x86_64, Julia 1.13.4")
    any(x -> x == "add env to ## Testing (Linux x86_64, Julia 1.13.4)", env_hints) ||
        die("self-test: pr body testing env hint $(env_hints)")
    any(x -> startswith(x, "add the OS to ## Testing"), pr_body_hints(noenv, "")) ||
        die("self-test: pr body testing env hint no example")
    with_env = "## Summary\n\n## Testing\n\nEnvironment: Darwin arm64, Julia 1.13.4.\n\nRan check.\n"
    isempty(pr_body_hints(with_env, "")) || die("self-test: pr body testing env ok")
    isempty(pr_body_hints("## Summary\n\nNo testing section.\n", "")) || die("self-test: pr body no testing section")
    stale = pr_body_hints("Any wording is fine.\n", "", "2026-11-20T21:00:00+09:00", "2026-11-20T11:00:00Z")
    any(==("update the PR body (a commit is newer than the last edit)"), stale) ||
        die("self-test: pr body stale edit $(stale)")
    fresh = pr_body_hints("Any wording is fine.\n", "", "2026-11-20T11:00:00Z", "2026-11-20T12:00:00Z")
    any(x -> startswith(x, "update the PR body"), fresh) && die("self-test: pr body fresh edit")
    any(x -> startswith(x, "update the PR body"), pr_body_hints("Any wording is fine.\n", "", "", "")) &&
        die("self-test: pr body missing edit time")
    fence_ok = "## Summary\n\n## Testing\n\n```sh\n# Confirmed locally\n```\n\n## Risk\n\n## Revert\n"
    isempty(pr_template_errors(fence_ok)) || die("self-test: pr fence heading $(pr_template_errors(fence_ok))")
    patch_pin = stdlib_compat_errors(
        Dict("compat" => Dict("julia" => "1.13", "OpenSSL_jll" => "3.5.8"), "deps" => Dict("OpenSSL_jll" => "458c3c95-2e84-50aa-8efc-19380b2a3a95")),
        Dict("OpenSSL_jll" => v"3.5.8"),
    )
    any(occursin("OpenSSL_jll", e) && occursin("patch", e) for e in patch_pin) || die("self-test: stdlib patch pin $(patch_pin)")
    isempty(
        stdlib_compat_errors(
            Dict("compat" => Dict("julia" => "1.13", "OpenSSL_jll" => "3.5"), "deps" => Dict("OpenSSL_jll" => "458c3c95-2e84-50aa-8efc-19380b2a3a95")),
            Dict("OpenSSL_jll" => v"3.5.8"),
        ),
    ) || die("self-test: stdlib two-component")
    percent_decode("a%20b") == "a b" || die("self-test: percent decode")
    for (_, _, text) in comment_tokens("# Use café\n")
    end
    link_target("guide.md \"Read the guide\"") == "guide.md" || die("self-test: link title")
    ssh_argv_hit("-o BatchMode=yes") == "BatchMode" || die("self-test: ssh BatchMode")
    ssh_argv_hit("Cmd([\"ssh\", host])") == "raw ssh argv" || die("self-test: ssh raw argv")
    ssh_argv_hit("_ssh_cmd([\"ssh\", dest])") === nothing || die("self-test: ssh builder argv")
    scan = "src/DistSSHRun/infra/remote.jl"
    raw_ml = """
    Cmd([
        \"ssh\", host,
    ])
    """
    for (h, msg) in (
            (Hunk(1, 0, 1, 1, String[]), "multiline cmd first added line"),
            (Hunk(1, 0, 2, 1, String[]), "multiline cmd ssh added line"),
        )
        lint_ssh_argv("", Dict(scan => [h]), _ -> raw_ml) == 1 ||
            die("self-test: ssh argv $(msg)")
    end
    str_ml = """
    String[
        \"ssh\", host,
    ]
    """
    lint_ssh_argv("", Dict(scan => [Hunk(1, 0, 1, 1, String[])]), _ -> str_ml) == 1 ||
        die("self-test: ssh argv multiline String")
    builder_ml = """
    _ssh_cmd([
        \"ssh\", dest,
    ])
    """
    lint_ssh_argv("", Dict(scan => [Hunk(1, 0, 2, 1, String[])]), _ -> builder_ml) == 0 ||
        die("self-test: ssh argv multiline builder exempt")
    untouched = "x = 1\nCmd([\"ssh\", host])\n"
    lint_ssh_argv("", Dict(scan => [Hunk(1, 0, 1, 1, String[])]), _ -> untouched) == 0 ||
        die("self-test: ssh argv outside added lines")
    drive_src = "src/DistSSHRun/core/drive/run.jl"
    for (code, want, msg) in (
            ("isdefined(Main, :main) || return\n", 1, "isdefined"),
            ("f = getfield(Main, :prepare_workers!)\n", 1, "getfield"),
            ("Main.init_output_dir!(args)\n", 1, "dotted call"),
            ("function _drive_hook_binding(name)\n    isdefined(Main, name)\nend\n", 0, "accessor"),
            ("_call_drive_script_hook(name) = getfield(Main, name)\n", 0, "short accessor"),
            ("Base.include(Main, path)\n", 0, "include into Main"),
        )
        lint_drive_hooks("", Dict(drive_src => [Hunk(1, 0, 1, 1, String[])]), _ -> code) == want ||
            die("self-test: drive hooks $(msg)")
    end
    lint_drive_hooks("", Dict(drive_src => [Hunk(1, 0, 1, 1, String[])]), _ -> "x = 1\nMain.main()\n") == 0 ||
        die("self-test: drive hooks outside added lines")
    lint_drive_hooks("", Dict("src/DistSSHRun.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> "getfield(Main, sym)()\n") == 0 ||
        die("self-test: drive hooks outside drive sources")
    ssh_scan_path("lib/DistSSHBase/src/ssh/ssh.jl") && die("self-test: ssh builder scanned")
    ssh_scan_path("src/DistSSHRun/infra/remote.jl") || die("self-test: ssh product scanned")
    aqua_lines = [
        "  aqua:",
        "    name: Aqua (1.13, ubuntu-latest, x64)",
        "    steps:",
        "      - name: Aqua.test_all (latest Aqua)",
        "        run: ./.github/aqua-check.sh",
        "      - name: extra",
        "        run: julia extra.jl",
    ]
    workflow_job_title(aqua_lines, 7) == "Aqua (1.13, ubuntu-latest, x64)" ||
        die("self-test: aqua job title")
    aqua_run_hit("Aqua (1.13, ubuntu-latest, x64)", "        run: ./.github/aqua-check.sh") ===
        nothing || die("self-test: aqua-check allowed")
    aqua_run_hit("Aqua (1.13, ubuntu-latest, x64)", "        run: julia extra.jl") ==
        "Aqua job run is not aqua-check.sh" || die("self-test: aqua extra run")
    split_for = Hunk(1, 2, 1, 1, String["for (k, v) in xs()", "    y = v"])
    deleted_bodies(split_for) == Set{String}() || die("self-test: split for")
    moved = Hunk(1, 2, 1, 1, String["for (k, v) in xs()", "# moved note"])
    "moved note" in deleted_bodies(moved) || die("self-test: deleted comment")
    partial = Hunk(1, 1, 1, 1, String["for (k, v) in xs()  # partial inline"])
    "partial inline" in deleted_bodies(partial) || die("self-test: partial deleted comment")
    del_doc = Hunk(1, 5, 1, 1, String["\"\"\"", "doc", "# inside doc \$(1 # doc interp\n)", "\"\"\"", "f() = 1"])
    isempty(deleted_bodies(del_doc)) || die("self-test: docstring treated as deleted comment")
    del_mstr = Hunk(1, 3, 1, 1, String["s = \"\"\"", "# inside string", "\"\"\""])
    isempty(deleted_bodies(del_mstr)) || die("self-test: multiline string treated as deleted comment")
    del_mid_str = Hunk(1, 2, 1, 1, String["end\"\"\"", "x = 1 # after split string"])
    "after split string" in deleted_bodies(del_mid_str) || die("self-test: comment after split string")
    bin = """
    diff --git a/docs/preview.png b/docs/preview.png
    Binary files a/docs/preview.png and b/docs/preview.png differ
    """
    bin_files = parse_diff(bin)
    doc_touch_files(bin_files, _ -> "", _ -> "") || die("self-test: binary docs path")
    lint_banned("", bin_files) == 0 || die("self-test: binary lint_banned")
    lint_skips("", bin_files, _ -> "") == 0 || die("self-test: binary lint_skips")
    bin_rename = """
    diff --git a/docs/old.png b/other/old.png
    similarity index 100%
    rename from docs/old.png
    rename to other/old.png
    """
    doc_touch_files(parse_diff(bin_rename), _ -> "", _ -> "") || die("self-test: binary docs rename")
    mktempdir() do tmp
        git(args...) = run(
            pipeline(
                `git -C $tmp -c user.name=t -c user.email=t@e -c commit.gpgsign=false $args`;
                stdout = devnull,
                stderr = devnull,
            ),
        )
        git("init", "-b", "main")
        write(joinpath(tmp, "f.jl"), "x = 1\n\"\"\"\ndoc\n\"\"\"\nf() = 2\n")
        git("add", "f.jl")
        git("commit", "-m", "base")
        git("checkout", "-b", "feat")
        write(joinpath(tmp, "f.jl"), "x = 1\nf() = 2\n")
        git("commit", "-am", "drop doc")
        git("checkout", "main")
        write(joinpath(tmp, "f.jl"), "a = 1\nb = 2\nc = 3\nd = 4\nx = 1\n\"\"\"\ndoc\n\"\"\"\nf() = 2\n")
        git("commit", "-am", "advance main")
        main_sha = strip(read(`git -C $tmp rev-parse main`, String))
        git("update-ref", "refs/remotes/origin/main", main_sha)
        git("checkout", "feat")
        lines_hit_doc(show_file(tmp, "f.jl"; ref = "origin/main"), Set(2:4)) &&
            die("self-test: origin/main tip unexpectedly hit doc")
        doc_touch(tmp) || die("self-test: doc_touch merge-base")
    end
    bogus_range =
        "d56a722ee521eda73e7df5c7bc0b186e9407ab1a...3963089a57e73146e0411104b4be53f4e8847dd8"
    withenv("GATE_DIFF_RANGE" => bogus_range) do
        mktempdir() do tmp
            git(args...) = run(
                pipeline(
                    `git -C $tmp -c user.name=t -c user.email=t@e -c commit.gpgsign=false $args`;
                    stdout = devnull,
                    stderr = devnull,
                ),
            )
            git("init", "-b", "main")
            write(joinpath(tmp, "f.jl"), "x = 1\n")
            git("add", "f.jl")
            git("commit", "-m", "one")
            try
                resolve_git_diff_range!(tmp, bogus_range)
                die("self-test: bogus GATE_DIFF_RANGE must fail closed")
            catch e
                e isa ErrorException || rethrow(e)
                occursin("GATE_DIFF_RANGE", e.msg) || die("self-test: bogus GATE_DIFF_RANGE message $(e.msg)")
            end
        end
    end
    ex_macro = export_names_in("export @reexport, foo, bar\n")
    ex_macro == Set(["foo", "bar"]) || die("self-test: export after macro $ex_macro")
    guard_src = "f(tag; broken=true)\n"
    guard_node = parse_tree(guard_src)[1]
    check_call_test_guard(guard_node, guard_src, "t.jl", Set(1:2)) >= 1 ||
        die("self-test: parameters broken kw without #N")
    guard_ok = "f(tag; broken=true) #3\n"
    guard_node2 = parse_tree(guard_ok)[1]
    check_call_test_guard(guard_node2, guard_ok, "t.jl", Set(1:2)) == 0 ||
        die("self-test: parameters broken kw with #N")
    rt_src = "# _runtest_include(\"ghost.jl\")\n_runtest_include(\"real.jl\")\n"
    rt_inc = runtests_includes(rt_src, "")
    rt_inc == Set(["real.jl"]) || die("self-test: commented runtest include $rt_inc")
    join_src = "include(joinpath(@__DIR__, \"unit\", \"nested.jl\"))\n"
    join_inc = runtests_includes(join_src, "lib/Fake/test/")
    join_inc == Set(["lib/Fake/test/unit/nested.jl"]) ||
        die("self-test: joinpath include $join_inc")
    dynamic_join = "include(joinpath(pkg_root, \"unit\", \"nested.jl\"))\n"
    isempty(runtests_includes(dynamic_join, "lib/Fake/test/")) ||
        die("self-test: joinpath non-literal must not resolve")
    mktempdir() do tmp
        pkg_t = joinpath(tmp, "lib", "Pkg", "test")
        mkpath(joinpath(pkg_t, "suites"))
        write(joinpath(pkg_t, "runtests.jl"), "include(\"suites/a.jl\")\n")
        write(
            joinpath(pkg_t, "suites", "a.jl"),
            "include(joinpath(@__DIR__, \"cases\", \"b.jl\"))\n",
        )
        mkpath(joinpath(pkg_t, "suites", "cases"))
        write(joinpath(pkg_t, "suites", "cases", "b.jl"), "using Test\n@test 1 == 1\n")
        reach = runtests_reachable("lib/Pkg/test/", joinpath(pkg_t, "runtests.jl"), pkg_t)
        "lib/Pkg/test/suites/cases/b.jl" in reach ||
            die("self-test: transitive joinpath include $reach")
        write(
            joinpath(pkg_t, "suites", "a.jl"),
            "include(joinpath(@__DIR__, \"unit\", \"nested.jl\"))\ninclude(\"../shared_case.jl\")\n",
        )
        mkpath(joinpath(pkg_t, "suites", "unit"))
        write(joinpath(pkg_t, "suites", "unit", "nested.jl"), "using Test\n@test true\n")
        write(joinpath(pkg_t, "shared_case.jl"), "using Test\n@test true\n")
        reach2 = runtests_reachable("lib/Pkg/test/", joinpath(pkg_t, "runtests.jl"), pkg_t)
        "lib/Pkg/test/shared_case.jl" in reach2 ||
            die("self-test: parent-relative include $reach2")
    end
    common_src = "function _distsshrun_short_skip_paths()\n    return (\"integration/a.jl\",)\nend\n"
    paths, ok = short_skip_paths_from_common(common_src)
    (ok && paths == ["integration/a.jl"]) || die("self-test: short skip paths $(paths) $(ok)")
    missing_fn = "const x = 1\n"
    _, ok2 = short_skip_paths_from_common(missing_fn)
    ok2 && die("self-test: short skip must fail closed")
    judge_norm = strip(read(`bash -c 'id=test-unit; norm=${id//-/_}; var=RESULT_${norm}; export RESULT_test_unit=success; echo ${!var:-missing}'`, String))
    judge_norm == "success" || die("self-test: judge result normalization $(judge_norm)")
    judge_script = joinpath(@__DIR__, "..", "gate", "judge_self_test.sh")
    judge_buf = IOBuffer()
    judge_proc = run(pipeline(`$judge_script`, stdout = judge_buf, stderr = judge_buf))
    judge_self = String(take!(judge_buf))
    if !success(judge_proc)
        for line in split(strip(judge_self), '\n'; keepempty = false)
            println(stderr, line)
        end
        for line in split(strip(judge_self), '\n'; keepempty = false)
            startswith(line, "FAIL  ") && die("self-test: judge_self_test $(line)")
        end
        die("self-test: judge_self_test exit $(judge_proc.exitcode)")
    end
    judge_lines = split(strip(judge_self), '\n'; keepempty = false)
    isempty(judge_lines) && die("self-test: judge_self_test no output")
    for line in judge_lines
        startswith(line, "ok  ") || die("self-test: judge_self_test unexpected line $(line)")
    end
    length(GATE_LINT_NAMES) == 15 || die("self-test: GATE_LINT_NAMES $(length(GATE_LINT_NAMES))")
    "all" in GATE_LINT_NAMES && die("self-test: all is not a per-mode name")
    lint_sh = read(joinpath(@__DIR__, "..", "gate", "lint.sh"), String)
    occursin("run.sh\" all", lint_sh) || die("self-test: lint.sh must run all in one process")
    occursin("lint_names=", lint_sh) && die("self-test: lint.sh still loops modes")
    shell_list = strip(read(`bash -c 'git ls-files scripts/*.sh .github/*.sh | LC_ALL=C sort -u'`, String))
    occursin("scripts/check.sh", shell_list) || die("self-test: shellcheck pathspec missing check.sh")
    occursin(".github/jetls-check.sh", strip(read(`bash -c 'git ls-files .github/*.sh'`, String))) ||
        die("self-test: shellcheck pathspec missing jetls-check.sh")
    id_src = "occursin(job_id, name)\nid == token\n"
    id_h = Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])])
    length(collect_id_match("", id_h, _ -> id_src; whole = false)) >= 1 || die("self-test: id-match hit")
    id_ok = "id == job_id\n"
    isempty(collect_id_match("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> id_ok; whole = false)) ||
        die("self-test: id-match exact ==")
    id_rng = "run_id[1:8] == token\n"
    length(collect_id_match("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> id_rng; whole = false)) >= 1 ||
        die("self-test: id-match range index")
    proc_src = "Cmd([\"pkill\", \"-9\", \"-f\", p])\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> proc_src; whole = false)) >= 1 ||
        die("self-test: process-pattern hit")
    lock_src = "if isfile(lock_path)\n    write(lock_path, pid)\nend\n"
    length(collect_lock_create("", Dict("src/x.jl" => [Hunk(1, 0, 1, 2, String[])]), _ -> lock_src; whole = false)) >= 1 ||
        die("self-test: lock-create hit")
    mkdir_src = "mkdir(lock_path)\n"
    isempty(collect_lock_create("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> mkdir_src; whole = false)) ||
        die("self-test: lock-create mkdir")
    lock_other = "if isfile(lock_path)\n    write(lock_path_backup, pid)\nend\n"
    isempty(collect_lock_create("", Dict("src/x.jl" => [Hunk(1, 0, 1, 2, String[])]), _ -> lock_other; whole = false)) ||
        die("self-test: lock-create other path")
    env_src = "get(ENV, \"X\", \"1\")\nget(ENV, \"X\", \"\")\n"
    env_h = Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])])
    length(collect_env_default("", env_h, _ -> env_src; whole = false)) == 1 || die("self-test: env-default hit")
    test_src = "withenv(\"DISTSSH_JOBS\" => \"nope\") do\n    @test kit_host_jobs() == 1\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> test_src; whole = false)) >= 1 ||
        die("self-test: env-default test hit")
    throw_src = "withenv(\"DISTSSH_JOBS\" => \"nope\") do\n    @test_throws ArgumentError kit_host_jobs()\nend\n"
    isempty(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> throw_src; whole = false)) ||
        die("self-test: env-default test throws")
    catch_src = "try\n    f()\ncatch\nend\n"
    length(collect_swallowed_catch("", Dict("src/x.jl" => [Hunk(3, 0, 3, 2, String[])]), _ -> catch_src; whole = false)) >= 1 ||
        die("self-test: swallowed-catch hit")
    rethrow_src = "try\n    f()\ncatch e\n    e isa InterruptException && rethrow()\n    error(e)\nend\n"
    isempty(collect_swallowed_catch("", Dict("src/x.jl" => [Hunk(3, 0, 3, 4, String[])]), _ -> rethrow_src; whole = false)) ||
        die("self-test: swallowed-catch rethrow")
    swallow_ie = "try\n    f()\ncatch e\n    e isa InterruptException && rethrow()\n    nothing\nend\n"
    length(collect_swallowed_catch("", Dict("src/x.jl" => [Hunk(3, 0, 3, 4, String[])]), _ -> swallow_ie; whole = false)) >= 1 ||
        die("self-test: swallowed-catch interrupt then nothing")
    skip_src2 = "for kind in ks\n    kind == \"x\" && continue\nend\n"
    length(collect_loop_skip("", Dict("test/t.jl" => [Hunk(2, 0, 2, 1, String[])]), _ -> skip_src2; whole = false)) >= 1 ||
        die("self-test: loop skip hit")
    skip_ok = "for kind in ks\n    kind == \"x\" && continue #1\nend\n"
    isempty(collect_loop_skip("", Dict("test/t.jl" => [Hunk(2, 0, 2, 1, String[])]), _ -> skip_ok; whole = false)) ||
        die("self-test: loop skip reason")
    if_src = "for kind in kinds\n    if kind == \"slow\"\n        continue\n    end\nend\n"
    length(collect_loop_skip("", Dict("test/t.jl" => [Hunk(2, 0, 2, 3, String[])]), _ -> if_src; whole = false)) >= 1 ||
        die("self-test: loop skip if continue")
    if_ok = "for kind in kinds\n    if kind == \"slow\" #1\n        continue\n    end\nend\n"
    isempty(collect_loop_skip("", Dict("test/t.jl" => [Hunk(2, 0, 2, 3, String[])]), _ -> if_ok; whole = false)) ||
        die("self-test: loop skip if continue reason")
    if_flag = "for kind in kinds\n    if flag\n        continue\n    end\nend\n"
    isempty(collect_loop_skip("", Dict("test/t.jl" => [Hunk(2, 0, 2, 3, String[])]), _ -> if_flag; whole = false)) ||
        die("self-test: loop skip if flag")
    nest_src = "for k in ks\n    if k == \"slow\"\n        if extra\n            continue\n        end\n    end\nend\n"
    isempty(collect_loop_skip("", Dict("test/t.jl" => [Hunk(2, 0, 2, 5, String[])]), _ -> nest_src; whole = false)) ||
        die("self-test: loop skip nested if")
    pref = "const S = \"see DistSSHQueue #12\"\n"
    length(collect_pr_refs("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> pref; whole = false)) >= 1 ||
        die("self-test: pr-refs hit")
    ev_fail = excuse_word_errors("This is known on CI.\n")
    any(endswith(e, "known") for e in ev_fail) || die("self-test: evidence fail $(ev_fail)")
    ev_ok = excuse_word_errors("This is known on main https://github.com/yamanori99/DistSSHRun.jl/actions/runs/1\n")
    isempty(ev_ok) || die("self-test: evidence pass $(ev_ok)")
    has_main_run_url("main https://githubXcom/t/p/actions/runs/1") && die("self-test: github host")
    markdown_removed_names("removed `old_api` in favor of `new_api`") == ["old_api"] ||
        die("self-test: removed names favor")
    fence_ev = "## Testing\n\n```text\n## Worker output\n```\n\nKnown failure.\n\n## Risk\n"
    any(endswith(e, "known") for e in excuse_word_errors(section_named_text(fence_ev, "Testing"))) ||
        die("self-test: evidence after fence heading")
    check_ceiling("CEILING_ID_MATCH", 1, 0) == 1 || die("self-test: ceiling mismatch")
    prose_testing = "## Testing\n\nran it\n"
    any(x -> occursin("Testing", x), testing_format_errors(section_named_text(prose_testing, "Testing"))) ||
        die("self-test: testing format prose")
    table_testing = "## Testing\n\n| os | julia |\n|---|---|\n"
    any(x -> occursin("table", x), testing_format_errors(section_named_text(table_testing, "Testing"))) ||
        die("self-test: testing format table")
    shaped = "## Testing\n\nmacOS arm64, Julia 1.13.4.\n\n`julia --version`\n\n```text\njulia version 1.13.4\n```\n"
    isempty(testing_format_errors(section_named_text(shaped, "Testing"))) ||
        die("self-test: testing format good $(testing_format_errors(section_named_text(shaped, "Testing")))")
    stale_head = "## Summary\n\nx\n\n## Testing\n\nLinux x86_64, Julia 1.13.4.\n\n`true`\n\n```text\nok\n```\n\n## Risk\n\n## Revert\n"
    isempty(pr_body_errors(stale_head, ["README.md"])) ||
        die("self-test: testing format pr pass")
    no_fence = "## Summary\n\nx\n\n## Testing\n\nLinux x86_64, Julia 1.13.4.\n\n`true`\n\n## Risk\n\n## Revert\n"
    any(x -> occursin("text output", x), pr_body_errors(no_fence, ["README.md"])) ||
        die("self-test: testing missing fence")
    pending_fail = "## Risk\n\nStill pending on main.\n"
    any(endswith(e, "pending") for e in excuse_word_errors(section_named_text(pending_fail, "Risk"))) ||
        die("self-test: pending evidence")
    table_in_fence = "## Testing\n\nLinux x86_64, Julia 1.13.4.\n\n`true`\n\n```text\n| a | b |\n|---|---|\n```\n"
    isempty(testing_format_errors(section_named_text(table_in_fence, "Testing"))) ||
        die("self-test: table in text fence $(testing_format_errors(section_named_text(table_in_fence, "Testing")))")
    testing_has_env_line("Linux x86_64, Julia 1.13.4") &&
        die("self-test: version dot must not satisfy env line")
    testing_has_env_line("Linux x86_64, Julia 1.13.4.") ||
        die("self-test: sentence period env line")
    cmd_fence_only = "## Testing\n\nLinux x86_64, Julia 1.13.4.\n\n```text\n`only in fence`\n```\n"
    any(x -> occursin("command", x), testing_format_errors(section_named_text(cmd_fence_only, "Testing"))) ||
        die("self-test: cmd in fence only")
    hdr_in_fence = "## Summary\n\n```markdown\n## Testing\n```\n\n## Risk\n"
    testing_section_present(hdr_in_fence) && die("self-test: testing heading in fence")
    banned_hit("# until later") == "until" || die("self-test: until phrase $(repr(banned_hit("# until later")))")
    println("self-test: passed")
    return 0
end

function line_span(start::Int, len::Int)
    return len == 0 ? Set{Int}() : Set(start:(start + len - 1))
end

function doc_line_ranges(src::AbstractString)
    ranges = UnitRange{Int}[]
    isempty(src) && return ranges
    tree = parse_tree(src)
    function walk(node)
        if kind(node) == K"doc"
            for i in 1:numchildren(node)
                child = node[i]
                kind(child) == K"string" || continue
                r = byte_range(child)
                push!(ranges, line_of(src, Int(first(r))):line_of(src, Int(last(r))))
            end
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return
    end
    walk(tree)
    return ranges
end

function lines_hit_doc(src::AbstractString, lines)
    isempty(lines) && return false
    ranges = doc_line_ranges(src)
    return any(line -> any(r -> line in r, ranges), lines)
end

function merge_base_ref(root::AbstractString)
    try
        return strip(read(`git -C $root merge-base origin/main HEAD`, String))
    catch
        return "origin/main"
    end
end

function show_file(root::AbstractString, path::AbstractString; ref::Union{Nothing, AbstractString} = nothing)
    ref = ref === nothing ? merge_base_ref(root) : String(ref)
    try
        return read(`git -C $root show $(ref):$path`, String)
    catch
        return ""
    end
end

function doc_touch_files(files::Dict{String, Vector{Hunk}}, read_new, read_old)
    for path in keys(files)
        startswith(path, "docs/") && return true
    end
    for (path, hunks) in files
        endswith(path, ".jl") || continue
        new_lines = Set{Int}()
        old_lines = Set{Int}()
        for h in hunks
            union!(new_lines, line_span(h.newstart, h.newlen))
            union!(old_lines, line_span(h.oldstart, h.oldlen))
        end
        if lines_hit_doc(read_new(path), new_lines) || lines_hit_doc(read_old(path), old_lines)
            return true
        end
    end
    return false
end

function doc_touch(root::AbstractString)
    base = merge_base_ref(root)
    return doc_touch_files(
        parse_diff(git_diff(root)),
        path -> isfile(joinpath(root, path)) ? read(joinpath(root, path), String) : "",
        path -> show_file(root, path; ref = base),
    )
end

function percent_decode(s::AbstractString)
    bytes = UInt8[]
    i = 1
    while i <= ncodeunits(s)
        if codeunit(s, i) == UInt8('%') && i + 2 <= ncodeunits(s)
            h1, h2 = s[i + 1], s[i + 2]
            if isxdigit(h1) && isxdigit(h2)
                push!(bytes, Base.parse(UInt8, string(h1, h2), base = 16))
                i += 3
                continue
            end
        end
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

function link_target(raw::AbstractString)
    t = strip(raw)
    if startswith(t, "<") && endswith(t, ">")
        t = t[2:(end - 1)]
    end
    m = match(r"^(\S+)(?:\s+[\"'].+[\"'])?\s*$", t)
    t = m === nothing ? t : m.captures[1]
    t = first(split(t, '#'; limit = 2))
    t = first(split(t, '?'; limit = 2))
    return strip(t)
end

function local_link_miss(root::AbstractString, file::AbstractString, target::AbstractString)
    t = link_target(target)
    isempty(t) && return nothing
    startswith(t, "@") && return nothing
    if occursin("://", t)
        m = match(r"^https?://github\.com/yamanori99/DistSSHRun\.jl/(blob|tree)/main/(.+)$", t)
        m === nothing && return nothing
        path = percent_decode(m.captures[2])
        full = joinpath(root, path)
        kind = m.captures[1]
        ok = kind == "blob" ? isfile(full) : (isdir(full) || isfile(full))
        return ok ? nothing : path
    end
    startswith(t, "mailto:") && return nothing
    full = startswith(t, "/") ? joinpath(root, t[2:end]) : normpath(joinpath(root, dirname(file), t))
    return (isfile(full) || isdir(full)) ? nothing : t
end

function spec_lower(spec::Pkg.Types.VersionSpec)
    isempty(spec.ranges) && die("empty version spec")
    return minimum(r.lower for r in spec.ranges)
end

function stdlib_compat_errors(proj::AbstractDict, stdlib_versions::Dict{String, VersionNumber})
    errs = String[]
    deps = get(proj, "deps", Dict{String, Any}())
    compat = get(proj, "compat", Dict{String, Any}())
    haskey(compat, "julia") || return ["compat.julia missing"]
    julia_spec = Pkg.Types.semver_spec(String(compat["julia"]))
    julia_lower = spec_lower(julia_spec)
    julia_patch_free = julia_lower.n < 3 || julia_lower.t[3] == 0
    for name in sort!(collect(keys(deps)))
        haskey(stdlib_versions, name) || continue
        haskey(compat, name) || (push!(errs, "$name: stdlib dep has no [compat]"); continue)
        spec = Pkg.Types.semver_spec(String(compat[name]))
        ver = stdlib_versions[name]
        if !(ver in spec)
            push!(errs, "$name: this Julia's stdlib is $ver, outside [compat] $(compat[name])")
        end
        if julia_patch_free && endswith(name, "_jll")
            lower = spec_lower(spec)
            if lower.n >= 3 && lower.t[3] != 0
                push!(
                    errs,
                    "$name: [compat] $(compat[name]) starts at patch $(Int(lower.t[3])). julia $(compat["julia"]) includes $(Int(julia_lower.t[1])).$(Int(julia_lower.t[2])).0, whose stdlib may be older. Use a two-component bound, or raise julia to a patch.",
                )
            end
        end
    end
    return errs
end

function stdlib_compat_errors(root::AbstractString)
    proj = TOML.parsefile(joinpath(root, "Project.toml"))
    versions = Dict{String, VersionNumber}()
    deps = get(proj, "deps", Dict{String, Any}())
    for name in keys(deps)
        p = joinpath(Sys.STDLIB, name, "Project.toml")
        isfile(p) || continue
        versions[name] = VersionNumber(TOML.parsefile(p)["version"])
    end
    return stdlib_compat_errors(proj, versions)
end

function lint_stdlib_compat(root::AbstractString)
    n = 0
    for err in stdlib_compat_errors(root)
        println(stderr, "lint: Project.toml: ", err)
        n += 1
    end
    return n
end

function pr_template_errors(src::AbstractString)
    need = Set(["Summary"])
    seen = Set{String}()
    errs = String[]
    in_fence = false
    for (i, line) in enumerate(eachsplit(src, '\n'; keepempty = true))
        if startswith(line, "```")
            in_fence = !in_fence
            continue
        end
        in_fence && continue
        if startswith(line, "# ")
            push!(errs, "$i: title heading")
        end
        if startswith(line, "## Checklist") || occursin(r"^- \[[ xX]\]", line)
            push!(errs, "$i: checklist")
        end
        m = match(r"^## ([A-Za-z]+)\s*$", line)
        m === nothing && continue
        push!(seen, m.captures[1])
    end
    for name in sort!(collect(setdiff(need, seen)))
        push!(errs, "missing ## $name")
    end
    return errs
end

function bullet_item(line::AbstractString)
    m = match(r"^[-*+] (.*)$", line)
    m === nothing && return nothing
    item = strip(m.captures[1])
    if startswith(item, "`") && endswith(item, "`") && length(item) >= 2
        item = item[2:(end - 1)]
    end
    return item
end

function file_list_errors(body::AbstractString, paths)
    pathset = Set(filter(!isempty, paths))
    length(pathset) < 2 && return String[]
    errs = String[]
    run = String[]
    fence = String[]
    in_fence = false
    function note(items)
        filtered = filter(!isempty, items)
        if Set(filtered) == pathset
            push!(errs, "file list")
        end
        return
    end
    function flush_run()
        note(run)
        empty!(run)
        return
    end
    for line in eachsplit(body, '\n'; keepempty = true)
        if startswith(line, "```")
            if in_fence
                note(fence)
                empty!(fence)
                in_fence = false
            else
                flush_run()
                in_fence = true
            end
            continue
        end
        if in_fence
            push!(fence, strip(line))
            continue
        end
        item = bullet_item(line)
        if item !== nothing
            push!(run, item)
        elseif !isempty(strip(line))
            flush_run()
        end
    end
    in_fence ? note(fence) : flush_run()
    return unique(errs)
end

function unfenced_lines(text::AbstractString)
    lines = collect(eachsplit(text, '\n'; keepempty = true))
    out = Tuple{Int, String}[]
    in_fence = false
    for (i, line) in enumerate(lines)
        if startswith(strip(line), "```")
            in_fence = !in_fence
            continue
        end
        in_fence || push!(out, (i, line))
    end
    return out
end

function has_markdown_table_outside_fences(text::AbstractString)
    for (_, line) in unfenced_lines(text)
        startswith(strip(line), "|") && return true
    end
    return false
end

function has_inline_command_outside_fences(text::AbstractString)
    for (_, line) in unfenced_lines(text)
        occursin(r"`[^`\n]+`", line) && return true
    end
    return false
end

function section_heading_outside_fences(body::AbstractString, hdr::AbstractString)
    h = strip(hdr)
    for (_, line) in unfenced_lines(body)
        s = strip(line)
        (s == h || (startswith(line, h) && length(s) <= length(h) + 2)) && return true
    end
    return false
end

function testing_format_errors(text::AbstractString)
    errs = String[]
    if isempty(strip(text))
        push!(errs, "Testing section empty")
        return errs
    end
    if has_markdown_table_outside_fences(text)
        push!(errs, "Testing uses a markdown table")
        return errs
    end
    lines = collect(eachsplit(text, '\n'; keepempty = true))
    env_lines = Int[]
    for (i, line) in unfenced_lines(text)
        if testing_has_env_line(line) && !isempty(strip(line))
            push!(env_lines, i)
        end
    end
    if isempty(env_lines)
        line = 1
        for (i, ln) in unfenced_lines(text)
            if !isempty(strip(ln))
                line = i
                break
            end
        end
        push!(errs, "$line: Testing environment line (OS/arch, Julia, trailing period)")
        return errs
    end
    for (idx, env_i) in enumerate(env_lines)
        stop = idx < length(env_lines) ? env_lines[idx + 1] - 1 : length(lines)
        segment = join(lines[env_i:stop], '\n')
        if !has_inline_command_outside_fences(segment)
            push!(errs, "$env_i: Testing command in a code span")
        elseif !occursin(r"(?m)^```text\s*$", segment)
            push!(errs, "$env_i: Testing ```text output fence")
        end
    end
    return unique(errs)
end

function pr_body_errors(body::AbstractString, paths)
    errs = pr_template_errors(body)
    append!(errs, file_list_errors(body, paths))
    if testing_section_present(body)
        append!(errs, testing_format_errors(section_named_text(body, "Testing")))
    end
    append!(errs, excuse_word_errors(section_named_text(body, "Testing")))
    append!(errs, excuse_word_errors(section_named_text(body, "Risk")))
    return errs
end

function testing_section_present(body::AbstractString)
    return section_heading_outside_fences(body, "## Testing")
end

function markdown_section_text(body::AbstractString, hdr::AbstractString)
    lines = collect(eachsplit(body, '\n'; keepempty = true))
    in_section = false
    in_fence = false
    parts = String[]
    for line in lines
        if startswith(line, "```")
            in_section && push!(parts, line)
            in_fence = !in_fence
            continue
        end
        if in_fence
            in_section && push!(parts, line)
            continue
        end
        if startswith(line, "## ")
            if in_section
                break
            end
            in_section = startswith(line, hdr) && length(line) <= length(hdr) + 2
            continue
        end
        in_section && push!(parts, line)
    end
    return join(parts, '\n')
end

function testing_section_text(body::AbstractString)
    return markdown_section_text(body, "## Testing")
end

function testing_has_env_markers(text::AbstractString)
    return occursin(r"(?i)\bjulia\b", text)
end

function testing_has_env_line(text::AbstractString)
    return occursin(
        r"(?im)^[^\n]*\b(arm64|aarch64|x86_64|x64|amd64|i686|riscv64)\b[^\n]*\bjulia\b[^\n]*\.\s*$",
        text,
    )
end

function has_generative_tool_line(body::AbstractString)
    return occursin(r"(?im)^generative tool:", body)
end

function has_made_with_footer(body::AbstractString)
    return occursin(r"(?im)^made with \[?[^\]\n]+\]?(\([^)\n]*\))?\s*$", body)
end

function utc_datetime(s::AbstractString)
    m = match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})?", strip(s))
    m === nothing && return nothing
    t = DateTime(
        Base.parse(Int, m.captures[1]),
        Base.parse(Int, m.captures[2]),
        Base.parse(Int, m.captures[3]),
        Base.parse(Int, m.captures[4]),
        Base.parse(Int, m.captures[5]),
        Base.parse(Int, m.captures[6]),
    )
    zone = m.captures[7]
    if zone !== nothing && zone != "Z"
        sign = zone[1] == '-' ? -1 : 1
        t -= Minute(sign * (Base.parse(Int, zone[2:3]) * 60 + Base.parse(Int, zone[5:6])))
    end
    return t
end

function commit_newer_than_edit(committed::AbstractString, edited::AbstractString)
    c = utc_datetime(committed)
    e = utc_datetime(edited)
    (c === nothing || e === nothing) && return false
    return c > e
end

function pr_body_hints(
        body::AbstractString,
        env_example::AbstractString,
        committed_at::AbstractString = "",
        edited_at::AbstractString = "",
    )
    hints = String[]
    if commit_newer_than_edit(committed_at, edited_at)
        push!(hints, "update the PR body (a commit is newer than the last edit)")
    end
    if has_generative_tool_line(body) && has_made_with_footer(body)
        push!(hints, "duplicate AI attribution (Generative tool and a Made with footer)")
    end
    if testing_section_present(body)
        txt = testing_section_text(body)
        if !testing_has_env_markers(txt)
            ex = strip(env_example)
            if isempty(ex)
                push!(hints, "add the OS to ## Testing")
            else
                push!(hints, "add env to ## Testing ($ex)")
            end
        end
    end
    return hints
end

function pr_body_hints_main(
        body_file::AbstractString,
        env_example::AbstractString,
        committed_at::AbstractString = "",
        edited_at::AbstractString = "",
    )
    for hint in pr_body_hints(read(body_file, String), env_example, committed_at, edited_at)
        println(hint)
    end
    return 0
end

function pr_body_main(paths_file::AbstractString, body_file::AbstractString)
    paths = filter(!isempty, readlines(paths_file))
    errs = pr_body_errors(read(body_file, String), paths)
    for err in errs
        println(stderr, "pr body: ", err)
    end
    isempty(errs) || exit(1)
    return 0
end

function coderabbit_tone_errors(src::AbstractString)
    lines = collect(eachsplit(src, '\n'; keepempty = true))
    idx = findfirst(line -> startswith(line, "tone_instructions:"), lines)
    idx === nothing && return ["tone_instructions missing"]
    line = lines[idx]
    text = if occursin(r":\s*[>|]\s*$", line)
        parts = String[]
        i = idx + 1
        while i <= length(lines)
            nxt = lines[i]
            (startswith(nxt, " ") || startswith(nxt, "\t")) || break
            push!(parts, strip(nxt))
            i += 1
        end
        join(filter(!isempty, parts), " ")
    else
        m = match(r"^tone_instructions:\s*(?:\"(.*)\"|'(.*)'|(\S.*?))\s*$", line)
        m === nothing && return ["tone_instructions is not a string"]
        something(m.captures[1], m.captures[2], m.captures[3], "")
    end
    length(text) <= 250 && return String[]
    return ["tone_instructions is $(length(text)) characters. The limit is 250"]
end

function docs_static(root::AbstractString)
    n = 0
    template_path = joinpath(root, ".github", "pull_request_template.md")
    if isfile(template_path)
        for err in pr_template_errors(read(template_path, String))
            println(stderr, "docs: .github/pull_request_template.md: $(err)")
            n += 1
        end
    else
        println(stderr, "docs: .github/pull_request_template.md: missing")
        n += 1
    end
    coderabbit = joinpath(root, ".coderabbit.yaml")
    if isfile(coderabbit)
        for err in coderabbit_tone_errors(read(coderabbit, String))
            println(stderr, "docs: .coderabbit.yaml: $(err)")
            n += 1
        end
    end
    for file in readlines(`git -C $root ls-files '*.md'`)
        src = read(joinpath(root, file), String)
        if file != "docs/src/api.md" && startswith(file, "docs/")
            for (i, line) in enumerate(eachsplit(src, '\n'))
                if occursin(r"```@docs|```@autodocs", line)
                    println(stderr, "docs: $(file):$(i): @docs block outside docs/src/api.md")
                    n += 1
                end
            end
        end
        for m in eachmatch(r"(?:\.github/workflows/|actions/workflows/)([A-Za-z0-9_.-]+\.yml)", src)
            name = m.captures[1]
            isfile(joinpath(root, ".github", "workflows", name)) && continue
            println(stderr, "docs: $(file): missing workflow $(name)")
            n += 1
        end
        lines = split(src, '\n'; keepempty = true)
        for (i, line) in enumerate(lines)
            for m in eachmatch(r"\]\(([^)]*)\)", line)
                miss = local_link_miss(root, file, m.captures[1])
                miss === nothing && continue
                println(stderr, "docs: $(file):$(i): missing path $(miss)")
                n += 1
            end
            m = match(r"^\[[^\]]+\]:\s+(\S+)", line)
            m === nothing && continue
            miss = local_link_miss(root, file, m.captures[1])
            miss === nothing && continue
            println(stderr, "docs: $(file):$(i): missing path $(miss)")
            n += 1
        end
    end
    return n
end

const RUNTESTS_ALLOW = Set(
    [
        "integration/cli/project_child.jl",
        "support.jl",
        "support/leak_guard.jl",
        "support/_common.jl",
        "support/parallel_common.jl",
    ]
)

function runtests_allowlisted(rel::AbstractString, prefix::AbstractString)
    rel in RUNTESTS_ALLOW && return true
    startswith(rel, prefix * "support/") && return true
    return occursin("/fixtures/", "/" * rel)
end

function string_literal_value(node)
    kind(node) == K"string" || return nothing
    txt = sourcetext(node)
    startswith(txt, "\"") && endswith(txt, "\"") || return nothing
    return txt[2:(end - 1)]
end

function join_test_rel(prefix::AbstractString, suffix::AbstractString)
    if isempty(prefix)
        return replace(normpath(suffix), '\\' => '/')
    end
    base = rstrip(replace(prefix, '\\' => '/'), '/')
    return replace(normpath(base * "/" * suffix), '\\' => '/')
end

function runtest_rel_from_joinpath(node, prefix::AbstractString)
    kind(node) == K"call" || return nothing
    numchildren(node) < 2 && return nothing
    head = node[1]
    kind(head) == K"Identifier" && sourcetext(head) == "joinpath" || return nothing
    parts = String[]
    for i in 2:numchildren(node)
        arg = node[i]
        if kind(arg) == K"Identifier" && sourcetext(arg) == "@__DIR__"
            continue
        end
        v = string_literal_value(arg)
        v === nothing && return nothing
        push!(parts, v)
    end
    isempty(parts) && return nothing
    rel = join(parts, '/')
    if !isempty(prefix)
        return join_test_rel(prefix, rel)
    elseif startswith(rel, "unit/") || startswith(rel, "integration/")
        return join_test_rel("", rel)
    end
    return nothing
end

function runtests_reachable(prefix::AbstractString, rt::AbstractString, tdir::AbstractString)
    raw = runtests_includes(read(rt, String), prefix)
    incl = Set(join_test_rel("", rel) for rel in raw)
    queue = collect(incl)
    prefix_norm = join_test_rel("", prefix)
    while !isempty(queue)
        rel = popfirst!(queue)
        startswith(rel, prefix_norm) || continue
        suffix = rel[(length(prefix_norm) + 1):end]
        path = normpath(joinpath(tdir, suffix))
        isfile(path) || continue
        relbase = dirname(suffix)
        sub_prefix =
            prefix_norm * (isempty(relbase) || relbase == "." ? "" : replace(relbase, '\\' => '/') * "/")
        for child in runtests_includes(read(path, String), sub_prefix)
            child_rel = join_test_rel("", child)
            child_rel in incl && continue
            push!(incl, child_rel)
            push!(queue, child_rel)
        end
    end
    return incl
end

function runtests_includes(src::AbstractString, prefix::AbstractString)
    out = Set{String}()
    tree = parse_tree(src)
    function walk(node)
        if kind(node) == K"call"
            if numchildren(node) >= 2
                head = node[1]
                if kind(head) == K"Identifier" && sourcetext(head) == "_runtest_include"
                    rel = string_literal_value(node[2])
                    if rel !== nothing
                        push!(out, isempty(prefix) ? join_test_rel("", rel) : join_test_rel(prefix, rel))
                    end
                elseif kind(head) == K"Identifier" && sourcetext(head) == "include"
                    numchildren(node) >= 2 || return nothing
                    arg = node[2]
                    if kind(arg) == K"call"
                        rel = runtest_rel_from_joinpath(arg, prefix)
                        rel !== nothing && push!(out, rel)
                    elseif (v = string_literal_value(arg)) !== nothing && endswith(v, ".jl")
                        if !isempty(prefix)
                            push!(out, join_test_rel(prefix, v))
                        else
                            push!(out, join_test_rel("", v))
                        end
                    end
                end
            end
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return nothing
    end
    walk(tree)
    for m in eachmatch(r"include\(joinpath\(@__DIR__,\s*((?:\"[^\"]+\",\s*)*\"[^\"]+\")\s*\)", src)
        parts = String[c.captures[1] for c in eachmatch(r"\"([^\"]+)\"", m.captures[1])]
        isempty(parts) && continue
        rel = join(parts, '/')
        if !isempty(prefix)
            push!(out, prefix * rel)
        elseif startswith(rel, "unit/") || startswith(rel, "integration/")
            push!(out, rel)
        end
    end
    for m in eachmatch(r"include\(\"([^\"]+\.jl)\"\)", src)
        rel = String(m.captures[1])
        !isempty(prefix) && push!(out, prefix * rel)
    end
    return out
end

function lint_runtests(root::AbstractString)
    n = 0
    main = read(joinpath(root, "test", "runtests.jl"), String)
    included = runtests_includes(main, "")
    test_root = joinpath(root, "test")
    for (dir, _, files) in walkdir(test_root)
        for file in files
            endswith(file, ".jl") || continue
            rel = replace(relpath(joinpath(dir, file), test_root), '\\' => '/')
            (startswith(rel, "unit/") || startswith(rel, "integration/")) || continue
            runtests_allowlisted(rel, "") && continue
            rel in included && continue
            println(stderr, "lint: test/$(rel) is not listed in test/runtests.jl")
            n += 1
        end
    end
    for pkg in ("DistSSHBase", "DistSSHUp", "DistSSHShip", "DistSSHHeartbeat")
        rt = joinpath(root, "lib", pkg, "test", "runtests.jl")
        isfile(rt) || continue
        prefix = "lib/" * pkg * "/test/"
        tdir = joinpath(root, "lib", pkg, "test")
        incl = runtests_reachable(prefix, rt, tdir)
        for (dir, _, files) in walkdir(tdir)
            for file in files
                endswith(file, ".jl") || continue
                rel = replace(relpath(joinpath(dir, file), tdir), '\\' => '/')
                rel == "runtests.jl" && continue
                full = prefix * rel
                runtests_allowlisted(full, prefix) && continue
                full in incl && continue
                occursin("/fixtures/", full) && continue
                endswith(rel, "support.jl") && continue
                endswith(rel, "helpers.jl") && continue
                rel == "e2e.jl" && continue
                rel == "shared_tempdir.jl" && continue
                println(stderr, "lint: $(full) is not included from lib/$(pkg)/test/runtests.jl")
                n += 1
            end
        end
    end
    short_src = read(joinpath(root, "test", "support", "_common.jl"), String)
    paths, ok = short_skip_paths_from_common(short_src)
    if !ok
        println(stderr, "lint: test/support/_common.jl: _distsshrun_short_skip_paths() not found")
        n += 1
    else
        for path in paths
            for (i, line) in enumerate(split(short_src, '\n'))
                occursin("\"$(path)\"", line) || continue
                if !occursin('#', line)
                    println(stderr, "lint: short-skip entry $(path) needs an end-of-line reason comment (line $(i))")
                    n += 1
                end
                break
            end
        end
    end
    return n
end

function short_skip_paths_from_common(src::AbstractString)
    tree = parse_tree(src)
    found = Ref(false)
    paths = String[]
    function function_def_name(node)
        kind(node) == K"function" || return nothing
        numchildren(node) < 1 && return nothing
        sig = node[1]
        kind(sig) == K"call" || return nothing
        numchildren(sig) < 1 && return nothing
        head = sig[1]
        kind(head) == K"Identifier" || return nothing
        return sourcetext(head)
    end
    function tuple_string_paths(node)
        if kind(node) == K"tuple"
            for i in 1:numchildren(node)
                v = string_literal_value(node[i])
                v === nothing || push!(paths, v)
            end
            return
        end
        for i in 1:numchildren(node)
            tuple_string_paths(node[i])
        end
        return
    end
    function walk(node)
        if function_def_name(node) == "_distsshrun_short_skip_paths"
            found[] = true
            for i in 1:numchildren(node)
                tuple_string_paths(node[i])
            end
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return nothing
    end
    walk(tree)
    return paths, found[]
end


const BANNED_NEW = ("best-effort", "until", "lockstep", "pending", "known failure", "pre-existing")
const CEILING_ID_MATCH = 6
const CEILING_PROCESS_PATTERN = 48
const CEILING_LOCK_CREATE = 7
const CEILING_ENV_DEFAULT = 11
const CEILING_ENV_DEFAULT_TEST = 37
const CEILING_SWALLOWED_CATCH = 141
const CEILING_LOOP_SKIP = 0
const CEILING_PR_REFS = 2
const CEILING_EXCUSE_PHRASES = 25

function tracked_jl(root::AbstractString)
    return filter(p -> endswith(p, ".jl") && !skipped_path(p), readlines(`git -C $root ls-files '*.jl'`))
end

function id_match_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "src/") && return true
    occursin(r"^lib/[^/]+/src/", p) && return true
    return occursin("/fixtures/", p)
end

function ident_leaf(node)
    k = kind(node)
    k == K"Identifier" && return sourcetext(node)
    if k == K"." && numchildren(node) >= 2
        return ident_leaf(node[numchildren(node)])
    end
    return nothing
end

function name_is_idish(s::AbstractString)::Bool
    return occursin(r"(?i)id|token|job|run|leaf|stamp|mark", s)
end

function id_match_call(node, src, path, added, hits)
    kind(node) == K"call" || return
    numchildren(node) >= 2 || return
    fname = ident_leaf(node[1])
    fname === nothing && return
    if fname in ("occursin", "startswith", "endswith", "first")
        for i in 2:numchildren(node)
            id = ident_leaf(node[i])
            id === nothing && continue
            name_is_idish(id) || continue
            node_touches_added(src, node, added) || continue
            a = line_of(src, Int(first(byte_range(node))))
            push!(hits, (path, a, "id-match"))
            return
        end
    end
    return
end

function id_match_ref(node, src, path, added, hits)
    kind(node) == K"ref" || return
    numchildren(node) >= 2 || return
    id = ident_leaf(node[1])
    id === nothing && return
    name_is_idish(id) || return
    idx = node[2]
    is_range = kind(idx) == K":" || (kind(idx) == K"call" && numchildren(idx) >= 2 && sourcetext(idx[2]) == ":")
    is_range || return
    node_touches_added(src, node, added) || return
    a = line_of(src, Int(first(byte_range(node))))
    push!(hits, (path, a, "id-match"))
    return
end

function id_match_shell_line(line::AbstractString)::Bool
    return occursin(r"case[[:space:]].*\*\"\$[A-Za-z_][A-Za-z0-9_]*\"\*", line)
end

function walk_id_match!(node, src, path, added, hits)
    id_match_call(node, src, path, added, hits)
    id_match_ref(node, src, path, added, hits)
    for i in 1:numchildren(node)
        walk_id_match!(node[i], src, path, added, hits)
    end
    return
end

function lint_file_src(root, path, src_for_path)
    if !isempty(root) && !isfile(joinpath(root, path))
        return nothing
    end
    return src_for_path(path)
end

function collect_id_match(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(id_match_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        id_match_path(path) || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        if whole
            for (i, line) in enumerate(split(src, '\n'; keepempty = true))
                id_match_shell_line(line) && push!(hits, (path, i, "id-match"))
            end
        else
            lines = split(src, '\n'; keepempty = true)
            for i in sort!(collect(added))
                1 <= i <= length(lines) || continue
                id_match_shell_line(lines[i]) || continue
                push!(hits, (path, i, "id-match"))
            end
        end
        endswith(path, ".jl") || continue
        walk_id_match!(parse_tree(src), src, path, added, hits)
    end
    return unique(hits)
end

function process_builder_name(node)
    n = defined_function_name(node)
    n === nothing && return false
    return n == "_pkill_pattern!"
end

function walk_process!(node, src, path, added, in_builder, hits)
    if process_builder_name(node)
        for i in 1:numchildren(node)
            walk_process!(node[i], src, path, added, true, hits)
        end
        return
    end
    st = sourcetext(node)
    if !in_builder && kind(node) in (K"vect", K"ref", K"string", K"String")
        if occursin(r"(?i)(?<![A-Za-z])(pkill|pgrep)(?![A-Za-z])", st) && node_touches_added(src, node, added)
            a = line_of(src, Int(first(byte_range(node))))
            push!(hits, (path, a, "process-pattern"))
        end
    end
    if kind(node) in (K"string", K"String") && occursin(r"\[[a-zA-Z]\]", st) &&
            node_touches_added(src, node, added)
        a = line_of(src, Int(first(byte_range(node))))
        push!(hits, (path, a, "process-pattern"))
    end
    for i in 1:numchildren(node)
        walk_process!(node[i], src, path, added, in_builder, hits)
    end
    return
end

function collect_process_pattern(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? tracked_jl(root) : collect(keys(files))
    for path in paths
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        p = replace(path, '\\' => '/')
        startswith(p, "src/") || occursin(r"^lib/[^/]+/src/", p) || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added_set = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added_set) && continue)
        walk_process!(parse_tree(src), src, path, added_set, false, hits)
    end
    return unique(hits)
end

function lock_create_hits(src::AbstractString, path::AbstractString, added)
    hits = Tuple{String, Int, String}[]
    lines = split(src, '\n'; keepempty = true)
    for (i, line) in enumerate(lines)
        m = match(r"isfile\(([^)]+)\)", line)
        m === nothing && continue
        v = strip(m.captures[1])
        occursin(r"(?i)lock|pid", v) || continue
        last = min(i + 40, length(lines))
        for j in (i + 1):last
            occursin(Regex("write\\(\\s*\\Q" * v * "\\E\\s*,"), lines[j]) || continue
            (i in added || j in added) || continue
            push!(hits, (path, i, "lock-create"))
            break
        end
    end
    return hits
end

function collect_lock_create(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? tracked_jl(root) : collect(keys(files))
    for path in paths
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        append!(hits, lock_create_hits(src, path, added))
    end
    return unique(hits)
end

function env_default_src_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "src/") && return true
    return occursin(r"^lib/[^/]+/src/", p)
end

function env_default_line_hit(line::AbstractString)::Bool
    occursin(r"something\(\s*tryparse\s*\(", line) && return true
    occursin(r"tryparse\s*\([^\n]*\)\s*===\s*nothing\s*&&\s*return\s+\S", line) && return true
    occursin(r"tryparse\s*\([^\n]*\)\s*===\s*nothing\s*\?\s*\S", line) && return true
    occursin(r"get\(\s*ENV\s*,\s*\"[^\"]+\"\s*,\s*\"[^\"]+\"\s*\)", line) && return true
    return false
end

function collect_env_default(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(env_default_src_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        env_default_src_path(path) || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        lines = split(src, '\n'; keepempty = true)
        for i in sort!(collect(added))
            1 <= i <= length(lines) || continue
            env_default_line_hit(lines[i]) || continue
            push!(hits, (path, i, "env-default"))
        end
    end
    return unique(hits)
end

function invalid_env_literal(s::AbstractString)::Bool
    s == "0" && return true
    s == "-1" && return true
    isempty(s) && return false
    return tryparse(Float64, s) === nothing
end

function test_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "test/") && return true
    return occursin(r"^lib/[^/]+/test/", p)
end

function collect_env_default_test(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(test_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        test_path(path) || continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        lines = split(src, '\n'; keepempty = true)
        i = 1
        while i <= length(lines)
            line = lines[i]
            m = match(r"withenv\([^)]*\"([^\"]+)\"\s*=>\s*\"([^\"]*)\"", line)
            if m !== nothing && invalid_env_literal(m.captures[2]) && i in added
                has_throws = false
                has_eq = false
                j = i
                while j <= length(lines)
                    occursin("@test_throws", lines[j]) && (has_throws = true)
                    occursin(r"@test\b[^=]*==", lines[j]) && (has_eq = true)
                    occursin(r"\bend\b", lines[j]) && j > i && break
                    j += 1
                    j - i > 40 && break
                end
                if has_eq && !has_throws
                    push!(hits, (path, i, "env-default"))
                end
            end
            i += 1
        end
    end
    return unique(hits)
end

function swallowed_catch_hit(src::AbstractString, node)::Bool
    kind(node) == K"catch" || return false
    st = strip(sourcetext(node))
    body = replace(st, r"^catch(?:\s+\w+)?" => "")
    body = strip(body)
    body = replace(body, r"^\w+\s+isa\s+InterruptException\s*&&\s*rethrow\(\)\s*" => "")
    body = strip(body)
    isempty(body) && return true
    body == "nothing" && return true
    occursin(r"^return\s+\S+$", body) && return true
    lines = [strip(l) for l in eachsplit(body, '\n'; keepempty = false)]
    !isempty(lines) && all(l -> isempty(l) || startswith(l, "#"), lines) && return true
    return false
end

function walk_catch!(node, src, path, added, hits)
    if kind(node) == K"catch" && node_touches_added(src, node, added) && swallowed_catch_hit(src, node)
        a = line_of(src, Int(first(byte_range(node))))
        push!(hits, (path, a, "swallowed-catch"))
    end
    for i in 1:numchildren(node)
        walk_catch!(node[i], src, path, added, hits)
    end
    return
end

function collect_swallowed_catch(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? tracked_jl(root) : collect(keys(files))
    for path in paths
        skipped_path(path) && continue
        startswith(replace(path, '\\' => '/'), ".github/") && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        walk_catch!(parse_tree(src), src, path, added, hits)
    end
    return unique(hits)
end

function loop_skip_line(line::AbstractString)::Bool
    return occursin(r"==\s*\"[^\"]+\"\s*&&\s*continue", line)
end

function loop_skip_reason(src, line::Int)::Bool
    notes = join(comments_on(src, line, line), "\n")
    isempty(issue_numbers(notes)) || return true
    return occursin(r"\"[^\"]+\"", notes)
end

function is_string_eq_cond(node)::Bool
    while kind(node) == K"parens" && numchildren(node) >= 1
        node = node[1]
    end
    kind(node) == K"call" || return false
    numchildren(node) >= 3 || return false
    sourcetext(node[2]) in ("==", "===") || return false
    a, b = node[1], node[3]
    return kind(a) in (K"string", K"String") || kind(b) in (K"string", K"String")
end

function scan_then_continues!(node, src, path, added, if_line, hits)
    k = kind(node)
    k in (K"if", K"for", K"while") && return
    if k == K"continue"
        cl = line_of(src, Int(first(byte_range(node))))
        (cl in added || if_line in added) || return
        loop_skip_reason(src, cl) && return
        loop_skip_reason(src, if_line) && return
        push!(hits, (path, cl, "skip-reasons"))
        return
    end
    for i in 1:numchildren(node)
        scan_then_continues!(node[i], src, path, added, if_line, hits)
    end
    return
end

function walk_if_continue!(node, src, path, added, hits)
    if kind(node) == K"if" && numchildren(node) >= 2 && is_string_eq_cond(node[1])
        if_line = line_of(src, Int(first(byte_range(node))))
        scan_then_continues!(node[2], src, path, added, if_line, hits)
    end
    for i in 1:numchildren(node)
        walk_if_continue!(node[i], src, path, added, hits)
    end
    return
end

function collect_loop_skip(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(test_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        test_path(path) || continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        lines = split(src, '\n'; keepempty = true)
        for i in sort!(collect(added))
            1 <= i <= length(lines) || continue
            loop_skip_line(lines[i]) || continue
            loop_skip_reason(src, i) && continue
            push!(hits, (path, i, "skip-reasons"))
        end
        endswith(path, ".jl") && walk_if_continue!(parse_tree(src), src, path, added, hits)
    end
    return unique(hits)
end

function pr_ref_hit(text::AbstractString)::Bool
    occursin(r"\blockstep\b", text) && return true
    occursin(r"\bPR\s+[0-9]+", text) && return true
    occursin(r"[A-Za-z][A-Za-z0-9_.-]*\s+#\s*[0-9]+", text) && return true
    return false
end

function collect_pr_refs(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? tracked_jl(root) : collect(keys(files))
    for path in paths
        skipped_path(path) && continue
        p = replace(path, '\\' => '/')
        in_src = (startswith(p, "src/") || occursin(r"^lib/[^/]+/src/", p)) && endswith(p, ".jl")
        in_test = test_path(p) && endswith(p, ".jl")
        (in_src || in_test) || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        if in_src
            tree = parse_tree(src)
            function walk_str(node)
                if kind(node) in (K"string", K"String") && node_touches_added(src, node, added)
                    pr_ref_hit(sourcetext(node)) && push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "pr-refs"))
                end
                for i in 1:numchildren(node)
                    walk_str(node[i])
                end
                return
            end
            walk_str(tree)
        end
        if in_test
            for (a, _, text) in comment_tokens(src)
                a in added || continue
                pr_ref_hit(text) || continue
                push!(hits, (path, a, "pr-refs"))
            end
        end
    end
    return unique(hits)
end

function collect_excuse_phrases(root)
    n = 0
    for path in tracked_jl(root)
        skipped_path(path) && continue
        src = read(joinpath(root, path), String)
        endswith(path, ".jl") || continue
        for (_, _, text) in comment_tokens(src)
            hit = banned_hit(text)
            hit === nothing && continue
            hit in BANNED_NEW || continue
            n += 1
        end
    end
    return n
end

function main_ceiling(name::AbstractString)
    text = try
        read(`git show origin/main:scripts/lint/diff_lint.jl`, String)
    catch
        return :unread
    end
    m = match(Regex("const " * name * " = ([0-9]+)"), text)
    m === nothing && return nothing
    return Base.parse(Int, m.captures[1])
end

function check_ceiling(name::AbstractString, measured::Int, constant::Int)
    n = 0
    if measured != constant
        println(stderr, "lint: $(name): measured $(measured), constant $(constant)")
        n += 1
    end
    prev = main_ceiling(name)
    if prev === :unread
        println(stderr, "lint: $(name): could not read the ceiling on origin/main")
        n += 1
    elseif prev !== nothing && constant > prev
        println(stderr, "lint: $(name): constant $(constant) is above origin/main $(prev)")
        n += 1
    end
    return n
end

function report_hits(hits)
    reasons = Dict(
        "id-match" => "substring or slice compare on an id-like name",
        "process-pattern" => "pkill or pgrep pattern",
        "lock-create" => "isfile then write on a lock or pid path",
        "env-default" => "fallback for a missing env value",
        "swallowed-catch" => "catch body drops the error",
        "skip-reasons" => "continue without a reason",
        "pr-refs" => "pull request or lockstep reference",
    )
    n = 0
    for (path, line, rule) in hits
        why = get(reasons, rule, "")
        msg = isempty(why) ? rule : "$(rule): $(why)"
        println(stderr, "lint: $(path):$(line): $(msg)")
        n += 1
    end
    return n
end

function lint_mode_dual(root, files, src_for_path, collect_fn, ceiling_name, ceiling)
    added = collect_fn(root, files, src_for_path; whole = false)
    n = report_hits(added)
    whole = collect_fn(root, files, src_for_path; whole = true)
    n += check_ceiling(ceiling_name, length(whole), ceiling)
    return n
end

function markdown_removed_names(src::AbstractString)
    names = String[]
    for line in eachsplit(src, '\n'; keepempty = false)
        occursin(r"removed|no longer", line) || continue
        head = first(split(line, r"in favor of|replaced by"; limit = 2))
        for m in eachmatch(r"`([^`]+)`", head)
            tok = m.captures[1]
            occursin(r"^[A-Za-z_][A-Za-z0-9_!]*$", tok) || continue
            push!(names, tok)
        end
    end
    return unique(names)
end

function grep_token(root, tok, dirs)
    hits = String[]
    pat = "(^|[^A-Za-z0-9_])" * replace(tok, r"([\\^$.|?*+()\[\]{}])" => s"\\\1") * raw"(!)?([^A-Za-z0-9_]|$)"
    for dir in dirs
        cmd = Cmd(`git -C $root grep -n -E -- $pat -- $dir`; ignorestatus = true)
        out = IOBuffer()
        err = IOBuffer()
        proc = run(pipeline(cmd; stdout = out, stderr = err); wait = true)
        if proc.exitcode == 2
            msg = strip(String(take!(err)))
            error("git grep failed for $(tok) in $(dir): $(msg)")
        end
        proc.exitcode == 1 && continue
        for line in eachsplit(String(take!(out)), '\n'; keepempty = false)
            push!(hits, line)
        end
    end
    return hits
end

function lint_removed_names(root::AbstractString, extra_root::AbstractString = "")
    n = 0
    diff = read(`git -C $root diff -U0 --no-color origin/main...HEAD -- changelog.d`, String)
    files = parse_diff(diff)
    names = String[]
    for (path, hunks) in files
        full = joinpath(root, path)
        isfile(full) || continue
        src = read(full, String)
        added = added_lines(hunks)
        lines = split(src, '\n'; keepempty = true)
        buf = IOBuffer()
        for i in sort!(collect(added))
            1 <= i <= length(lines) && println(buf, lines[i])
        end
        append!(names, markdown_removed_names(String(take!(buf))))
    end
    names = unique(names)
    for tok in names
        for hit in grep_token(root, tok, ("README.md", "README.ja.md", "docs", "src"))
            println(stderr, "lint: removed name $(tok) still in $(hit)")
            n += 1
        end
        if !isempty(extra_root)
            for hit in grep_token(extra_root, tok, ("src", "test", "README.md", "README.ja.md", "docs"))
                println(stderr, "lint: removed name $(tok) still in downstream $(hit)")
                n += 1
            end
        end
    end
    return n
end

function section_named_text(body::AbstractString, name::AbstractString)
    return markdown_section_text(body, "## " * name)
end

function has_main_run_url(text::AbstractString)::Bool
    occursin(r"https://github\.com/[^/]+/[^/]+/actions/runs/[0-9]+", text) || return false
    return occursin(r"\bmain\b", text)
end

function excuse_word_errors(section::AbstractString)
    errs = String[]
    lines = collect(eachsplit(section, '\n'; keepempty = true))
    paras = Tuple{Int, String}[]
    buf = String[]
    start = 1
    function flush!(s, b)
        isempty(b) && return
        push!(paras, (s, join(b, '\n')))
        empty!(b)
        return
    end
    for (i, line) in enumerate(lines)
        if isempty(strip(line))
            flush!(start, buf)
            start = i + 1
        else
            isempty(buf) && (start = i)
            push!(buf, line)
        end
    end
    flush!(start, buf)
    patterns = (
        (r"(?<![A-Za-z])known(?![A-Za-z])"i, "known"),
        (r"pre-existing"i, "pre-existing"),
        (r"(?<![A-Za-z])unrelated(?![A-Za-z])"i, "unrelated"),
        (r"(?<![A-Za-z])flaky(?![A-Za-z])"i, "flaky"),
        (r"left to CI"i, "left to CI"),
        (r"(?<![A-Za-z])pending(?![A-Za-z])"i, "pending"),
    )
    for (s, text) in paras
        has_main_run_url(text) && continue
        for (re, word) in patterns
            m = match(re, text)
            m === nothing && continue
            rel = count(==('\n'), text[1:max(1, m.offset)])
            push!(errs, "$(s + rel): $(word)")
        end
    end
    return errs
end

function lint_id_match(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_id_match, "CEILING_ID_MATCH", CEILING_ID_MATCH)
end

function lint_process_pattern(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_process_pattern, "CEILING_PROCESS_PATTERN", CEILING_PROCESS_PATTERN)
end

function lint_lock_create(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_lock_create, "CEILING_LOCK_CREATE", CEILING_LOCK_CREATE)
end

function lint_env_default(root, files, src_for_path)
    n = lint_mode_dual(root, files, src_for_path, collect_env_default, "CEILING_ENV_DEFAULT", CEILING_ENV_DEFAULT)
    n += lint_mode_dual(root, files, src_for_path, collect_env_default_test, "CEILING_ENV_DEFAULT_TEST", CEILING_ENV_DEFAULT_TEST)
    return n
end

function lint_swallowed_catch(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_swallowed_catch, "CEILING_SWALLOWED_CATCH", CEILING_SWALLOWED_CATCH)
end

function lint_pr_refs(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_pr_refs, "CEILING_PR_REFS", CEILING_PR_REFS)
end

function lint_excuse_ceiling(root)
    return check_ceiling("CEILING_EXCUSE_PHRASES", collect_excuse_phrases(root), CEILING_EXCUSE_PHRASES)
end

const GATE_LINT_NAMES = (
    "banned-words",
    "agents-md",
    "skip-reasons",
    "new-comments",
    "stdlib-compat",
    "ssh-argv",
    "drive-hooks",
    "aqua-run",
    "runtests",
    "id-match",
    "process-pattern",
    "lock-create",
    "env-default",
    "swallowed-catch",
    "pr-refs",
)

function lint_diff_mode(mode, root, files, src_for)
    mode == "banned-words" && return lint_banned(root, files) + lint_excuse_ceiling(root)
    mode == "agents-md" && return lint_agents(root, files)
    mode == "skip-reasons" && return lint_skips(root, files, src_for)
    mode == "new-comments" && return lint_new_comments(root, files)
    mode == "ssh-argv" && return lint_ssh_argv(root, files, src_for)
    mode == "drive-hooks" && return lint_drive_hooks(root, files, src_for)
    mode == "aqua-run" && return lint_aqua_run(root, files)
    mode == "id-match" && return lint_id_match(root, files, src_for)
    mode == "process-pattern" && return lint_process_pattern(root, files, src_for)
    mode == "lock-create" && return lint_lock_create(root, files, src_for)
    mode == "env-default" && return lint_env_default(root, files, src_for)
    mode == "swallowed-catch" && return lint_swallowed_catch(root, files, src_for)
    mode == "pr-refs" && return lint_pr_refs(root, files, src_for)
    return die("unknown mode $(mode)")
end

function lint_all(root)
    files = parse_diff(git_diff(root))
    src_for = path -> begin
        p = joinpath(root, path)
        isfile(p) || return ""
        read(p, String)
    end
    n = 0
    for mode in GATE_LINT_NAMES
        n += if mode == "stdlib-compat"
            lint_stdlib_compat(root)
        elseif mode == "runtests"
            lint_runtests(root)
        else
            lint_diff_mode(mode, root, files, src_for)
        end
    end
    n == 0 || exit(1)
    return 0
end

function main(args)
    if length(args) == 3 && args[1] == "pr-body"
        return pr_body_main(args[2], args[3])
    end
    if length(args) >= 1 && args[1] == "removed-names"
        extra = length(args) >= 2 ? args[2] : ""
        lint_removed_names(repo_root(), extra) == 0 || exit(1)
        return 0
    end
    if length(args) in 3:5 && args[1] == "pr-body-hints"
        committed = length(args) >= 4 ? args[4] : ""
        edited = length(args) >= 5 ? args[5] : ""
        return pr_body_hints_main(args[2], args[3], committed, edited)
    end
    if length(args) != 1
        die("usage: diff_lint.jl <all|banned-words|agents-md|skip-reasons|new-comments|stdlib-compat|ssh-argv|drive-hooks|aqua-run|runtests|doc-touch|docs-static|self-test|pr-body|pr-body-hints>")
    end
    mode = args[1]
    mode == "self-test" && return self_test()
    root = repo_root()
    mode == "all" && return lint_all(root)
    if mode == "runtests"
        lint_runtests(root) == 0 || exit(1)
        return 0
    elseif mode == "doc-touch"
        println(doc_touch(root) ? "yes" : "no")
        return 0
    elseif mode == "docs-static"
        docs_static(root) == 0 || exit(1)
        return 0
    elseif mode == "stdlib-compat"
        lint_stdlib_compat(root) == 0 || exit(1)
        return 0
    end
    files = parse_diff(git_diff(root))
    src_for = path -> begin
        p = joinpath(root, path)
        isfile(p) || return ""
        read(p, String)
    end
    n = lint_diff_mode(mode, root, files, src_for)
    n == 0 || exit(1)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
