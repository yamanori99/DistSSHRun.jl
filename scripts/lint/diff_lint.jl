# Diff lints. JuliaSyntax comes from `.github/runic` (a direct dependency).
# Do not Pkg.add, and do not load a copy from the running process.
#
#   julia --project=.github/runic --startup-file=no scripts/lint/diff_lint.jl <mode>
#   modes: all, banned-words, agents-md, skip-reasons, new-comments, stdlib-compat, self-test, pr-body

using Dates
using Distributed
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
    p = replace(String(path), '\\' => '/')
    startswith(p, "scripts/lint/fixtures/") && return false
    return startswith(p, "scripts/lint/")
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
        n += report_hits(collect_loop_skip(root, files, src_for_path; whole = false), root)
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

function lint_fixture_suite!(root::AbstractString)
    src_for = path -> read(joinpath(root, path), String)
    function file_hunks(rel)
        src = src_for(rel)
        nlines = count(==('\n'), src) + 1
        return Dict(rel => [Hunk(0, 0, 1, nlines, String[])])
    end
    split_rel = "scripts/lint/fixtures/evasion/split_string.jl"
    isempty(collect_split_token(root, file_hunks(split_rel), src_for; whole = false)) &&
        die("self-test: fixture split-token evasion")
    clean_rel = "scripts/lint/fixtures/clean/prose_string.jl"
    !isempty(collect_split_token(root, file_hunks(clean_rel), src_for; whole = false)) &&
        die("self-test: fixture split-token clean")
    proc_rel = "scripts/lint/fixtures/evasion/pkill_cmd.jl"
    isempty(collect_process_pattern(root, file_hunks(proc_rel), src_for; whole = false)) &&
        die("self-test: fixture process-pattern evasion")
    tick_rel = "scripts/lint/fixtures/evasion/pkill_backtick.jl"
    isempty(collect_process_pattern(root, file_hunks(tick_rel), src_for; whole = false)) &&
        die("self-test: fixture process-pattern backtick evasion")
    doc_rel = "scripts/lint/fixtures/clean/doc_pkill.jl"
    !isempty(collect_process_pattern(root, file_hunks(doc_rel), src_for; whole = false)) &&
        die("self-test: fixture process-pattern clean")
    withenv_bad = "scripts/lint/fixtures/evasion/withenv_test_invalid.jl"
    isempty(collect_env_default_test(root, file_hunks(withenv_bad), src_for; whole = false)) &&
        die("self-test: fixture env-default-test evasion")
    mut_rel = "scripts/lint/fixtures/test_mutation/env_write.jl"
    isempty(collect_test_env_mutation(root, file_hunks(mut_rel), src_for; whole = false)) &&
        die("self-test: fixture test-env-mutation evasion")
    for rel in (
            "scripts/lint/fixtures/evasion/pkill_remote_shell.jl",
            "scripts/lint/fixtures/evasion/pkill_which.jl",
            "scripts/lint/fixtures/evasion/pgrep_bracket.jl",
        )
        length(collect_process_pattern(root, file_hunks(rel), src_for; whole = false)) < 1 &&
            die("self-test: fixture process-pattern $(rel)")
    end
    remote = joinpath(root, "src/DistSSHRun/infra/remote.jl")
    remote_src = read(remote, String)
    remote_h = Dict("src/DistSSHRun/infra/remote.jl" => [Hunk(16, 0, 16, 1, String[])])
    length(collect_process_pattern(root, remote_h, _ -> remote_src; whole = false)) >= 1 ||
        die("self-test: remote.jl local pkill must hit process-pattern")
    return
end

