# Diff lints. JuliaSyntax comes from `.github/runic` (a direct dependency).
# Do not Pkg.add, and do not load a copy from the running process.
#
#   julia --project=.github/runic --startup-file=no scripts/lint/diff_lint.jl <mode>
#   modes: banned-words, agents-md, skip-reasons, new-comments, self-test, pr-body

using JuliaSyntax
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

function parse_diff(diff::AbstractString)
    files = Dict{String, Vector{Hunk}}()
    path = ""
    cur = nothing
    for line in eachsplit(diff, '\n')
        if startswith(line, "diff --git ")
            cur = nothing
            continue
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

function git_diff(root::AbstractString)
    cmd = `git -C $root diff -U0 --no-color origin/main...HEAD`
    return read(cmd, String)
end

function skipped_path(path::AbstractString)
    return startswith(path, "scripts/lint/") ||
        startswith(path, ".agents/skills/") ||
        startswith(path, "docs/src/devdocs/agents/skills/")
end

const BANNED = (
    "fine for now",
    "workaround",
    "IMPORTANT",
    "for now",
    "XXX",
    "HACK",
    "delve",
    "crucial",
    "additionally",
)

function banned_hit(text::AbstractString)
    for word in ("fine for now", "workaround", "IMPORTANT")
        occursin(word, text) && return word
    end
    if !occursin("fine for now", text) && occursin("for now", text)
        return "for now"
    end
    for word in ("XXX", "HACK", "delve", "crucial", "additionally")
        occursin(Regex("(?<![A-Za-z0-9_])" * word * "(?![A-Za-z0-9_])"), text) && return word
    end
    return nothing
end

function lint_banned(root, files)
    n = 0
    for (path, hunks) in files
        skipped_path(path) && continue
        added = union((added_lines(h) for h in hunks)...)
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
                println(stderr, "lint: $(path):$(i): banned word $(hit)")
                n += 1
            end
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
                union!(names, public_names_in(read(joinpath(dir, file), String)))
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
    added = union((added_lines(h) for h in hunks)...)
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

function has_string(node)
    stack = [node]
    while !isempty(stack)
        n = pop!(stack)
        if kind(n) in (K"string", K"String")
            return true
        end
        for i in 1:numchildren(n)
            push!(stack, n[i])
        end
    end
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

function issue_is_open(n::Int)
    get(ENV, "GITHUB_ACTIONS", "") == "true" || return true
    repo = get(ENV, "GITHUB_REPOSITORY", "")
    isempty(repo) && die("GITHUB_REPOSITORY is unset")
    out = read(`gh api repos/$(repo)/issues/$(n) --jq .state`, String)
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

function check_skip_macro(node, src, path)
    numchildren(node) < 1 && return 0
    name = sourcetext(node[1])
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
            kw = keyword_name(node[i])
            kw === nothing && continue
            val = keyword_value(node[i])
            if kw == "broken" && val !== nothing && kind(val) == K"Bool" && sourcetext(val) == "true"
                broken = true
            elseif kw == "skip"
                skip = true
                val !== nothing && has_version(val) && (versioned = true)
            end
        end
    end
    if broken || versioned
        if isempty(nums)
            println(stderr, "lint: $(path):$(a): #N is required")
            nerr += 1
        end
    elseif skip
        if !has_string(node)
            println(stderr, "lint: $(path):$(a): environment-guard skip needs a reason string")
            nerr += 1
        end
    else
        return nerr
    end
    return nerr + require_open_issues(src, a, b, path)
end

function lint_skips(root, files, src_for_path)
    n = 0
    for (path, hunks) in files
        endswith(path, ".jl") || continue
        skipped_path(path) && continue
        added = union((added_lines(h) for h in hunks)...)
        isempty(added) && continue
        src = src_for_path(path)
        tree = parse_tree(src)
        function walk(node, inside_fn)
            k = kind(node)
            if k == K"macrocall" && !inside_fn
                r = byte_range(node)
                line = line_of(src, Int(first(r)))
                if line in added
                    n += check_skip_macro(node, src, path)
                end
            end
            next = inside_fn || k == K"function" || k == K"->"
            for i in 1:numchildren(node)
                walk(node[i], next)
            end
            return
        end
        walk(tree, false)
    end
    return n
end