function self_test()
    register_lint_rules!(collect(GATE_LINT_NAMES))
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
    any(x -> occursin("add the OS", x) || startswith(x, "add env"), pr_body_hints(lower_env, "")) &&
        die("self-test: pr body lowercase env")
    noenv = "## Summary\n\n## Testing\n\n`./scripts/check.sh` passed.\n"
    env_hints = pr_body_hints(noenv, "Linux x86_64, Julia 1.13.4")
    any(x -> x == "add env to ## Testing (Linux x86_64, Julia 1.13.4)", env_hints) ||
        die("self-test: pr body testing env hint $(env_hints)")
    any(x -> startswith(x, "add the OS to ## Testing"), pr_body_hints(noenv, "")) ||
        die("self-test: pr body testing env hint no example")
    with_env = "## Summary\n\n## Testing\n\nEnvironment: Darwin arm64, Julia 1.13.4.\n\nRan check.\n"
    any(x -> occursin("add the OS", x) || startswith(x, "add env"), pr_body_hints(with_env, "")) &&
        die("self-test: pr body testing env ok")
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
    judge_proc = run(ignorestatus(pipeline(`$judge_script`, stdout = judge_buf, stderr = judge_buf)))
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
    length(GATE_LINT_NAMES) == 32 || die("self-test: GATE_LINT_NAMES $(length(GATE_LINT_NAMES))")
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
    ssh_src = "withenv(\"DISTSSH_SSH_OPTS\" => \"-o BatchMode=yes\") do\n    @test true\nend\n"
    isempty(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> ssh_src; whole = false)) ||
        die("self-test: env-default test ssh opts")
    multi_src = "withenv(\n    \"DISTSSH_JOBS\" => \"nope\",\n) do\n    @test x == 1\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 5, String[])]), _ -> multi_src; whole = false)) >= 1 ||
        die("self-test: env-default test multiline withenv")
    split_hit = "s = string(\"DISTSSH_\", \"FOO\")\n"
    length(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> split_hit; whole = false)) >= 1 ||
        die("self-test: split-token hit")
    split_star = "s = \"DISTSSH_\" * \"FOO\"\n"
    length(collect_split_token("", Dict("test/t.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> split_star; whole = false)) >= 1 ||
        die("self-test: split-token star")
    split_ok = "s = string(\"hello\", \" world\")\n"
    isempty(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> split_ok; whole = false)) ||
        die("self-test: split-token prose")
    split_var = "a = \"x\"; s = string(a, \"y\")\n"
    isempty(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 2, 1, String[])]), _ -> split_var; whole = false)) ||
        die("self-test: split-token variable")
    parse_lint_allow_line("ENV[\"X\"] = \"1\" # lint-allow: test-env-mutation -- fixture models a raw ENV write") !== nothing ||
        die("self-test: inline lint-allow")
    allow_inline = "x = 1\nENV[\"X\"] = 1 # lint-allow: split-token -- fixture inline marker only for this line\ny = 2\n"
    !lint_allow_active(allow_inline, 3, "split-token") ||
        die("self-test: inline lint-allow must not suppress next line")
    whole_allow = "# lint-allow: split-token -- whole line marker with a long reason\nx = 1\n"
    lint_allow_active(whole_allow, 2, "split-token") || die("self-test: whole-line allow next line")
    indented_allow = "    # lint-allow: split-token -- indented whole line marker reason\nx = 1\n"
    lint_allow_active(indented_allow, 2, "split-token") || die("self-test: indented whole-line allow")
    later_allow = "x = 1\n# lint-allow: split-token -- second line whole line marker reason\ny = 2\n"
    lint_allow_active(later_allow, 3, "split-token") || die("self-test: line-2 whole-line allow")
    block_allow = "#= # lint-allow: split-token -- block comment must not count here =#\nx = 1\n"
    lint_allow_active(block_allow, 2, "split-token") && die("self-test: block comment allow")
    isempty(comment_allow_markers(block_allow)) || die("self-test: block comment uncounted")
    for wrap in ("sudo", "timeout 5", "env", "nice", "nohup")
        srcw = "run(`$(wrap) pkill -f x`)\n"
        length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> srcw; whole = false)) >= 1 ||
            die("self-test: wrapper $(wrap) pkill")
    end
    tick = "run(`sudo pkill -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> tick; whole = false)) >= 1 ||
        die("self-test: sudo pkill backtick")
    echo_pg = "Cmd([\"echo\", \"pgrep\"])\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> echo_pg; whole = false)) ||
        die("self-test: echo pgrep not a command")
    err_pk = "error(\"pkill failed on host\")\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> err_pk; whole = false)) ||
        die("self-test: error prose pkill")
    shc = "run(`sh -c \"pkill -f x\"`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> shc; whole = false)) >= 1 ||
        die("self-test: sh -c pkill")
    secondw = "run(`sh -c \"echo pkill -f x\"`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> secondw; whole = false)) >= 1 ||
        die("self-test: sh -c second-word pkill")
    chain = "run(`sh -c \"true; pkill -f x\"`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> chain; whole = false)) >= 1 ||
        die("self-test: sh -c chain pkill")
    typed = "Cmd(String[\"pkill\", \"-f\", \"x\"])\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> typed; whole = false)) >= 1 ||
        die("self-test: typed Cmd pkill")
    prod = "s = prod([\"DISTSSH_\", \"FOO\"])\n"
    length(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> prod; whole = false)) >= 1 ||
        die("self-test: split-token prod")
    red = "s = reduce(*, [\"DISTSSH_\", \"FOO\"])\n"
    length(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> red; whole = false)) >= 1 ||
        die("self-test: split-token reduce")
    str_mark = "s = \"# lint-allow: split-token -- not a real marker inside string\"\n"
    lint_allow_active(str_mark, 1, "split-token") && die("self-test: lint-allow inside string literal")
    triple = "s = \"\"\"\n# lint-allow: split-token -- not a real marker inside triple string\n\"\"\"\nnext = 1\n"
    lint_allow_active(triple, 4, "split-token") && die("self-test: lint-allow inside triple string")
    beside = "s = \"hi\" # lint-allow: split-token -- inline beside a string literal here\n"
    length(comment_allow_markers(beside)) == 1 || die("self-test: inline allow beside string must count")
    join_hit = "s = join([\"DISTSSH_\", \"FOO\"])\n"
    length(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> join_hit; whole = false)) >= 1 ||
        die("self-test: split-token join")
    decode_string_literal_chunk("A") == "A" || die("self-test: string_literal chunk")
    lit_tree = parse_tree("const S = \"\\x42\"\n")
    found = Ref(false)
    function walk_lit!(node)
        if kind(node) == K"string" && string_literal_value(node) == "B"
            found[] = true
            return
        end
        for i in 1:numchildren(node)
            walk_lit!(node[i])
        end
        return
    end
    walk_lit!(lit_tree)
    found[] || die("self-test: string_literal \\x node")
    lint_allow_line_malformed("# lint-allow: split-token --") ||
        die("self-test: malformed lint-allow empty reason")
    commented = "# EnvRow(\"DISTSSH_UNLISTED\", \"string\", \"unset\", \"—\", \"gone\")\nEnvRow(\"DISTSSH_JOBS\", \"int >= 1\", \"1\", \"—\", \"jobs\")\n"
    !occursin("DISTSSH_UNLISTED", source_without_full_line_comments(commented)) ||
        die("self-test: commented EnvRow stripped")
    occursin("DISTSSH_JOBS", source_without_full_line_comments(commented)) ||
        die("self-test: live EnvRow kept")
    job_bad = "withenv(\"DISTSSH_JOB_ID\" => \"bad!\") do\n    @test x == 1\nend\n"
    length(collect_env_default_test(repo_root(), Dict("test/runtests.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> job_bad; whole = false)) >= 1 ||
        die("self-test: env-default job id grammar")
    job_ok = "withenv(\"DISTSSH_JOB_ID\" => \"job-1\") do\n    @test x == 1\nend\n"
    isempty(collect_env_default_test(repo_root(), Dict("test/runtests.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> job_ok; whole = false)) ||
        die("self-test: env-default job id charset")
    seti = "setindex!(ENV, \"1\", \"DISTSSH_YES\")\n"
    length(collect_test_env_mutation("", Dict("test/t.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> seti; whole = false)) >= 1 ||
        die("self-test: setindex! ENV")
    dupw = "withenv(\"DISTSSH_YES\" => \"1\", \"DISTSSH_YES\" => \"0\") do\n    ENV[\"DISTSSH_YES\"] = \"9\"\nend\n"
    length(collect_test_env_mutation("", Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> dupw; whole = false)) >= 1 ||
        die("self-test: duplicate withenv key still mutates")
    blockrow = "#= EnvRow(\"DISTSSH_UNLISTED\", \"string\", \"unset\", \"—\", \"gone\") =#\n"
    !occursin("DISTSSH_UNLISTED", source_without_full_line_comments(blockrow)) ||
        die("self-test: block comment EnvRow")
    bad_allow = "x = \"hello\" # lint-allow split-token\n"
    malformed_allow_comment_lines(bad_allow) == [1] || die("self-test: malformed allow beside string")
    read_name = "read(\"pgrep report.txt\", String)\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> read_name; whole = false)) ||
        die("self-test: read filename is not a command")
    shifted = "Cmd([exe, \"pkill\"])\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> shifted; whole = false)) ||
        die("self-test: unresolved argv must not shift pkill")
    quoted = "echo '/opt/tools;archive/pgrep' -f x"
    length(shell_segments(quoted)) == 1 || die("self-test: quoted semicolon stays one segment")
    command_position_kill(quoted) && die("self-test: quoted semicolon path")
    command_position_kill("true; pkill -f x") || die("self-test: later segment pkill")
    leak = "function a()\n    tool = Sys.which(\"pgrep\")\nend\nfunction b()\n    Cmd([tool])\nend\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 6, String[])]), _ -> leak; whole = false)) ||
        die("self-test: const binding does not leak across functions")
    malformed_num = "withenv(\"DISTSSH_JOBS\" => \"12oops\") do\n    @test kit_host_jobs() == 1\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> malformed_num; whole = false)) >= 1 ||
        die("self-test: env-default malformed numeric")
    unrelated_throws = "withenv(\"DISTSSH_JOBS\" => \"nope\") do\n    @test kit_host_jobs() == 1\n    @test_throws ArgumentError parse(Int, \"bad\")\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 4, String[])]), _ -> unrelated_throws; whole = false)) >= 1 ||
        die("self-test: env-default unrelated throws")
    proc_doc = "function f()\n\"\"\"\nUse pkill with care.\n\"\"\"\nend\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 5, String[])]), _ -> proc_doc; whole = false)) ||
        die("self-test: process-pattern docstring")
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
    markdown_removed_names("Removed: `old_api`") == ["old_api"] || die("self-test: removed names Removed line")
    isempty(markdown_removed_names("removed `old_api` in favor of `new_api`")) ||
        die("self-test: removed names prose ignored")
    lint_obsolete_env_reject_table_sync(repo_root()) == 0 ||
        die("self-test: obsolete env table sync")
    post = mktempdir()
    ob = joinpath(post, "src/DistSSHRun/options/obsolete_env.jl")
    mkpath(dirname(ob))
    mkpath(joinpath(post, "changelog.d"))
    ob_text = """
    const OBSOLETE_ENV_RENAME_PAIRS = (
        "DISTSSH_SOURCE_COMMIT" => "DISTSSH_INTERNAL_SOURCE_COMMIT",
    )
    const OBSOLETE_ENV_REJECTION_NAMES = (
        "GB_PER_WORKER",
    )
    """
    write(ob, ob_text)
    write(joinpath(post, "NEWS.md"), "Removed: `GB_PER_WORKER`\n")
    lint_obsolete_env_reject_table_sync(post) == 0 || die("self-test: post-cut obsolete sync aligned")
    write(joinpath(post, "NEWS.md"), "Removed: `OTHER_ENV`\n")
    lint_obsolete_env_reject_table_sync(post) >= 1 || die("self-test: post-cut obsolete sync mismatch")
    allow_eq = "x = 1 # lint-allow: split-token -- inline allow marker with enough reason text\n"
    lint_allow_active(allow_eq, 1, "split-token") || die("self-test: inline allow not block comment")
    prog_bad = "withenv(\"DISTSSH_PROGRESS_BG\" => \"bogus\") do\n    @test x == 1\nend\n"
    length(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> prog_bad; whole = false)) >= 1 ||
        die("self-test: env-default progress bogus")
    prog_bad2 = "withenv(\"DISTSSH_PROGRESS_BG\" => \"bogus123\") do\n    @test x == 1\nend\n"
    length(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> prog_bad2; whole = false)) >= 1 ||
        die("self-test: env-default progress bogus123")
    valid_root = "withenv(\"DISTSSH_REMOTE_PROJECT_ROOT\" => \"/tmp/proj\") do\n    @test true\nend\n"
    isempty(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> valid_root; whole = false)) ||
        die("self-test: env-default valid remote root path")
    valid_ssh = "withenv(\"DISTSSH_SSH_OPTS\" => \"-o BatchMode=yes\") do\n    @test x == 1\nend\n"
    isempty(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> valid_ssh; whole = false)) ||
        die("self-test: env-default valid ssh opts")
    valid_hosts = "withenv(\"DISTSSH_HOSTS_FILE\" => \"\") do\n    @test x == 1\nend\n"
    isempty(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> valid_hosts; whole = false)) ||
        die("self-test: env-default valid empty hosts file")
    valid_exe = "withenv(\"JULIA_DISTRIBUTED_EXE\" => \"/usr/bin/julia\") do\n    @test x == 1\nend\n"
    isempty(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> valid_exe; whole = false)) ||
        die("self-test: env-default valid julia exe path")
    valid_auto = "withenv(\"JULIA_DISTRIBUTED_EXE\" => \"auto\") do\n    @test x == 1\nend\n"
    isempty(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> valid_auto; whole = false)) ||
        die("self-test: env-default valid julia exe auto")
    oxford = "accent: auto, light, or dark"
    ch = choice_words_from_env_row_desc(oxford)
    ch == Set(["auto", "light", "dark"]) || die("self-test: env-default oxford choices")
    backtick_desc = raw"set to `light` or `dark`"
    ch2 = choice_words_from_env_row_desc(backtick_desc)
    ch2 == Set(["light", "dark"]) || die("self-test: env-default backtick choices")
    bool_bad = "withenv(\"DISTSSH_SSH_TUNNEL\" => \"maybe\") do\n    @test ssh_tunnel_enabled() == true\nend\n"
    length(collect_env_default_test(repo_root(), Dict("test/t.jl" => [Hunk(1, 0, 1, 3, String[])]), _ -> bool_bad; whole = false)) >= 1 ||
        die("self-test: env-default bool maybe silent")
    helper_throws = "withenv(\"DISTSSH_JOBS\" => \"nope\") do\n    @test kit_host_jobs() == 1\n    @test_throws ArgumentError first([1])\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 4, String[])]), _ -> helper_throws; whole = false)) >= 1 ||
        die("self-test: env-default helper throws unrelated")
    outer_pe = "withenv(\"DISTSSH_JOBS\" => \"nope\") do\n    @test only(ProcessEnv(Dict())) == 1\n    @test_throws ArgumentError only(ProcessEnv(Dict()))\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 4, String[])]), _ -> outer_pe; whole = false)) >= 1 ||
        die("self-test: env-default ProcessEnv throws unrelated")
    keytext = "withenv(\"DISTSSH_JOBS\" => \"nope\") do\n    @test kit_host_jobs() == 1\n    @test_throws ArgumentError error(\"DISTSSH_JOBS failed\")\nend\n"
    length(collect_env_default_test("", Dict("test/t.jl" => [Hunk(1, 0, 1, 4, String[])]), _ -> keytext; whole = false)) >= 1 ||
        die("self-test: env-default throws key text unrelated")
    wrapper_env = "run(`env VAR=1 nice -n 2 sudo -u root timeout -s SIG 5 pkill -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> wrapper_env; whole = false)) >= 1 ||
        die("self-test: process-pattern env nice sudo timeout flags")
    var_which = "t = Sys.which(\"pkill\")\nrun(`\$t -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 2, 1, String[])]), _ -> var_which; whole = false)) >= 1 ||
        die("self-test: process-pattern backtick dollar which")
    var_lit = "t = \"pkill\"\nrun(`\$t -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 2, 1, String[])]), _ -> var_lit; whole = false)) >= 1 ||
        die("self-test: process-pattern backtick dollar literal")
    arg_err = "throw(ArgumentError(\"pkill failed on host\"))\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> arg_err; whole = false)) ||
        die("self-test: process-pattern throw ArgumentError prose")
    print_pk = "println(\"pkill failed on host\")\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> print_pk; whole = false)) ||
        die("self-test: process-pattern println prose")
    print_plain = "print(\"pkill failed on host\")\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> print_plain; whole = false)) ||
        die("self-test: process-pattern print prose")
    string_pk = "string(\"pkill failed on host\")\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> string_pk; whole = false)) ||
        die("self-test: process-pattern string prose")
    read_pk = "println(read(`pkill -f x`, String))\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> read_pk; whole = false)) >= 1 ||
        die("self-test: process-pattern println read cmd")
    sudo_n = "run(`sudo -n pkill -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> sudo_n; whole = false)) >= 1 ||
        die("self-test: process-pattern sudo -n")
    sudo_nu = "run(`sudo -nu root pkill -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> sudo_nu; whole = false)) >= 1 ||
        die("self-test: process-pattern sudo -nu")
    cmd_sudo = "Cmd([\"sudo\", \"pkill\", \"-f\", \"x\"])\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> cmd_sudo; whole = false)) >= 1 ||
        die("self-test: process-pattern Cmd sudo pkill")
    cmd_ex = "Cmd([exe, \"pkill\"])\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> cmd_ex; whole = false)) ||
        die("self-test: process-pattern Cmd exe pkill shift")
    cmd_ex2 = "Cmd([exe, \"sudo\", \"pkill\"])\n"
    isempty(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> cmd_ex2; whole = false)) ||
        die("self-test: process-pattern Cmd exe sudo pkill")
    var_dollar = "t = \"pkill\"\nrun(`\$(t) -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 2, 1, String[])]), _ -> var_dollar; whole = false)) >= 1 ||
        die("self-test: process-pattern backtick paren var")
    nice_n = "run(`nice -5 pkill -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> nice_n; whole = false)) >= 1 ||
        die("self-test: process-pattern nice -N")
    env_u = "run(`env -u FOO pkill -f x`)\n"
    length(collect_process_pattern("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> env_u; whole = false)) >= 1 ||
        die("self-test: process-pattern env -u")
    allow_mal = "x = 1 # lint-allow: split-token =# not documented\n"
    malformed_allow_comment_lines(allow_mal) == [1] || die("self-test: malformed allow equals-hash")
    red_str = "s = reduce(string, [\"DISTSSH_\", \"FOO\"])\n"
    length(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> red_str; whole = false)) >= 1 ||
        die("self-test: split-token reduce string")
    prod_tup = "s = prod((\"DISTSSH_\", \"FOO\"))\n"
    length(collect_split_token("", Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])]), _ -> prod_tup; whole = false)) >= 1 ||
        die("self-test: split-token prod tuple")
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
    span_cmd = "## Testing\n\nmacOS arm64, Julia 1.13.4.\n\n`julia --version`\n\n```text\njulia version 1.13.4\n```\n"
    any(x -> occursin("easier to copy", x), testing_shape_hints(section_named_text(span_cmd, "Testing"))) ||
        die("self-test: testing shape span hint $(testing_shape_hints(section_named_text(span_cmd, "Testing")))")
    bash_cmd = "## Testing\n\nmacOS arm64, Julia 1.13.4.\n\n```bash\njulia --version\n```\n\n```text\njulia version 1.13.4\n```\n"
    isempty(testing_shape_hints(section_named_text(bash_cmd, "Testing"))) ||
        die("self-test: testing shape bash $(testing_shape_hints(section_named_text(bash_cmd, "Testing")))")
    julia_cmd = "## Testing\n\nmacOS arm64, Julia 1.13.4.\n\n```julia\nusing Pkg; Pkg.test()\n```\n\n```text\n     Testing DistSSHRun tests passed\n```\n"
    isempty(testing_shape_hints(section_named_text(julia_cmd, "Testing"))) ||
        die("self-test: testing shape julia $(testing_shape_hints(section_named_text(julia_cmd, "Testing")))")
    stale_head = "## Summary\n\nx\n\n## Testing\n\nLinux x86_64, Julia 1.13.4.\n\n`true`\n\n```text\nok\n```\n\n## Risk\n\n## Revert\n"
    isempty(pr_body_errors(stale_head, ["README.md"])) ||
        die("self-test: testing format pr pass")
    no_fence = "## Summary\n\nx\n\n## Testing\n\nLinux x86_64, Julia 1.13.4.\n\n```bash\ntrue\n```\n\n## Risk\n\n## Revert\n"
    any(x -> occursin("text output", x), pr_body_errors(no_fence, ["README.md"])) &&
        die("self-test: testing missing fence is not a failure")
    any(x -> occursin("text fence", x), pr_body_hints(no_fence, "")) ||
        die("self-test: testing missing fence hint $(pr_body_hints(no_fence, ""))")
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
    isempty(testing_format_errors(section_named_text(cmd_fence_only, "Testing"))) ||
        die("self-test: cmd in fence only is not a failure")
    any(x -> occursin("fenced command", x), testing_shape_hints(section_named_text(cmd_fence_only, "Testing"))) ||
        die("self-test: cmd in fence only hint")
    hdr_in_fence = "## Summary\n\n```markdown\n## Testing\n```\n\n## Risk\n"
    testing_section_present(hdr_in_fence) && die("self-test: testing heading in fence")
    banned_hit("# until later") == "until" || die("self-test: until phrase $(repr(banned_hit("# until later")))")
    verify_addprocs_kw_allowlist!()
    h_cd = Dict("src/x.jl" => [Hunk(1, 0, 1, 1, String[])])
    length(collect_ban_cd("", h_cd, _ -> "cd(pwd())\n"; whole = false)) >= 1 || die("self-test: ban-cd hit")
    isempty(collect_ban_cd("", h_cd, _ -> "chdir(pwd())\n"; whole = false)) || die("self-test: ban-cd negative")
    length(collect_invokelatest("", h_cd, _ -> "Base.invokelatest(f)\n"; whole = false)) >= 1 ||
        die("self-test: invokelatest hit")
    dv_path = "test/fixtures/_lint_dead_version_gate.jl"
    dv_h = Dict(dv_path => [Hunk(1, 0, 1, 2, String[])])
    dead_src = "if VERSION < v\"1.14.0-\"\nend\n"
    length(collect_dead_version("", dv_h, _ -> dead_src; whole = false)) >= 1 ||
        die("self-test: dead-version-gate hit")
    live_src = "if VERSION < v\"1.13.5\"\nend\n"
    isempty(collect_dead_version("", dv_h, _ -> live_src; whole = false)) ||
        die("self-test: dead-version-gate negative")
    addprocs_bad = "addprocs(1; not_a_kw=1)\n"
    bad_a, splat_a = collect_addprocs_bad_kw("", h_cd, _ -> addprocs_bad; whole = false)
    length(bad_a) >= 1 || die("self-test: addprocs-kwargs bad")
    addprocs_splat = "addprocs(1; exename=x, other()...)\n"
    _, splat_b = collect_addprocs_bad_kw("", h_cd, _ -> addprocs_splat; whole = false)
    length(splat_b) >= 1 || die("self-test: addprocs-kwargs-splat")
    weak_path = "test/fixtures/_lint_weak_assertion.jl"
    weak_h = Dict(weak_path => [Hunk(1, 0, 1, 4, String[])])
    weak_bad = "@test true\n@test_throws Exception f()\n@test x == x\n"
    length(collect_weak_assertion("", weak_h, _ -> weak_bad; whole = false)) >= 3 ||
        die("self-test: weak-assertion hit")
    weak_ok = "@test_throws ErrorException f()\n@test 1 + 1 == 2\n"
    isempty(collect_weak_assertion("", weak_h, _ -> weak_ok; whole = false)) ||
        die("self-test: weak-assertion negative")
    count_swallowed_catch_legacy(repo_root()) <= 138 ||
        die("self-test: swallowed legacy above main")
    lint_fixture_suite!(repo_root())
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

function fenced_blocks(text::AbstractString)
    lines = collect(eachsplit(text, '\n'; keepempty = true))
    blocks = Tuple{String, String}[]
    i = 1
    while i <= length(lines)
        s = strip(lines[i])
        if startswith(s, "```")
            lang = String(strip(s[4:end]))
            body = String[]
            i += 1
            while i <= length(lines) && !startswith(strip(lines[i]), "```")
                push!(body, lines[i])
                i += 1
            end
            push!(blocks, (lang, join(body, '\n')))
        end
        i += 1
    end
    return blocks
end

function has_testing_command_fence(text::AbstractString)
    for (lang, body) in fenced_blocks(text)
        lang == "text" && continue
        for line in eachsplit(body, '\n'; keepempty = true)
            s = strip(line)
            (isempty(s) || startswith(s, "#")) && continue
            return true
        end
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

function testing_shape_hints(text::AbstractString)
    hints = String[]
    has_cmd = has_testing_command_fence(text)
    has_span = has_inline_command_outside_fences(text)
    has_text = occursin(r"(?m)^```text\s*$", text)
    if !has_cmd && !has_span
        push!(hints, "Testing command: a fenced command from the repository root is easiest to copy")
    elseif !has_cmd
        push!(hints, "Testing command: a fenced command is easier to copy than a code span")
    end
    if !has_text
        push!(hints, "Testing output: copy the last lines of that run into a text fence")
    end
    return hints
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
        append!(hints, testing_shape_hints(txt))
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

function decode_string_literal_chunk(v::AbstractString)
    occursin('\0', v) && return nothing
    return v
end

function string_literal_value(node)
    kind(node) == K"string" || return nothing
    # Interpolation keeps more than one child; refuse so a prefix chunk is not
    # treated as the full name (e.g. "DISTSSH_JOBS$(suffix)").
    numchildren(node) > 1 && return nothing
    if numchildren(node) == 1 && kind(node[1]) == K"String"
        chunk = sourcetext(node[1])
        occursin('\\', chunk) || return decode_string_literal_chunk(chunk)
        ex = try
            Meta.parse(sourcetext(node))
        catch
            return nothing
        end
        ex isa String || return nothing
        return occursin('\0', ex) ? nothing : ex
    end
    ex = try
        Meta.parse(sourcetext(node))
    catch
        return nothing
    end
    ex isa String || return nothing
    return occursin('\0', ex) ? nothing : ex
end

function string_literal_value_src(node)
    kind(node) == K"string" || return nothing
    v = string_literal_value(node)
    v !== nothing && return v
    ex = try
        Meta.parse(sourcetext(node))
    catch
        return nothing
    end
    ex isa String || return nothing
    return ex
end

function env_table_src_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "src/") && return true
    return occursin(r"^lib/[^/]+/src/", p)
end

# Complete names end in A-Z0-9. A trailing "_" is a prefix pattern, not one var.
const DISTSSH_ENV_NAME_RE = r"^DISTSSH_[A-Z0-9_]*[A-Z0-9]$"

function walk_split_token!(node, src, path, added, consts, rule, hits)
    if kind(node) == K"doc" ||
            (kind(node) == K"macrocall" && macro_head_name(node) in ("@doc", "doc"))
        # Skip the docstring operand; still scan the attached declaration.
        n = numchildren(node)
        n >= 2 && walk_split_token!(node[n], src, path, added, consts, rule, hits)
        return
    end
    if kind(node) in (K"function", K"->", K"let", K"do", K"for", K"while", K"try", K"macro")
        inner = copy(consts)
        for i in 1:numchildren(node)
            walk_split_token!(node[i], src, path, added, inner, rule, hits)
        end
        return
    end
    kind(node) == K"=" && fold_const_binding!(node, consts)
    if split_token_expr_hit(node, consts) && node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    for i in 1:numchildren(node)
        walk_split_token!(node[i], src, path, added, consts, rule, hits)
    end
    return
end

function split_token_ratchet_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    startswith(p, "scripts/lint/fixtures/") && return false
    return split_token_path(p)
end

function collect_split_token(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    pick = whole ? split_token_ratchet_path : split_token_path
    paths = whole ? filter(split_token_ratchet_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        pick(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        tree = parse_tree(src)
        consts = Dict{String, String}()
        fold_module_consts!(tree, consts)
        walk_split_token!(tree, src, path, added, consts, "split-token", hits)
    end
    return unique(hits)
end

function distssh_env_folded_name(node, consts::Dict{String, String})
    v = fold_string_expr(node, consts)
    v === nothing && return nothing
    occursin(DISTSSH_ENV_NAME_RE, v) || return nothing
    return v
end

# Drop full-line `#` comments so commented-out EnvRow / rename rows do not
# count as declarations. Trailing comments on code lines stay (rare for rows).
function source_without_full_line_comments(text::AbstractString)::String
    bytes = Vector{UInt8}(codeunits(text))
    for tok in tokenize(text)
        kind(tok) == K"Comment" || continue
        a = Int(first(tok.range))
        b = Int(last(tok.range))
        for i in a:b
            1 <= i <= length(bytes) || continue
            bytes[i] == UInt8('\n') && continue
            bytes[i] = UInt8(' ')
        end
    end
    return String(bytes)
end

function parse_user_env_table_names(root::AbstractString)
    path = joinpath(root, "src", "DistSSHRun", "options", "env_table.jl")
    isfile(path) || return Set{String}()
    names = Set{String}()
    text = source_without_full_line_comments(read(path, String))
    for m in eachmatch(r"EnvRow\(\s*\"([^\"]+)\"", text)
        push!(names, String(m.captures[1]))
    end
    # EnvRow(string("DISTSSH_", "FOO"), ...) keeps a split spelling in source.
    for m in eachmatch(r"EnvRow\(\s*string\(([^)]*)\)", text)
        parts = String[String(mm.captures[1]) for mm in eachmatch(r"\"([^\"]*)\"", m.captures[1])]
        isempty(parts) && continue
        push!(names, join(parts))
    end
    return names
end

function parse_legacy_env_old_names(root::AbstractString)
    path = joinpath(root, "lib", "DistSSHBase", "src", "env.jl")
    isfile(path) || return Set{String}()
    names = Set{String}()
    text = source_without_full_line_comments(read(path, String))
    for m in eachmatch(r"\"([A-Z0-9_]+)\"\s*=>", text)
        push!(names, String(m.captures[1]))
    end
    return names
end

function parse_removed_env_reject_table(root::AbstractString)
    path = joinpath(root, "src", "DistSSHRun", "options", "obsolete_env.jl")
    isfile(path) || return Set{String}()
    text = source_without_full_line_comments(read(path, String))
    m = match(r"OBSOLETE_ENV_REJECTION_NAMES\s*=\s*\(([^)]*)\)", text)
    m === nothing && return Set{String}()
    names = Set{String}()
    for mm in eachmatch(r"\"([^\"]+)\"", m.captures[1])
        push!(names, String(mm.captures[1]))
    end
    return names
end

function parse_obsolete_env_rename_names(root::AbstractString)
    path = joinpath(root, "src", "DistSSHRun", "options", "obsolete_env.jl")
    isfile(path) || return Set{String}()
    text = source_without_full_line_comments(read(path, String))
    m = match(r"OBSOLETE_ENV_RENAME_PAIRS\s*=\s*\(([^)]*)\)", text)
    m === nothing && return Set{String}()
    names = Set{String}()
    for mm in eachmatch(r"\"([^\"]+)\"\s*=>", m.captures[1])
        push!(names, String(mm.captures[1]))
    end
    return names
end

function parse_obsolete_env_known_names(root::AbstractString)
    return union(parse_removed_env_reject_table(root), parse_obsolete_env_rename_names(root))
end

const REMOVED_ENV_NAME_RE = r"^(DISTSSH_[A-Z0-9_]+|GB_PER_WORKER)$"

function changelog_removed_fragment_names(root::AbstractString)
    names = String[]
    for path in readlines(Cmd(`git -C $root ls-files changelog.d`; ignorestatus = true))
        append!(names, markdown_removed_names(read(joinpath(root, path), String)))
    end
    return unique(names)
end

function removed_env_fragment_names(root::AbstractString)
    return Set(n for n in changelog_removed_fragment_names(root) if occursin(REMOVED_ENV_NAME_RE, n))
end

# After a version cut, news-collect deletes consumed changelog.d fragments.
# Removed: lines that sat in those fragment bodies are copied into NEWS.md with
# the bullets, so the table sync must read both pending fragments and NEWS.md.
# Bidirectional checks apply only to pending changelog.d names; NEWS.md is a
# durable one-way source (every table name must appear somewhere).
function durable_removed_env_names(root::AbstractString)
    names = String[]
    append!(names, changelog_removed_fragment_names(root))
    news = joinpath(root, "NEWS.md")
    if isfile(news)
        append!(names, markdown_removed_names(read(news, String)))
    end
    return Set(n for n in unique(names) if occursin(REMOVED_ENV_NAME_RE, n))
end

function lint_obsolete_env_reject_table_sync(root::AbstractString)
    table = parse_removed_env_reject_table(root)
    if isempty(table)
        println(stderr, "lint: obsolete env rejection table is empty")
        return 1
    end
    durable = durable_removed_env_names(root)
    pending = removed_env_fragment_names(root)
    n = 0
    for name in table
        name in durable || begin
            println(
                stderr,
                "lint: obsolete env table name $(name) missing from changelog Removed: line or NEWS.md",
            )
            n += 1
        end
    end
    for name in pending
        name in table || begin
            println(stderr, "lint: changelog Removed env name $(name) missing from obsolete env table")
            n += 1
        end
    end
    bad = String[]
    for path in readlines(Cmd(`git -C $root ls-files src`; ignorestatus = true))
        path == "src/DistSSHRun/options/obsolete_env.jl" && continue
        text = read(joinpath(root, path), String)
        for (i, line) in enumerate(split(text, '\n'; keepempty = true))
            for name in table
                esc = replace(name, r"([\\^$.|?*+()\[\]{}])" => s"\\\1")
                occursin(Regex("\\b" * esc * "\\b"), line) || continue
                removed_name_src_ok(line, name) || push!(bad, "$(path):$(i):$(name)")
            end
        end
    end
    for hit in unique(bad)
        println(stderr, "lint: removed env name mention outside rejection table: $(hit)")
        n += 1
    end
    return n
end

function env_name_allowed(
        name::AbstractString,
        table::Set{String},
        legacy::Set{String},
        obsolete::Set{String},
    )::Bool
    # Explicit row, legacy map, or obsolete rejection only. Prefix and _ENV
    # aliases are not membership. DISTSSH_INTERNAL_* is skipped by the walker.
    name == "JULIA_DISTRIBUTED_EXE" && return true
    name in table && return true
    name in legacy && return true
    name in obsolete && return true
    return false
end

function env_sink_distssh_name(node, consts::Dict{String, String})
    if kind(node) == K"ref" && numchildren(node) >= 2 && sourcetext(node[1]) == "ENV"
        return distssh_env_folded_name(node[2], consts)
    end
    kind(node) == K"call" || return nothing
    head = call_head_name(node)
    head in ("get", "get!", "haskey", "delete!", "pop!") || return nothing
    numchildren(node) < 3 && return nothing
    sourcetext(node[2]) == "ENV" || return nothing
    return distssh_env_folded_name(node[3], consts)
end

function withenv_pair_distssh_name(node, consts::Dict{String, String})
    pair = env_pair_string_literals(node)
    pair === nothing && return nothing
    key, _ = pair
    occursin(DISTSSH_ENV_NAME_RE, key) || return nothing
    return key
end

function walk_env_table_names!(node, src, path, added, consts, table, legacy, removed, hits)
    if kind(node) == K"doc" ||
            (kind(node) == K"macrocall" && macro_head_name(node) in ("@doc", "doc"))
        n = numchildren(node)
        n >= 2 && walk_env_table_names!(
            node[n],
            src,
            path,
            added,
            consts,
            table,
            legacy,
            removed,
            hits,
        )
        return
    end
    name = distssh_env_folded_name(node, consts)
    if name !== nothing && !startswith(name, "DISTSSH_INTERNAL_") && node_touches_added(src, node, added) &&
            !env_name_allowed(name, table, legacy, removed)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "env-table"))
    end
    sink = env_sink_distssh_name(node, consts)
    if sink !== nothing && !startswith(sink, "DISTSSH_INTERNAL_") && node_touches_added(src, node, added) &&
            !env_name_allowed(sink, table, legacy, removed)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "env-table"))
    end
    if kind(node) == K"call" && call_head_name(node) == "withenv"
        for i in 2:numchildren(node)
            wn = withenv_pair_distssh_name(node[i], consts)
            if wn !== nothing && node_touches_added(src, node, added) &&
                    !env_name_allowed(wn, table, legacy, removed)
                push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "env-table"))
            end
        end
    end
    for i in 1:numchildren(node)
        walk_env_table_names!(node[i], src, path, added, consts, table, legacy, removed, hits)
    end
    return