function deleted_bodies(h::Hunk)
    bodies = Set{String}()
    for line in h.deleted
        for (_, _, text) in comment_tokens(line * "\n")
            push!(bodies, comment_body(text))
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
    @test_broken \"needs a number\"
    @test g() skip=(VERSION < v\"1.14\")
    @test h() skip=true
    @test i() broken=true #1
    function helper()
        @test_broken \"inside helper\"
    end
    """
    tree2 = parse_tree(skip_src)
    errs = Ref(0)
    function walk2(node, inside)
        if kind(node) == K"macrocall" && !inside
            errs[] += check_skip_macro(node, skip_src, "t.jl")
        end
        next = inside || kind(node) == K"function"
        for i in 1:numchildren(node)
            walk2(node[i], next)
        end
        return
    end
    walk2(tree2, false)
    errs[] == 3 || die("self-test: skip errors $(errs[])")
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
    dump = "## Summary\n\n## Testing\n\n## Risk\n\n## Revert\n\n- `scripts/check.sh`\n- `CONTRIBUTING.md`\n"
    any(==("file list"), pr_body_errors(dump, listed)) || die("self-test: pr body file list")
    fenced = "## Summary\n\n## Testing\n\n## Risk\n\n## Revert\n\n```\nscripts/check.sh\nCONTRIBUTING.md\n```\n"
    any(==("file list"), pr_body_errors(fenced, listed)) || die("self-test: pr body fence")
    short = "## Summary\n\nscripts/check.sh is the gate.\n\n## Testing\n\nRan it.\n\n## Risk\n\nThe hook remains.\n\n## Revert\n\nRevert the merge.\n"
    isempty(pr_body_errors(short, listed)) || die("self-test: pr body $(pr_body_errors(short, listed))")
    isempty(pr_body_errors(dump, ["scripts/check.sh"])) || die("self-test: pr body one path")
    star = "## Summary\n\n## Testing\n\n## Risk\n\n## Revert\n\n* `scripts/check.sh`\n* `CONTRIBUTING.md`\n"
    any(==("file list"), pr_body_errors(star, listed)) || die("self-test: pr body star list")
    fence_ok = "## Summary\n\n## Testing\n\n```sh\n# Confirmed locally\n```\n\n## Risk\n\n## Revert\n"
    isempty(pr_template_errors(fence_ok)) || die("self-test: pr fence heading $(pr_template_errors(fence_ok))")
    percent_decode("a%20b") == "a b" || die("self-test: percent decode")
    for (_, _, text) in comment_tokens("# Use café\n")
    end
    link_target("guide.md \"Read the guide\"") == "guide.md" || die("self-test: link title")
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

function show_file(root::AbstractString, path::AbstractString)
    try
        return read(`git -C $root show origin/main:$path`, String)
    catch
        return ""
    end
end

function doc_touch(root::AbstractString)
    files = parse_diff(git_diff(root))
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
        new_src = isfile(joinpath(root, path)) ? read(joinpath(root, path), String) : ""
        if lines_hit_doc(new_src, new_lines) || lines_hit_doc(show_file(root, path), old_lines)
            return true
        end
    end
    return false
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

function pr_body_errors(body::AbstractString, paths)
    errs = pr_template_errors(body)
    append!(errs, file_list_errors(body, paths))
    return errs
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
    text = ""
    if occursin(r":\s*[>|]\s*$", line)
        parts = String[]
        i = idx + 1
        while i <= length(lines)
            nxt = lines[i]
            (startswith(nxt, " ") || startswith(nxt, "\t")) || break
            push!(parts, strip(nxt))
            i += 1
        end
        text = join(filter(!isempty, parts), " ")
    else
        m = match(r"^tone_instructions:\s*(?:\"(.*)\"|'(.*)'|(\S.*?))\s*$", line)
        m === nothing && return ["tone_instructions is not a string"]
        text = something(m.captures[1], m.captures[2], m.captures[3], "")
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

function main(args)
    if length(args) == 3 && args[1] == "pr-body"
        return pr_body_main(args[2], args[3])
    end
    if length(args) != 1
        die("usage: diff_lint.jl <banned-words|agents-md|skip-reasons|new-comments|doc-touch|docs-static|self-test|pr-body>")
    end
    mode = args[1]
    mode == "self-test" && return self_test()
    root = repo_root()
    if mode == "doc-touch"
        println(doc_touch(root) ? "yes" : "no")
        return 0
    elseif mode == "docs-static"
        docs_static(root) == 0 || exit(1)
        return 0
    end
    files = parse_diff(git_diff(root))
    n = if mode == "banned-words"
        lint_banned(root, files)
    elseif mode == "agents-md"
        lint_agents(root, files)
    elseif mode == "skip-reasons"
        lint_skips(root, files, path -> read(joinpath(root, path), String))
    elseif mode == "new-comments"
        lint_new_comments(root, files)
    else
        die("unknown mode $(mode)")
    end
    n == 0 || exit(1)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