end

function collect_env_table_names(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    table = parse_user_env_table_names(root)
    legacy = parse_legacy_env_old_names(root)
    removed = parse_obsolete_env_known_names(root)
    paths = whole ? filter(env_table_src_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        env_table_src_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        tree = parse_tree(src)
        consts = Dict{String, String}()
        fold_module_consts!(tree, consts)
        walk_env_table_names!(tree, src, path, added, consts, table, legacy, removed, hits)
    end
    return unique(hits)
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


# Inserted into scripts/lint/diff_lint.jl before `const BANNED_NEW`

function library_src_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "src/") && return true
    return occursin(r"^lib/[^/]+/src/", p)
end

const EXIT_SRC_ALLOWLIST = Set{String}(
    [
        "src/cli/_checkout.jl",
        "src/cli/doctor.jl",
        "src/cli/drive.jl",
        "src/cli/go.jl",
        "src/cli/hostinfo.jl",
        "src/cli/pool.jl",
        "src/cli/setup.jl",
        "src/cli/up.jl",
        "src/DistSSHRun/core/drive/cancel_frame.jl",
        "src/DistSSHRun/core/drive/run.jl",
        "src/DistSSHRun/infra/go_handshake.jl",
        "src/DistSSHRun/infra/namespace_sync.jl",
        "src/DistSSHRun/infra/ship.jl",
        "lib/DistSSHHeartbeat/src/worker.jl",
    ]
)

function macro_head_name(node)
    kind(node) == K"macrocall" || return nothing
    numchildren(node) >= 1 || return nothing
    head = node[1]
    kind(head) == K"MacroName" && return sourcetext(head)
    return ident_leaf(head)
end

function call_head_name(node)
    kind(node) == K"call" || return nothing
    numchildren(node) >= 1 || return nothing
    return ident_leaf(node[1])
end

include(joinpath(@__DIR__, "fold.jl"))
include(joinpath(@__DIR__, "shell_cmd.jl"))
include(joinpath(@__DIR__, "lint_allow.jl"))

function call_is_meta_dir_macro(node)
    kind(node) != K"macrocall" && return false
    head = macro_head_name(node)
    return head in ("@__DIR__", "@__FILE__", "@__MODULE__")
end

function call_ispkgdir(node)
    name = call_head_name(node)
    name in ("pkgdir", "Pkg.pkgdir") && return true
    kind(node) == K"call" || return false
    numchildren(node) >= 2 || return false
    return kind(node[1]) == K"." && sourcetext(node[1]) == "Base.pkgdir"
end

function rhs_bakes_runtime(node)
    function walk(node)
        call_is_meta_dir_macro(node) && return false
        call_ispkgdir(node) && return false
        kind(node) == K"macrocall" && return true
        if kind(node) == K"call"
            name = call_head_name(node)
            if name in ("homedir", "gethostname", "tempdir", "pwd", "getpid", "CPU_THREADS")
                return true
            end
            if kind(node[1]) == K"."
                right = sourcetext(node[numchildren(node)])
                right == "CPU_THREADS" && occursin("Sys", sourcetext(node[1])) && return true
            end
        end
        if kind(node) == K"ref"
            numchildren(node) >= 1 && sourcetext(node[1]) == "ENV" && return true
        end
        for i in 1:numchildren(node)
            walk(node[i]) && return true
        end
        return false
    end
    return walk(node)
end

const INIT_WORKLOAD_FORBIDDEN_CALLS = Set{String}(
    [
        "run",
        "addprocs",
        "connect",
        "listen",
        "atexit",
        "Timer",
    ]
)

function init_workload_forbidden_node(node)
    if kind(node) == K"macrocall"
        head = macro_head_name(node)
        head == "@async" && return true
        if head == "@spawn"
            return occursin("Threads", sourcetext(node[1]))
        end
        return false
    end
    kind(node) == K"call" || return false
    return call_head_name(node) in INIT_WORKLOAD_FORBIDDEN_CALLS
end

function collect_src_walk(
        root,
        files,
        src_for_path;
        whole::Bool,
        rule::AbstractString,
        walk_fn,
    )
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(library_src_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        library_src_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        walk_fn(parse_tree(src), src, path, added, rule, hits)
    end
    return unique(hits)
end

struct LibraryWalkCtx
    func_depth::Int
    in_init::Bool
    workload_depth::Int
end

function tree_function_name(node)
    k = kind(node)
    (k == K"function" || k == K"=") || return nothing
    numchildren(node) < 1 && return nothing
    sig = node[1]
    while (kind(sig) == K"where" || kind(sig) == K"::") && numchildren(sig) >= 1
        sig = sig[1]
    end
    kind(sig) == K"call" || return nothing
    return ident_leaf(sig[1])
end

function walk_ban_cd!(node, src, path, added, rule, hits)
    if kind(node) == K"call" && call_head_name(node) == "cd" && node_touches_added(src, node, added)
        a = line_of(src, Int(first(byte_range(node))))
        push!(hits, (path, a, rule))
    end
    for i in 1:numchildren(node)
        walk_ban_cd!(node[i], src, path, added, rule, hits)
    end
    return
end

function collect_ban_cd(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "ban-cd", walk_fn = walk_ban_cd!)
end

function assign_lhs_is_const_container(node)
    kind(node) != K"=" && return false
    numchildren(node) >= 2 || return false
    rhs = node[2]
    if kind(rhs) == K"call"
        return call_head_name(rhs) in ("Ref", "Dict", "Set", "IdDict", "Vector", "Array", "BitSet")
    end
    return kind(rhs) in (K"vect", K"curly")
end

function descend_library_ctx(node, ctx::LibraryWalkCtx)
    fn = tree_function_name(node)
    fn == "__init__" && return LibraryWalkCtx(ctx.func_depth + 1, true, ctx.workload_depth)
    fn !== nothing && return LibraryWalkCtx(ctx.func_depth + 1, false, ctx.workload_depth)
    if kind(node) == K"macrocall"
        head = macro_head_name(node)
        head in ("@setup_workload", "setup_workload", "@compile_workload", "compile_workload") &&
            return LibraryWalkCtx(ctx.func_depth, ctx.in_init, ctx.workload_depth + 1)
    end
    return ctx
end

function module_level_parent(parent)
    return kind(parent) in (K"toplevel", K"module")
end

function walk_ban_global!(node, parent, src, path, added, rule, hits, ctx::LibraryWalkCtx = LibraryWalkCtx(0, false, 0))
    if ctx.func_depth > 0 && kind(node) == K"global" && node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    if ctx.func_depth == 0 && module_level_parent(parent) && kind(node) == K"=" &&
            tree_function_name(node) === nothing && !assign_lhs_is_const_container(node) &&
            numchildren(node) >= 1 && kind(node[1]) != K"ref" &&
            node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    child_ctx = descend_library_ctx(node, ctx)
    for i in 1:numchildren(node)
        walk_ban_global!(node[i], node, src, path, added, rule, hits, child_ctx)
    end
    return
end

function collect_ban_global(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(library_src_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        library_src_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        tree = parse_tree(src)
        walk_ban_global!(tree, tree, src, path, added, "ban-global", hits)
    end
    return unique(hits)
end

function walk_ban_const_bake!(node, src, path, added, rule, hits, ctx::LibraryWalkCtx = LibraryWalkCtx(0, false, 0))
    if kind(node) == K"const" && ctx.func_depth == 0 && numchildren(node) >= 2
        rhs_bakes_runtime(node[2]) && node_touches_added(src, node, added) &&
            push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    child_ctx = descend_library_ctx(node, ctx)
    for i in 1:numchildren(node)
        walk_ban_const_bake!(node[i], src, path, added, rule, hits, child_ctx)
    end
    return
end

function collect_ban_const_bake(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "ban-const-bake", walk_fn = walk_ban_const_bake!)
end

function in_init_or_workload(ctx::LibraryWalkCtx)
    return ctx.in_init || ctx.workload_depth > 0
end

function walk_ban_init_sidefx!(node, src, path, added, rule, hits, ctx::LibraryWalkCtx = LibraryWalkCtx(0, false, 0))
    if in_init_or_workload(ctx) && init_workload_forbidden_node(node) && node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    child_ctx = descend_library_ctx(node, ctx)
    for i in 1:numchildren(node)
        walk_ban_init_sidefx!(node[i], src, path, added, rule, hits, child_ctx)
    end
    return
end

function collect_ban_init_sidefx(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "ban-init-sidefx", walk_fn = walk_ban_init_sidefx!)
end

function walk_ban_assert!(node, src, path, added, rule, hits)
    if kind(node) == K"macrocall" && macro_head_name(node) in ("assert", "@assert") &&
            node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    for i in 1:numchildren(node)
        walk_ban_assert!(node[i], src, path, added, rule, hits)
    end
    return
end

function collect_ban_assert(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "ban-assert", walk_fn = walk_ban_assert!)
end

function is_invokelatest_node(node)
    if kind(node) == K"macrocall"
        return macro_head_name(node) == "@invokelatest"
    end
    kind(node) == K"call" || return false
    name = call_head_name(node)
    name in ("invokelatest", "invoke_in_world") && return true
    if kind(node[1]) == K"."
        return ident_leaf(node[1]) == "invokelatest"
    end
    return false
end

function walk_invokelatest!(node, src, path, added, rule, hits)
    is_invokelatest_node(node) && node_touches_added(src, node, added) &&
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    for i in 1:numchildren(node)
        walk_invokelatest!(node[i], src, path, added, rule, hits)
    end
    return
end

function collect_invokelatest(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "invokelatest", walk_fn = walk_invokelatest!)
end

function is_env_write_node(node)
    if kind(node) == K"="
        numchildren(node) >= 1 || return false
        lhs = node[1]
        return kind(lhs) == K"ref" && numchildren(lhs) >= 1 && sourcetext(lhs[1]) == "ENV"
    end
    if kind(node) == K"call"
        name = call_head_name(node)
        if name == "setindex!"
            numchildren(node) >= 4 || return false
            return sourcetext(node[2]) == "ENV"
        end
        name in ("delete!", "pop!") || return false
        numchildren(node) >= 2 || return false
        return sourcetext(node[2]) == "ENV"
    end
    return false
end

function walk_env_write!(node, src, path, added, rule, hits)
    is_env_write_node(node) && node_touches_added(src, node, added) &&
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    for i in 1:numchildren(node)
        walk_env_write!(node[i], src, path, added, rule, hits)
    end
    return
end

function collect_env_write(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "env-write", walk_fn = walk_env_write!)
end

function withenv_pair_key(node)::Union{Nothing, String}
    kind(node) == K"call" || return nothing
    numchildren(node) < 3 && return nothing
    key_i = if sourcetext(node[1]) in ("=>", ":(=>)")
        2
    elseif sourcetext(node[2]) in ("=>", ":(=>)")
        1
    else
        return nothing
    end
    key = string_literal_value(node[key_i])
    key === nothing && (key = string_literal_value_src(node[key_i]))
    return key
end

# nothing → pair keys are not all literals; body gets an empty restore set.
function withenv_restored_keys(node)::Union{Nothing, Set{String}}
    keys = String[]
    n = numchildren(node)
    n < 2 && return Set{String}()
    for i in 2:(n - 1)
        key = withenv_pair_key(node[i])
        key === nothing && return nothing
        push!(keys, key)
    end
    dup = Set(k for k in keys if count(==(k), keys) > 1)
    return setdiff(Set(keys), dup)
end

function env_write_target_key(node)::Union{Nothing, String}
    if kind(node) == K"="
        numchildren(node) >= 1 || return nothing
        lhs = node[1]
        kind(lhs) == K"ref" && numchildren(lhs) >= 2 || return nothing
        sourcetext(lhs[1]) == "ENV" || return nothing
        key = string_literal_value(lhs[2])
        key === nothing && (key = string_literal_value_src(lhs[2]))
        return key
    end
    if kind(node) == K"call"
        name = call_head_name(node)
        if name == "setindex!"
            numchildren(node) >= 4 || return nothing
            sourcetext(node[2]) == "ENV" || return nothing
            key = string_literal_value(node[4])
            key === nothing && (key = string_literal_value_src(node[4]))
            return key
        end
        name in ("delete!", "pop!") || return nothing
        numchildren(node) >= 3 || return nothing
        sourcetext(node[2]) == "ENV" || return nothing
        key = string_literal_value(node[3])
        key === nothing && (key = string_literal_value_src(node[3]))
        return key
    end
    return nothing
end

# restored === nothing → outside withenv (every write hits).
# restored isa Set → inside withenv; only writes to other/unknown keys hit.
function test_env_mutation_hit_node(node, restored::Union{Nothing, Set{String}})
    if kind(node) == K"call" && call_head_name(node) == "merge!" &&
            numchildren(node) >= 2 && sourcetext(node[2]) == "ENV"
        return true
    end
    is_env_write_node(node) || return false
    restored === nothing && return true
    key = env_write_target_key(node)
    key === nothing && return true
    return !(key in restored)
end

function walk_test_env_mutation!(node, src, path, added, restored::Union{Nothing, Set{String}}, hits)
    if kind(node) == K"call" && call_head_name(node) == "withenv"
        n = numchildren(node)
        n < 2 && return
        body = node[n]
        inner = restored
        if kind(body) == K"do"
            keys = withenv_restored_keys(node)
            added_keys = keys === nothing ? Set{String}() : keys
            inner = restored === nothing ? added_keys : union(restored, added_keys)
        end
        for i in 1:n
            d = i == n ? inner : restored
            walk_test_env_mutation!(node[i], src, path, added, d, hits)
        end
        return
    end
    if test_env_mutation_hit_node(node, restored) && node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "test-env-mutation"))
    end
    for i in 1:numchildren(node)
        walk_test_env_mutation!(node[i], src, path, added, restored, hits)
    end
    return
end

function test_env_mutation_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    test_path(p) && return true
    return startswith(p, "scripts/lint/fixtures/test_mutation/")
end

function collect_test_env_mutation(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(test_env_mutation_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        test_env_mutation_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        walk_test_env_mutation!(parse_tree(src), src, path, added, nothing, hits)
    end
    return unique(hits)
end

function function_has_kwargs_splat(node)
    kind(node) in (K"function", K"=") || return false
    st = sourcetext(node)
    return occursin(r";\s*kwargs\.\.\.", st) || occursin(r",\s*kwargs\.\.\.", st)
end

function walk_kwargs_splat!(node, src, path, added, rule, hits)
    if function_has_kwargs_splat(node) && node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    for i in 1:numchildren(node)
        walk_kwargs_splat!(node[i], src, path, added, rule, hits)
    end
    return
end

function collect_kwargs_splat(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "kwargs-splat", walk_fn = walk_kwargs_splat!)
end

function walk_ban_exit!(node, src, path, added, rule, hits)
    if kind(node) == K"call" && call_head_name(node) == "exit" && node_touches_added(src, node, added)
        p = replace(path, '\\' => '/')
        p in EXIT_SRC_ALLOWLIST && return
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), rule))
    end
    for i in 1:numchildren(node)
        walk_ban_exit!(node[i], src, path, added, rule, hits)
    end
    return
end

function collect_ban_exit(root, files, src_for_path; whole::Bool)
    return collect_src_walk(root, files, src_for_path; whole, rule = "ban-exit", walk_fn = walk_ban_exit!)
end

function catch_stmt_log_only(node)
    k = kind(node)
    if k == K"macrocall"
        head = macro_head_name(node)
        return head in ("@warn", "@error", "@info", "@debug")
    end
    if k == K"call" && call_head_name(node) == "println"
        return occursin("stderr", sourcetext(node))
    end
    return false
end

function catch_body_statement_nodes(node)
    kind(node) == K"catch" || return SyntaxNode[]
    out = SyntaxNode[]
    function walk(node)
        k = kind(node)
        if k == K"macrocall" || k == K"call"
            push!(out, node)
            return
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return
    end
    for i in 1:numchildren(node)
        walk(node[i])
    end
    return out
end

function catch_body_log_only(node)
    stmts = catch_body_statement_nodes(node)
    isempty(stmts) && return false
    for st in stmts
        catch_stmt_log_only(st) || return false
    end
    return true
end

function swallowed_catch_hit_legacy(src::AbstractString, node)::Bool
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

function verify_addprocs_kw_allowlist!()
    lm = Distributed.LocalManager(1, true)
    sm = Distributed.SSHManager(["localhost"])
    live = Set{Symbol}()
    union!(live, keys(Distributed.default_addprocs_params(lm)))
    union!(live, keys(Distributed.default_addprocs_params(sm)))
    live == ADDDROCS_KW_ALLOWLIST || die("self-test: addprocs allowlist $(live)")
    return
end

function version_string_literal(node)
    kind(node) == K"macrocall" || return nothing
    numchildren(node) >= 2 || return nothing
    head_txt = sourcetext(node[1])
    head_txt in ("v", "@v_str", "v_str") || return nothing
    inner = strip(sourcetext(node[2]), '"')
    isempty(inner) && return nothing
    try
        return VersionNumber(inner)
    catch
        return nothing
    end
end

function version_compare_sides(node)
    kind(node) == K"call" || return nothing
    numchildren(node) >= 3 || return nothing
    op = sourcetext(node[2])
    op in ("<", ">", "<=", ">=", "==", "===", "!=", "!==") || return nothing
    a, b = node[1], node[3]
    if sourcetext(a) == "VERSION"
        v = version_string_literal(b)
        v === nothing && return nothing
        return (op, v)
    end
    if sourcetext(b) == "VERSION"
        v = version_string_literal(a)
        v === nothing && return nothing
        return (flip_op(op), v)
    end
    return nothing
end

function flip_op(op::AbstractString)
    op == "<" && return ">"
    op == ">" && return "<"
    op == "<=" && return ">="
    op == ">=" && return "<="
    return op
end

function version_compare_result(op::AbstractString, ver::VersionNumber, v::VersionNumber)
    op == "<" && return ver < v
    op == ">" && return ver > v
    op == "<=" && return ver <= v
    op == ">=" && return ver >= v
    op == "==" && return ver == v
    op == "===" && return ver == v
    op == "!=" && return ver != v
    op == "!==" && return ver != v
    return ver < v
end

function project_julia_compat_bounds(root::AbstractString)
    path = joinpath(root, "Project.toml")
    isfile(path) || return nothing
    data = TOML.parsefile(path)
    compat = get(data, "compat", Dict{String, Any}())
    spec = get(compat, "julia", nothing)
    spec === nothing && return nothing
    s = strip(String(spec))
    isempty(s) && return nothing
    m = match(r"^(\d+)\.(\d+)(?:\.(\d+))?", s)
    m === nothing && return nothing
    major = Base.parse(Int, m.captures[1])
    minor = Base.parse(Int, m.captures[2])
    patch = m.captures[3] === nothing ? 0 : Base.parse(Int, m.captures[3])
    lo = VersionNumber(major, minor, patch)
    hi = VersionNumber(major, minor + 1, 0)
    return (lo, hi)
end

function dead_version_compare(bounds, op::AbstractString, literal::VersionNumber)
    lo, _ = bounds
    probe_hi = VersionNumber(lo.major, lo.minor, 999)
    return version_compare_result(op, lo, literal) == version_compare_result(op, probe_hi, literal)
end

function dead_version_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    startswith(p, "src/") && return true
    startswith(p, "test/") && return true
    startswith(p, "lib/") && return true
    return false
end

function walk_dead_version!(node, bounds, src, path, added, hits)
    sides = version_compare_sides(node)
    if sides !== nothing && node_touches_added(src, node, added)
        op, literal = sides
        dead_version_compare(bounds, op, literal) &&
            push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "dead-version-gate"))
    end
    for i in 1:numchildren(node)
        walk_dead_version!(node[i], bounds, src, path, added, hits)
    end
    return
end

function collect_dead_version(root, files, src_for_path; whole::Bool)
    bounds_root = isempty(root) ? repo_root() : root
    bounds = project_julia_compat_bounds(bounds_root)
    bounds === nothing && return [("Project.toml", 1, "dead-version-gate")]
    hits = Tuple{String, Int, String}[]
    paths = whole ? filter(dead_version_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        dead_version_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        walk_dead_version!(parse_tree(src), bounds, src, path, added, hits)
    end
    return unique(hits)
end

function addprocs_kw_child_kw(node)
    st = sourcetext(node)
    occursin(r"\)\.\.\.", st) && return :splat
    kind(node) == K"=" || return nothing
    numchildren(node) >= 1 || return nothing
    id = ident_leaf(node[1])
    id === nothing && return nothing
    return Symbol(id)
end

function addprocs_call_kws(node)
    kind(node) == K"call" || return (Symbol[], false)
    call_head_name(node) == "addprocs" || return (Symbol[], false)
    has_splat = false
    keys = Symbol[]
    for i in 1:numchildren(node)
        child = node[i]
        kind(child) == K"parameters" || continue
        for j in 1:numchildren(child)
            kw = addprocs_kw_child_kw(child[j])
            kw === nothing && continue
            kw == :splat && (has_splat = true; continue)
            push!(keys, kw)
        end
    end
    return (keys, has_splat)
end

function walk_addprocs!(node, src, path, added, bad_hits, splat_hits)
    if kind(node) == K"call" && call_head_name(node) == "addprocs"
        keys, has_splat = addprocs_call_kws(node)
        line = line_of(src, Int(first(byte_range(node))))
        if has_splat && node_touches_added(src, node, added)
            push!(splat_hits, (path, line, "addprocs-kwargs-splat"))
        end
        for k in keys
            k in ADDDROCS_KW_ALLOWLIST && continue
            node_touches_added(src, node, added) || continue
            push!(bad_hits, (path, line, "addprocs-kwargs"))
        end
    end
    for i in 1:numchildren(node)
        walk_addprocs!(node[i], src, path, added, bad_hits, splat_hits)
    end
    return
end

function collect_addprocs_bad_kw(root, files, src_for_path; whole::Bool)
    bad = Tuple{String, Int, String}[]
    splat = Tuple{String, Int, String}[]
    paths = whole ? filter(library_src_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        library_src_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        walk_addprocs!(parse_tree(src), src, path, added, bad, splat)
    end
    return unique(bad), unique(splat)
end

function collect_addprocs_kwargs_bad(root, files, src_for_path; whole::Bool)
    bad, _ = collect_addprocs_bad_kw(root, files, src_for_path; whole)
    return bad
end

function collect_addprocs_kwargs_splat(root, files, src_for_path; whole::Bool)
    _, splat = collect_addprocs_bad_kw(root, files, src_for_path; whole)
    return splat
end

function weak_assertion_hit(node, src, path, added)
    kind(node) == K"macrocall" || return false
    head = macro_head_name(node)
    head in ("test", "@test") || return false
    node_touches_added(src, node, added) || return false
    numchildren(node) >= 2 || return false
    arg = node[2]
    if sourcetext(arg) == "true" || kind(arg) == K"Bool"
        return true
    end
    if kind(arg) == K"call" && call_head_name(arg) == "isa" && numchildren(arg) >= 3
        tail = ident_leaf(arg[3])
        return tail == "Any"
    end
    if kind(arg) == K"call" && numchildren(arg) >= 3
        op = sourcetext(arg[2])
        op in ("==", "===") && return expr_same(arg[1], arg[3])
    end
    return false
end

function expr_same(node_a, node_b)
    return sourcetext(node_a) == sourcetext(node_b)
end

function weak_assertion_throws_hit(node, src, path, added)
    kind(node) == K"macrocall" || return false
    macro_head_name(node) in ("@test_throws", "test_throws") || return false
    node_touches_added(src, node, added) || return false
    numchildren(node) < 2 && return false
    arg = node[2]
    kind(arg) == K"Identifier" && sourcetext(arg) == "Exception" && return true
    return false
end

function walk_weak_assertion!(node, src, path, added, hits)
    if weak_assertion_hit(node, src, path, added) || weak_assertion_throws_hit(node, src, path, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "weak-assertion"))
    end
    for i in 1:numchildren(node)
        walk_weak_assertion!(node[i], src, path, added, hits)
    end
    return
end

function collect_weak_assertion(root, files, src_for_path; whole::Bool)
    whole && die("weak-assertion is diff-only")
    hits = Tuple{String, Int, String}[]
    for path in collect(keys(files))
        test_path(path) || continue
        skipped_path(path) && continue
        endswith(path, ".jl") || continue
        isempty(added_lines(get(files, path, Hunk[]))) && continue
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = added_lines(get(files, path, Hunk[]))
        walk_weak_assertion!(parse_tree(src), src, path, added, hits)
    end
    return unique(hits)
end

function count_swallowed_catch_legacy(root::AbstractString)
    n = 0
    for path in tracked_jl(root)
        skipped_path(path) && continue
        startswith(replace(path, '\\' => '/'), ".github/") && continue
        src = read(joinpath(root, path), String)
        function walk(node)
            if kind(node) == K"catch" && swallowed_catch_hit_legacy(src, node)
                n += 1
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

function suppression_line_hit(line::AbstractString)
    occursin("shellcheck disable=", line) && return true
    occursin("zizmor: ignore", line) && return true
    occursin(r"#\s*! format: off", line) && return true
    occursin("runic: off", line) && return true
    occursin("gitleaks:allow", line) && return true
    occursin("treat_as_own", line) && return true
    occursin(r"broken\s*=\s*true", line) && return true
    occursin(r"ambiguities\s*=\s*false", line) && return true
    return false
end

function collect_suppression_markers(root::AbstractString)
    n = 0
    for path in readlines(`git -C $root ls-files`)
        skipped_path(path) && continue
        full = joinpath(root, path)
        isfile(full) || continue
        if path == ".github/zizmor.yml"
            src = read(full, String)
            n += count(==("disable: true"), split(src, '\n'))
            continue
        end
        if path == ".JETLSConfig.toml"
            n += count(==("[[diagnostic.patterns]]"), split(read(full, String), '\n'))
            continue
        end
        if path == ".github/aqua-check.sh"
            occursin("stale_deps", read(full, String)) && occursin("ignore", read(full, String)) && (n += 1)
            continue
        end
        endswith(path, ".jl") || endswith(path, ".sh") || endswith(path, ".yml") || endswith(path, ".yaml") ||
            continue
        for line in eachsplit(read(full, String), '\n')
            suppression_line_hit(line) && (n += 1)
        end
    end
    return n
end

function lint_mode_zero(root, files, src_for_path, collect_fn, ceiling_name)
    added = collect_fn(root, files, src_for_path; whole = false)
    n = report_hits(added, root)
    whole = collect_fn(root, files, src_for_path; whole = true)
    filter_debt_hits!(whole, root)
    n += check_ceiling(ceiling_name, length(whole), 0)
    return n
end

function main_ceiling_int(name::AbstractString, default::Int)
    v = main_ceiling(name)
    v === :unread && return -1
    v === nothing && return default
    return v
end

function check_env_default_test_ceiling(measured::Int, constant::Int)
    n = 0
    if measured != constant
        println(stderr, "lint: CEILING_ENV_DEFAULT_TEST: measured $(measured), constant $(constant)")
        n += 1
    end
    prev = main_ceiling("CEILING_ENV_DEFAULT_TEST")
    if prev === :unread
        println(stderr, "lint: CEILING_ENV_DEFAULT_TEST: could not read the ceiling on origin/main")
        n += 1
    elseif prev !== nothing && constant > prev
        main_rev = main_ceiling_int("CEILING_ENV_DEFAULT_TEST_RULE_REV", 0)
        if CEILING_ENV_DEFAULT_TEST_RULE_REV <= main_rev || measured != constant
            println(
                stderr,
                "lint: CEILING_ENV_DEFAULT_TEST: constant $(constant) above origin/main $(prev) without rule revision",
            )
            n += 1
        end
    end
    return n
end

function check_swallowed_ceiling(measured::Int, constant::Int)
    n = 0
    if measured != constant
        println(stderr, "lint: CEILING_SWALLOWED_CATCH: measured $(measured), constant $(constant)")
        n += 1
    end
    prev = main_ceiling("CEILING_SWALLOWED_CATCH")
    if prev === :unread
        println(stderr, "lint: CEILING_SWALLOWED_CATCH: could not read the ceiling on origin/main")
        n += 1
    elseif prev !== nothing && constant > prev
        main_rev = main_ceiling_int("CEILING_SWALLOWED_CATCH_RULE_REV", 1)
        if CEILING_SWALLOWED_CATCH_RULE_REV <= main_rev || measured != constant
            println(
                stderr,
                "lint: CEILING_SWALLOWED_CATCH: constant $(constant) above origin/main $(prev) without rule revision",
            )
            n += 1
        end
    end
    return n
end

const BANNED_NEW = ("best-effort", "until", "lockstep", "pending", "known failure", "pre-existing")
const CEILING_ID_MATCH = 0
const CEILING_PROCESS_PATTERN = 5
const CEILING_LOCK_CREATE = 0
const CEILING_ENV_DEFAULT = 0
const CEILING_ENV_DEFAULT_TEST = 0
const CEILING_ENV_DEFAULT_TEST_RULE_REV = 5
const CEILING_SWALLOWED_CATCH_RULE_REV = 2
const CEILING_SWALLOWED_CATCH = 146
const CEILING_LOOP_SKIP = 0
const CEILING_PR_REFS = 0
const CEILING_EXCUSE_PHRASES = 6
const CEILING_INVOKELATEST = 14
const CEILING_ENV_WRITE = 38
const CEILING_KWARGS_SPLAT = 22
const CEILING_SUPPRESSION = 18
const CEILING_ADDPROCS_KW_SPLAT = 0
const CEILING_SPLIT_TOKEN = 2
const CEILING_ENV_TABLE = 0
const CEILING_TEST_ENV_MUTATION = 72
const CEILING_LINT_ALLOW = 1
const ADDDROCS_KW_ALLOWLIST = Set{Symbol}(
    [
        :cmdline_cookie,
        :dir,
        :enable_threaded_blas,
        :env,
        :exeflags,
        :exename,
        :lazy,
        :max_parallel,
        :multiplex,
        :shell,
        :ssh,
        :sshflags,
        :topology,
        :tunnel,
    ]
)

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
        src = src_for_path(path)
        src === nothing && return nothing
        return src
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

function string_is_function_docstring(node, parent)
    kind(node) in (K"string", K"String") || return false
    kind(parent) == K"block" || return false
    numchildren(parent) < 1 && return false
    parent[1] === node || return false
    return true
end

function diagnostic_prose_context(parent, gparent)
    for p in (parent, gparent)
        p === nothing && continue
        if kind(p) == K"macrocall"
            mh = macro_head_name(p)
            mh in ("@warn", "@error", "@info", "@debug", "warn", "error", "info", "debug") && return true
        end
        if kind(p) == K"call"
            h = call_head_name(p)
            h in (
                "error",
                "throw",
                "warn",
                "println",
                "print",
                "string",
                "sprint",
                "showerror",
            ) && return true
            h in ("ArgumentError", "ErrorException") && return true
        end
    end
    return false
end

function walk_process_pattern!(node, parent, gparent, src, path, added, consts, hits)
    if kind(node) == K"doc" ||
            (kind(node) == K"macrocall" && macro_head_name(node) in ("@doc", "doc"))
        n = numchildren(node)
        n >= 2 && walk_process_pattern!(node[n], node, parent, src, path, added, consts, hits)
        return
    end
    if kind(node) in (K"function", K"->", K"let", K"do", K"for", K"while", K"try", K"macro")
        inner = copy(consts)
        for i in 1:numchildren(node)
            walk_process_pattern!(node[i], node, parent, src, path, added, inner, hits)
        end
        return
    end
    kind(node) == K"=" && fold_const_binding!(node, consts)
    diagnostic = diagnostic_prose_context(parent, gparent)
    filename_arg = parent !== nothing && kind(parent) == K"call" &&
        call_head_name(parent) in ("read", "open")
    if !diagnostic && !filename_arg && kind(node) == K"string" && node_touches_added(src, node, added)
        lit = string_literal_value(node)
        lit === nothing && (lit = literal_command_text(node))
        scriptish = lit !== nothing && occursin(r"[;&|]|\s", lit) && command_position_kill(lit)
        if lit !== nothing && (occursin(BRACKET_TRICK_RE, lit) || scriptish)
            push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "process-pattern"))
        end
    end
    if kind(node) != K"Identifier" && kind(node) != K"Comment" &&
            process_pattern_builder_hit(node, consts) &&
            node_touches_added(src, node, added)
        push!(hits, (path, line_of(src, Int(first(byte_range(node)))), "process-pattern"))
    end
    for i in 1:numchildren(node)
        walk_process_pattern!(node[i], node, parent, src, path, added, consts, hits)
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
        startswith(p, "src/") || occursin(r"^lib/[^/]+/src/", p) ||
            startswith(p, "scripts/lint/fixtures/") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added_set = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added_set) && continue)
        tree = parse_tree(src)
        consts = Dict{String, String}()
        fold_module_consts!(tree, consts)
        walk_process_pattern!(tree, nothing, nothing, src, path, added_set, consts, hits)
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

function parse_user_env_kinds(root::AbstractString)::Dict{String, String}
    path = joinpath(root, "src", "DistSSHRun", "options", "env_table.jl")
    isfile(path) || return Dict{String, String}()
    text = source_without_full_line_comments(read(path, String))
    kinds = Dict{String, String}()
    for m in eachmatch(r"EnvRow\(\s*\"([^\"]+)\"\s*,\s*\"([^\"]+)\"", text)
        kinds[String(m.captures[1])] = String(m.captures[2])
    end
    for m in eachmatch(r"EnvRow\(\s*string\(([^)]*)\)\s*,\s*\"([^\"]+)\"", text)
        parts = String[String(mm.captures[1]) for mm in eachmatch(r"\"([^\"]*)\"", m.captures[1])]
        isempty(parts) && continue
        kinds[join(parts)] = String(m.captures[2])
    end
    return kinds
end

function invalid_env_literal_generic(s::AbstractString)::Bool
    s == "0" && return true
    s == "-1" && return true
    isempty(s) && return false
    return tryparse(Float64, s) === nothing
end

function invalid_env_literal_for_kind(
        kind_str::AbstractString,
        val::AbstractString,
        choices::Set{String},
    )::Bool
    k = lowercase(strip(kind_str))
    if startswith(k, "int") || startswith(k, "uint")
        n = tryparse(Int, val)
        n === nothing && return true
        occursin(">= 1", k) && return n < 1
        occursin("> 0", k) && return n <= 0
        occursin(">= 0", k) && return n < 0
        return false
    end
    if startswith(k, "float")
        n = tryparse(Float64, val)
        n === nothing && return true
        !isfinite(n) && return true
        occursin("> 0", k) && return !(n > 0)
        occursin(">= 0", k) && return n < 0
        return false
    end
    if startswith(k, "bool")
        isempty(val) && return false
        low = lowercase(val)
        low in ("true", "false", "yes", "no", "on", "off", "0", "1") && return false
        return true
    end
    if startswith(k, "string") || startswith(k, "path") || occursin("path list", k)
        isempty(choices) && return false
        return !(lowercase(val) in choices)
    end
    return false
end

function invalid_env_literal(s::AbstractString)::Bool
    return invalid_env_literal_generic(s)
end

const CHOICE_DESC_STOPWORDS = Set{String}(
    [
        "a",
        "an",
        "and",
        "of",
        "one",
        "or",
        "set",
        "the",
        "to",
    ]
)

function choice_word_token(raw::AbstractString)
    s = strip(String(raw), [' ', '`', '"', '\'', ','])
    isempty(s) && return nothing
    m = match(r"^([a-z][a-z0-9_]*)$", lowercase(s))
    m === nothing && return nothing
    tok = String(m.captures[1])
    tok in CHOICE_DESC_STOPWORDS && return nothing
    return tok
end

function choice_tail_word(frag::AbstractString)
    s = strip(String(frag))
    s = replace(s, r"^.*:\s*" => "")
    m = match(r"\b([a-z][a-z0-9_]*)\s*$", lowercase(strip(s)))
    m === nothing && return nothing
    tok = String(m.captures[1])
    tok in CHOICE_DESC_STOPWORDS && return nothing
    return tok
end

function choice_words_from_env_row_desc(desc::AbstractString)
    vals = Set{String}()
    d = String(desc)
    for m in eachmatch(r"`([^`]+)`", d)
        w = choice_word_token(m.captures[1])
        w !== nothing && push!(vals, w)
    end
    low = lowercase(d)
    if !occursin(r"\bor\b", low) && !occursin("one of", low)
        return length(vals) >= 2 ? vals : Set{String}()
    end
    plain = replace(d, r"`[^`]*`" => "")
    comma_or = replace(plain, r"\bor\b" => ",")
    for part in split(comma_or, ',')
        w = choice_word_token(part)
        w === nothing && (w = choice_tail_word(part))
        w !== nothing && push!(vals, w)
    end
    length(vals) < 2 && return Set{String}()
    return vals
end

function env_row_descriptions(text::AbstractString, key::AbstractString)
    descs = String[]
    literal = Regex(
        "EnvRow\\(\\s*\"\\Q$(key)\\E\"\\s*,\\s*\"[^\"]+\"\\s*,\\s*\"[^\"]+\"\\s*,\\s*\"[^\"]+\"\\s*,\\s*\"([^\"]+)\"",
    )
    for m in eachmatch(literal, text)
        push!(descs, String(m.captures[1]))
    end
    return descs
end

function documented_choice_values(root::AbstractString, key::AbstractString)
    vals = Set{String}()
    table = joinpath(root, "src", "DistSSHRun", "options", "env_table.jl")
    isfile(table) || return vals
    text = read(table, String)
    for desc in env_row_descriptions(text, key)
        union!(vals, choice_words_from_env_row_desc(desc))
    end
    return vals
end

function documented_string_patterns(root::AbstractString)
    pats = Dict{String, Regex}()
    dir = joinpath(root, "src")
    isdir(dir) || return pats
    for (d, _, files) in walkdir(dir)
        for f in files
            endswith(f, ".jl") || continue
            text = read(joinpath(d, f), String)
            for line in eachsplit(text, '\n')
                m = match(r"(DISTSSH_[A-Z0-9_]+).{0,120}\[([A-Za-z0-9._:@+\-]+)\]\+", line)
                m === nothing && continue
                class = String(m.captures[2])
                pats[String(m.captures[1])] = Regex("^(?:[" * class * "]+)\$")
            end
        end
    end
    return pats
end

function invalid_env_literal(
        key::AbstractString,
        val::AbstractString,
        kinds::Dict{String, String};
        choices::Dict{String, Set{String}} = Dict{String, Set{String}}(),
        patterns::Dict{String, Regex} = Dict{String, Regex}(),
    )::Bool
    pat = get(patterns, key, nothing)
    if pat !== nothing
        isempty(val) && return false
        return !occursin(pat, val)
    end
    known = get(choices, key, Set{String}())
    if !isempty(known)
        return !(lowercase(val) in known)
    end
    kind_str = get(kinds, key, "")
    isempty(kind_str) && return false
    return invalid_env_literal_for_kind(kind_str, val, known)
end

function test_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "test/") && return true
    return occursin(r"^lib/[^/]+/test/", p)
end

function env_pair_string_literals(node)
    kind(node) == K"call" || return nothing
    numchildren(node) < 3 && return nothing
    (op_i, key_i, val_i) = if sourcetext(node[1]) in ("=>", ":(=>)")
        (1, 2, 3)
    elseif numchildren(node) >= 3 && sourcetext(node[2]) in ("=>", ":(=>)")
        (2, 1, 3)
    else
        return nothing
    end
    op = sourcetext(node[op_i])
    op in ("=>", ":(=>)") || return nothing
    key = string_literal_value(node[key_i])
    val = string_literal_value(node[val_i])
    if key === nothing || val === nothing
        key = string_literal_value_src(node[key_i])
        val = string_literal_value_src(node[val_i])
    end
    (key === nothing || val === nothing) && return nothing
    return (key, val)
end

function called_names(node)
    names = Set{String}()
    function walk(n)
        if kind(n) == K"call"
            nm = call_head_name(n)
            nm !== nothing && push!(names, nm)
        end
        for i in 1:numchildren(n)
            walk(n[i])
        end
        return
    end
    walk(node)
    return names
end

const ENV_TEST_WRAPPER_CALLS = Set{String}(
    [
        "ProcessEnv",
        "only",
        "get",
        "getproperty",
        "getindex",
        "broadcast",
        "something",
        "Dict",
        "String",
        "withenv",
        "merge",
        "pairs",
        "strip",
        "getfield",
        "first",
        "last",
        "length",
        "isempty",
        "collect",
        "each",
        "map",
        "filter",
        "parse",
        "Int",
        "UInt",
        "Float64",
        "Bool",
        "error",
        "ArgumentError",
        "ErrorException",
        "Exception",
        "Set",
        "Vector",
        "Array",
    ]
)

function env_test_equality_macro(node)
    found = false
    function walk(n)
        if kind(n) == K"macrocall" && macro_head_name(n) in ("test", "@test") && numchildren(n) >= 2
            arg = n[2]
            if kind(arg) == K"call" && numchildren(arg) >= 3 && sourcetext(arg[2]) in ("==", "===")
                found = true
            end
        end
        for i in 1:numchildren(n)
            walk(n[i])
        end
        return
    end
    walk(node)
    return found
end

function env_test_reader_names(node)
    names = Set{String}()
    function walk(n)
        if kind(n) == K"macrocall"
            mh = macro_head_name(n)
            if mh in ("test", "@test") && numchildren(n) >= 2
                arg = n[2]
                if kind(arg) == K"call" && numchildren(arg) >= 3
                    op = sourcetext(arg[2])
                    if op in ("==", "===")
                        union!(names, setdiff(called_names(arg), ENV_TEST_WRAPPER_CALLS))
                    end
                end
            end
        end
        for i in 1:numchildren(n)
            walk(n[i])
        end
        return
    end
    walk(node)
    return names
end

function env_test_throw_reader_names(node)
    names = Set{String}()
    function walk_throw(n)
        if kind(n) == K"macrocall" && macro_head_name(n) in ("test_throws", "@test_throws")
            for i in 2:numchildren(n)
                kind(n[i]) == K"call" &&
                    union!(names, setdiff(called_names(n[i]), ENV_TEST_WRAPPER_CALLS))
            end
        end
        for i in 1:numchildren(n)
            walk_throw(n[i])
        end
        return
    end
    walk_throw(node)
    return names
end

function throw_covers_bad_env_keys(throw::Set{String}, bad_keys::AbstractSet{<:AbstractString})
    isempty(throw) && return false
    for key in bad_keys
        stem = lowercase(replace(String(key), r"^DISTSSH_" => ""))
        for name in throw
            low = lowercase(name)
            low == stem && return true
            occursin(stem, low) && return true
        end
    end
    return false
end

function test_flags_in_subtree(node, watched_keys::AbstractSet{<:AbstractString} = Set{String}())
    has_eq = env_test_equality_macro(node)
    eq = env_test_reader_names(node)
    throw = env_test_throw_reader_names(node)
    shared = !isempty(intersect(eq, throw))
    throws_only_reader = !has_eq && !isempty(throw)
    throw_covers = throw_covers_bad_env_keys(throw, watched_keys)
    suppress = shared || throws_only_reader || throw_covers
    return has_eq, suppress
end

function withenv_invalid_test_keys(node, kinds::Dict{String, String}, root, choices, patterns)
    kind(node) == K"call" || return String[]
    call_head_name(node) == "withenv" || return String[]
    keys = String[]
    for i in 2:numchildren(node)
        pair = env_pair_string_literals(node[i])
        pair === nothing && continue
        key = pair[1]
        (startswith(key, "DISTSSH_") || key == "JULIA_DISTRIBUTED_EXE") || continue
        startswith(key, "DISTSSH_INTERNAL_") && continue
        get!(choices, key) do
            documented_choice_values(root, key)
        end
        invalid_env_literal(key, pair[2], kinds; choices = choices, patterns = patterns) && push!(keys, key)
    end
    return keys
end

function walk_env_default_test!(node, src, path, added, kinds, root, choices, patterns, hits)
    if kind(node) == K"call" && call_head_name(node) == "withenv" &&
            node_touches_added(src, node, added)
        bad_keys = withenv_invalid_test_keys(node, kinds, root, choices, patterns)
        if !isempty(bad_keys)
            numchildren(node) >= 2 || return
            body = node[numchildren(node)]
            has_eq, suppress = test_flags_in_subtree(body, Set(bad_keys))
            if has_eq && !suppress
                a = line_of(src, Int(first(byte_range(node))))
                push!(hits, (path, a, "env-default"))
            end
        end
    end
    for i in 1:numchildren(node)
        walk_env_default_test!(node[i], src, path, added, kinds, root, choices, patterns, hits)
    end
    return
end

function env_default_test_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    test_path(p) && return true
    return startswith(p, "scripts/lint/fixtures/evasion/")
end

function env_default_test_ratchet_path(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    startswith(p, "scripts/lint/fixtures/") && return false
    return env_default_test_path(p)
end

function collect_env_default_test(root, files, src_for_path; whole::Bool)
    hits = Tuple{String, Int, String}[]
    kinds = parse_user_env_kinds(root)
    choices = Dict{String, Set{String}}()
    patterns = documented_string_patterns(root)
    pick = whole ? env_default_test_ratchet_path : env_default_test_path
    paths = whole ? filter(env_default_test_ratchet_path, tracked_jl(root)) : collect(keys(files))
    for path in paths
        pick(path) || continue
        endswith(path, ".jl") || continue
        whole || (isempty(added_lines(get(files, path, Hunk[]))) && continue)
        src = lint_file_src(root, path, src_for_path)
        src === nothing && continue
        added = whole ? Set(1:(count(==('\n'), src) + 1)) : added_lines(get(files, path, Hunk[]))
        whole || (isempty(added) && continue)
        walk_env_default_test!(parse_tree(src), src, path, added, kinds, root, choices, patterns, hits)
    end
    return unique(hits)
end

function swallowed_catch_hit(src::AbstractString, node)::Bool
    kind(node) == K"catch" || return false
    catch_body_log_only(node) && return true
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
    !isempty(lines) && all(
        l ->
        isempty(l) || startswith(l, "#") || occursin(r"^@(warn|error|info|debug)\b", l) ||
            occursin(r"^println\s*\(\s*stderr", l),
        lines,
    ) && return true
    return catch_body_log_only(node)
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

const LINT_RULE_PROTECT = Dict(
    "split-token" => (
        "greps stay honest when env or API names are built from folded string pieces",
        "use one literal name or list it in the env table",
    ),
    "process-pattern" => (
        "shell command builders use pid-scoped patterns, not broad pkill",
        "scope pkill/pgrep/killall to a job tag or document setup cleanup",
    ),
    "env-table" => (
        "every DISTSSH_* string in src is documented or rejected",
        "add an EnvRow or obsolete rejection entry",
    ),
    "test-env-mutation" => (
        "tests restore process env via withenv",
        "wrap the test body in withenv or leave env unchanged",
    ),
    "env-default" => (
        "missing env must not silently fall back in library code",
        "require a value or throw when unset",
    ),
)

function lint_fixture_rel(path::AbstractString)
    p = replace(String(path), '\\' => '/')
    return startswith(p, "scripts/lint/fixtures/")
end

function filter_debt_hits!(hits, root::AbstractString)
    filter!(h -> !lint_fixture_rel(h[1]), hits)
    filter_lint_allows!(hits, root)
    return hits
end

function report_hits(hits, root::AbstractString)
    filter_debt_hits!(hits, root)
    n = 0
    for (path, line, rule) in hits
        info = get(LINT_RULE_PROTECT, rule, ("", ""))
        protect, fix = info
        msg = isempty(protect) ? rule : "$(rule): protects $(protect)"
        println(stderr, "lint: $(path):$(line): $(msg)")
        !isempty(fix) && println(stderr, "lint: $(path):$(line): fix: $(fix)")
        println(
            stderr,
            "lint: $(path):$(line): If this is a false positive, add `# lint-allow: $(rule) -- <why>`. Do not split, rename, reformat, move or reword code to avoid this rule.",
        )
        n += 1
    end
    return n
end

function lint_mode_dual(root, files, src_for_path, collect_fn, ceiling_name, ceiling)
    added = collect_fn(root, files, src_for_path; whole = false)
    n = report_hits(added, root)
    whole = collect_fn(root, files, src_for_path; whole = true)
    filter_debt_hits!(whole, root)
    n += check_ceiling(ceiling_name, length(whole), ceiling)
    return n
end

function markdown_removed_names(src::AbstractString)
    names = String[]
    for line in eachsplit(src, '\n'; keepempty = false)
        m = match(r"^Removed:\s*(.*)$", strip(line))
        m === nothing && continue
        for mm in eachmatch(r"`([^`]+)`", m.captures[1])
            tok = mm.captures[1]
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

function removed_name_src_ok(line::AbstractString, tok::AbstractString)::Bool
    # Only recognized rejection / migration constructs. Prose such as
    # "was renamed to" on an active definition must still report.
    occursin("throw_renamed_env!", line) && return true
    occursin("_reject_obsolete", line) && return true
    occursin("_throw_if_obsolete", line) && return true
    occursin("LEGACY_ENV_RENAMES", line) && return true
    occursin("OBSOLETE_ENV_REJECTION_NAMES", line) && return true
    occursin("OBSOLETE_ENV_RENAME_PAIRS", line) && return true
    occursin(r"name in \(", line) && occursin(tok, line) && return true
    occursin(Regex("\\Q\"$(tok)\"\\s*=>"), line) && return true
    occursin(Regex("=>\\s*\"\\Q$(tok)\""), line) && return true
    return false
end

function grep_token_removed(root, tok, dirs)
    hits = grep_token(root, tok, dirs)
    out = String[]
    for hit in hits
        m = match(r"^([^:]+):[0-9]+:", hit)
        m === nothing && (push!(out, hit); continue)
        path = String(m.captures[1])
        replace(path, '\\' => '/') == "src/DistSSHRun/options/obsolete_env.jl" && continue
        line = occursin(":", hit) ? split(hit, ":", limit = 3)[3] : ""
        if startswith(replace(path, '\\' => '/'), "src/") && removed_name_src_ok(line, tok)
            continue
        end
        push!(out, hit)
    end
    return out
end

function lint_removed_names(root::AbstractString, extra_root::AbstractString = "")
    n = lint_obsolete_env_reject_table_sync(root)
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
        for hit in grep_token_removed(root, tok, ("README.md", "README.ja.md", "docs", "src"))
            println(stderr, "lint: removed name $(tok) still in $(hit)")
            n += 1
        end
        if !isempty(extra_root)
            # Downstream stays unfiltered: this package's rejection exemptions
            # must not hide an active use in DistSSHQueue / DistSSHKit trees.
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
    added = collect_env_default_test(root, files, src_for_path; whole = false)
    n += report_hits(added, root)
    whole = collect_env_default_test(root, files, src_for_path; whole = true)
    filter_debt_hits!(whole, root)
    n += check_env_default_test_ceiling(length(whole), CEILING_ENV_DEFAULT_TEST)
    return n
end

function lint_swallowed_catch(root, files, src_for_path)
    added = collect_swallowed_catch(root, files, src_for_path; whole = false)
    n = report_hits(added, root)
    whole = collect_swallowed_catch(root, files, src_for_path; whole = true)
    filter_debt_hits!(whole, root)
    n += check_swallowed_ceiling(length(whole), CEILING_SWALLOWED_CATCH)
    return n
end

function lint_ban_cd(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_ban_cd, "CEILING_BAN_CD")
end

function lint_ban_global(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_ban_global, "CEILING_BAN_GLOBAL")
end

function lint_ban_const_bake(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_ban_const_bake, "CEILING_BAN_CONST_BAKE")
end

function lint_ban_init_sidefx(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_ban_init_sidefx, "CEILING_BAN_INIT_SIDEFX")
end

function lint_ban_assert(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_ban_assert, "CEILING_BAN_ASSERT")
end

function lint_invokelatest(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_invokelatest, "CEILING_INVOKELATEST", CEILING_INVOKELATEST)
end

function lint_env_write(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_env_write, "CEILING_ENV_WRITE", CEILING_ENV_WRITE)
end

function lint_kwargs_splat(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_kwargs_splat, "CEILING_KWARGS_SPLAT", CEILING_KWARGS_SPLAT)
end

function lint_ban_exit(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_ban_exit, "CEILING_BAN_EXIT")
end

function lint_suppression(root)
    return check_ceiling("CEILING_SUPPRESSION", collect_suppression_markers(root), CEILING_SUPPRESSION)
end

function lint_dead_version(root, files, src_for_path)
    return lint_mode_zero(root, files, src_for_path, collect_dead_version, "CEILING_DEAD_VERSION")
end

function lint_addprocs_kwargs(root, files, src_for_path)
    bad_add, splat_add = collect_addprocs_bad_kw(root, files, src_for_path; whole = false)
    n = report_hits(bad_add, root) + report_hits(splat_add, root)
    bad_whole, splat_whole = collect_addprocs_bad_kw(root, files, src_for_path; whole = true)
    filter_debt_hits!(splat_whole, root)
    n += check_ceiling("CEILING_ADDPROCS_KW_BAD", length(bad_whole), 0)
    n += check_ceiling("CEILING_ADDPROCS_KW_SPLAT", length(splat_whole), CEILING_ADDPROCS_KW_SPLAT)
    return n
end

function lint_addprocs_kwargs_splat(root, files, src_for_path)
    _, splat_add = collect_addprocs_bad_kw(root, files, src_for_path; whole = false)
    return report_hits(splat_add, root)
end

function lint_weak_assertion(root, files, src_for_path)
    return report_hits(collect_weak_assertion(root, files, src_for_path; whole = false), root)
end

function lint_pr_refs(root, files, src_for_path)
    return lint_mode_dual(root, files, src_for_path, collect_pr_refs, "CEILING_PR_REFS", CEILING_PR_REFS)
end

function lint_excuse_ceiling(root)
    return check_ceiling("CEILING_EXCUSE_PHRASES", collect_excuse_phrases(root), CEILING_EXCUSE_PHRASES)
end

function lint_split_token(root, files, src_for_path)
    return lint_mode_dual(
        root,
        files,
        src_for_path,
        collect_split_token,
        "CEILING_SPLIT_TOKEN",
        CEILING_SPLIT_TOKEN,
    )
end

function lint_env_table(root, files, src_for_path)
    return lint_mode_dual(
        root,
        files,
        src_for_path,
        collect_env_table_names,
        "CEILING_ENV_TABLE",
        CEILING_ENV_TABLE,
    )
end

function lint_test_env_mutation(root, files, src_for_path)
    return lint_mode_dual(
        root,
        files,
        src_for_path,
        collect_test_env_mutation,
        "CEILING_TEST_ENV_MUTATION",
        CEILING_TEST_ENV_MUTATION,
    )
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
    "ban-cd",
    "ban-global",
    "ban-const-bake",
    "ban-init-sidefx",
    "ban-assert",
    "invokelatest",
    "env-write",
    "kwargs-splat",
    "ban-exit",
    "suppression",
    "dead-version-gate",
    "addprocs-kwargs",
    "addprocs-kwargs-splat",
    "weak-assertion",
    "split-token",
    "env-table",
    "test-env-mutation",
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
    mode == "ban-cd" && return lint_ban_cd(root, files, src_for)
    mode == "ban-global" && return lint_ban_global(root, files, src_for)
    mode == "ban-const-bake" && return lint_ban_const_bake(root, files, src_for)
    mode == "ban-init-sidefx" && return lint_ban_init_sidefx(root, files, src_for)
    mode == "ban-assert" && return lint_ban_assert(root, files, src_for)
    mode == "invokelatest" && return lint_invokelatest(root, files, src_for)
    mode == "env-write" && return lint_env_write(root, files, src_for)
    mode == "kwargs-splat" && return lint_kwargs_splat(root, files, src_for)
    mode == "ban-exit" && return lint_ban_exit(root, files, src_for)
    mode == "suppression" && return lint_suppression(root)
    mode == "dead-version-gate" && return lint_dead_version(root, files, src_for)
    mode == "addprocs-kwargs" && return lint_addprocs_kwargs(root, files, src_for)
    mode == "addprocs-kwargs-splat" && return lint_addprocs_kwargs_splat(root, files, src_for)
    mode == "weak-assertion" && return lint_weak_assertion(root, files, src_for)
    mode == "split-token" && return lint_split_token(root, files, src_for)
    mode == "env-table" && return lint_env_table(root, files, src_for)
    mode == "test-env-mutation" && return lint_test_env_mutation(root, files, src_for)
    return die("unknown mode $(mode)")
end

function lint_all(root)
    register_lint_rules!(collect(GATE_LINT_NAMES))
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
        elseif mode == "suppression"
            lint_suppression(root)
        else
            lint_diff_mode(mode, root, files, src_for)
        end
    end
    n += lint_unknown_or_bad_allows(root)
    n += check_ceiling("CEILING_LINT_ALLOW", length(collect_lint_allow_markers(root)), CEILING_LINT_ALLOW)
    lint_allow_summary_new(root, files)
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
    register_lint_rules!(collect(GATE_LINT_NAMES))
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
