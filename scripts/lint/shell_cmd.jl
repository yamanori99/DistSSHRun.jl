# Shell command-building context for process-pattern (included into Main).

const PROCESS_KILL_WORDS = ("pkill", "killall", "pgrep")
const SHELL_WRAPPERS = ("sudo", "env", "nice", "command", "nohup", "timeout", "ssh", "xargs")
const BRACKET_TRICK_RE = r"(^|[^A-Za-z0-9_])\[[A-Za-z]\][A-Za-z]"

function shell_token(tok::AbstractString)
    return basename(replace(String(tok), r"^['\"]|['\"]$" => ""))
end

function shell_skip_sudo_opts(i::Int, toks::AbstractVector)
    n = length(toks)
    sudo_noarg = Set(['n', 'v', 'E', 'h', 'K'])
    sudo_witharg = Set(['u', 'g', 'p', 'C', 'H'])
    while i <= n
        t = String(toks[i])
        startswith(t, "-") || break
        if t in ("-n", "-E", "-v", "-h", "-K")
            i += 1
            continue
        end
        if t in ("-u", "-g", "-p", "-C", "-H")
            i += 2
            continue
        end
        if length(t) > 1 && t[2] != '-'
            chars = collect(t[2:end])
            j = 1
            needs_arg = false
            while j <= length(chars)
                c = chars[j]
                c in sudo_noarg && (j += 1; continue)
                if c in sudo_witharg
                    needs_arg = true
                    j += 1
                    break
                end
                j += 1
            end
            i += 1
            needs_arg && i <= n && (i += 1)
            continue
        end
        i += 1
    end
    return i
end

function shell_advance_past_wrapper(i::Int, toks::AbstractVector)
    n = length(toks)
    i > n && return i
    raw = String(toks[i])
    base = shell_token(raw)
    low = lowercase(base)
    if low == "env"
        i += 1
        while i <= n
            t = String(toks[i])
            if !startswith(t, "-")
                occursin("=", t) && (i += 1; continue)
                break
            end
            if t == "-u"
                i += 2
                continue
            end
            if t == "-i"
                i += 1
                continue
            end
            startswith(t, "-") && (i += 1; continue)
            break
        end
        return i
    end
    if low == "nice"
        i += 1
        i <= n || return i
        t = String(toks[i])
        if startswith(t, "-")
            m = match(r"^-(-?\d+)$", t)
            m !== nothing && (i += 1; return i)
            t == "-n" && (i += 2; return i)
            i += 1
        end
        return i
    end
    if low == "sudo"
        return shell_skip_sudo_opts(i + 1, toks)
    end
    if low == "timeout"
        i += 1
        while i <= n
            t = String(toks[i])
            if !startswith(t, "-")
                break
            end
            if t in ("-s", "-k", "-u", "-p")
                i += 2
                continue
            end
            if t == "-v"
                i += 1
                continue
            end
            i += 1
        end
        if i <= n && tryparse(Float64, String(toks[i])) !== nothing
            i += 1
        end
        return i
    end
    if low == "ssh"
        ssh_val = Set(
            [
                "-o",
                "-p",
                "-i",
                "-l",
                "-F",
                "-J",
                "-b",
                "-c",
                "-E",
                "-L",
                "-R",
                "-W",
                "-m",
                "-D",
            ]
        )
        i += 1
        while i <= n
            t = String(toks[i])
            if !startswith(t, "-")
                break
            end
            if occursin('=', t)
                i += 1
                continue
            end
            if t in ssh_val
                i += 2
                continue
            end
            i += 1
        end
        i <= n && (i += 1)
        if i <= n && String(toks[i]) == "--"
            i += 1
        end
        return i
    end
    if low == "xargs"
        i += 1
        while i <= n && startswith(String(toks[i]), "-")
            arg = String(toks[i])
            i += 1
            arg in ("-I", "-i", "-n", "-P", "-L", "-x") && i <= n && (i += 1)
        end
        return i
    end
    if low in SHELL_WRAPPERS
        return i + 1
    end
    return i
end

function shell_payload_after_sh(i::Int, toks::AbstractVector)
    n = length(toks)
    i > n && return nothing
    low = lowercase(shell_token(String(toks[i])))
    low in ("sh", "bash") || return nothing
    i += 1
    i > n && return nothing
    flags = String(toks[i])
    if flags == "-c"
        i += 1
        return i <= n ? join(String.(toks[i:n]), " ") : nothing
    end
    if startswith(flags, "-") && occursin('c', flags)
        i += 1
        return i <= n ? join(String.(toks[i:n]), " ") : nothing
    end
    return nothing
end

function process_kill_word(s::AbstractString)
    w = strip(s)
    isempty(w) && return nothing
    base = basename(replace(w, r"^['\"]|['\"]$" => ""))
    m = match(r"^([A-Za-z0-9_.+-]+)", base)
    m === nothing && return nothing
    word = lowercase(String(m.captures[1]))
    word in PROCESS_KILL_WORDS && return word
    occursin(BRACKET_TRICK_RE, w) && return "bracket"
    return nothing
end

function shell_segments(script::AbstractString)
    parts = String[]
    buf = IOBuffer()
    quote_ch = Char(0)
    escaped = false
    i = firstindex(script)
    while i <= lastindex(script)
        c = script[i]
        nxt = nextind(script, i)
        if escaped
            write(buf, c)
            escaped = false
            i = nxt
            continue
        end
        if c == '\\' && quote_ch != '\''
            write(buf, c)
            escaped = true
            i = nxt
            continue
        end
        if quote_ch == Char(0) && (c == '\'' || c == '"')
            quote_ch = c
            write(buf, c)
            i = nxt
            continue
        end
        if quote_ch != Char(0) && c == quote_ch
            quote_ch = Char(0)
            write(buf, c)
            i = nxt
            continue
        end
        if quote_ch == Char(0)
            two = nxt <= lastindex(script) ? string(c, script[nxt]) : ""
            if two in ("&&", "||")
                push!(parts, String(take!(buf)))
                i = nextind(script, nxt)
                continue
            end
            if c == ';' || c == '|'
                push!(parts, String(take!(buf)))
                i = nxt
                continue
            end
        end
        write(buf, c)
        i = nxt
    end
    push!(parts, String(take!(buf)))
    return filter(!isempty, strip.(parts))
end

function literal_command_text(node)::Union{Nothing, String}
    kind(node) == K"string" || return nothing
    parts = String[]
    for i in 1:numchildren(node)
        kind(node[i]) == K"String" || continue
        push!(parts, sourcetext(node[i]))
    end
    isempty(parts) && return string_literal_value(node)
    return join(parts, " ")
end

function command_position_kill(script::AbstractString; second::Bool = false)::Bool
    for seg in shell_segments(script)
        stripped = strip(seg)
        occursin(BRACKET_TRICK_RE, stripped) && return true
        toks = split(stripped)
        isempty(toks) && continue
        i = 1
        while i <= length(toks)
            raw = String(toks[i])
            base = shell_token(raw)
            low = lowercase(base)
            i0 = shell_advance_past_wrapper(i, toks)
            if i0 != i
                i = i0
                continue
            end
            payload = shell_payload_after_sh(i, toks)
            if payload !== nothing
                payload = strip(payload, ['"', '\''])
                command_position_kill(payload; second = true) && return true
                break
            end
            nxt = i < length(toks) ? shell_token(String(toks[i + 1])) : ""
            hit = process_kill_word(base) !== nothing ||
                (second && process_kill_word(nxt) !== nothing) ||
                occursin(BRACKET_TRICK_RE, raw)
            hit && return true
            break
        end
    end
    return false
end

function remote_shell_script_hit(s::AbstractString)
    w = strip(s)
    isempty(w) && return false
    process_kill_word(w) !== nothing && return true
    for tok in ("pkill", "pgrep", "killall")
        occursin(Regex("\\b" * tok * "\\b"), w) && return true
    end
    for run in (";", "&&", "||")
        occursin(run, w) || continue
        for tok in ("pkill", "pgrep", "killall")
            occursin(Regex("\\b" * tok * "\\b"), w) && return true
        end
    end
    return false
end

function folded_cmd_first_word(node, consts::Dict{String, String})
    s = fold_string_expr(node, consts)
    s === nothing && (s = string_literal_value(node))
    s === nothing && return nothing
    return process_kill_word(s)
end

function cmd_argv_vector(node)
    kind(node) == K"vect" && return node
    if kind(node) == K"ref" && numchildren(node) >= 2
        return node
    end
    if kind(node) == K"::" && numchildren(node) >= 1 && kind(node[1]) == K"vect"
        return node[1]
    end
    return nothing
end

function cmd_slot_word(node, consts::Dict{String, String})
    w = fold_string_expr(node, consts)
    w === nothing && (w = string_literal_value(node))
    if w === nothing && kind(node) == K"Identifier"
        w = get(consts, sourcetext(node), nothing)
    end
    if w === nothing
        w = which_kill_tool(node, consts)
    end
    return w
end

function cmd_argv_slots(vect, consts::Dict{String, String})
    start = kind(vect) == K"ref" ? 2 : 1
    slots = Union{Nothing, String}[]
    for i in start:numchildren(vect)
        push!(slots, cmd_slot_word(vect[i], consts))
    end
    return slots
end

function cmd_slots_kill(slots::Vector{Union{Nothing, String}})
    slots[1] === nothing && return nothing
    words = String[]
    for w in slots
        w !== nothing && push!(words, w)
    end
    isempty(words) && return nothing
    j = shell_advance_past_wrapper(1, words)
    tail = words[j:end]
    isempty(tail) && return nothing
    payload = shell_payload_after_sh(1, tail)
    if payload !== nothing
        return command_position_kill(payload; second = true) ? "pkill" : nothing
    end
    base = shell_token(tail[1])
    return process_kill_word(base) !== nothing ? "pkill" : nothing
end

function cmd_array_first_kill(node, consts::Dict{String, String})
    kind(node) == K"call" || return nothing
    call_head_name(node) == "Cmd" || return nothing
    numchildren(node) < 2 && return nothing
    arg = node[2]
    vect = cmd_argv_vector(arg)
    if vect !== nothing
        return cmd_slots_kill(cmd_argv_slots(vect, consts))
    end
    return folded_cmd_first_word(arg, consts)
end

function shell_sh_c_string(node, consts::Dict{String, String})
    kind(node) != K"call" && return nothing
    call_head_name(node) == "Cmd" || return nothing
    numchildren(node) < 2 && return nothing
    arg = node[2]
    vect = cmd_argv_vector(arg)
    vect === nothing && return nothing
    n = numchildren(vect)
    n < 2 && return nothing
    sh = fold_string_expr(vect[1], consts)
    sh === nothing && (sh = string_literal_value(vect[1]))
    sh === nothing && return nothing
    lowercase(sh) in ("sh", "bash") || return nothing
    for i in 2:(n - 1)
        fl = fold_string_expr(vect[i], consts)
        fl === nothing && (fl = string_literal_value(vect[i]))
        fl == "-c" || continue
        inner = fold_string_expr(vect[i + 1], consts)
        inner === nothing && (inner = string_literal_value(vect[i + 1]))
        inner === nothing && return nothing
        return command_position_kill(inner; second = true) ? "pkill" : nothing
    end
    return nothing
end

function expand_cmdstring_vars(inner::AbstractString, consts::Dict{String, String})
    out = String(inner)
    for m in eachmatch(r"\$\(\s*string\s*\(\s*\"([^\"]+)\"\s*\)\s*\)", out)
        out = replace(out, m.match => String(m.captures[1]))
    end
    for m in eachmatch(r"\$\(\s*\"([^\"]+)\"\s*\)", out)
        out = replace(out, m.match => String(m.captures[1]))
    end
    for pattern in (r"\$\((\w+)\)", r"\$(\w+)")
        for m in eachmatch(pattern, out)
            v = get(consts, String(m.captures[1]), nothing)
            v === nothing && continue
            out = replace(out, m.match => v)
        end
    end
    return out
end

function cmdstring_first_kill(node, consts::Dict{String, String})
    kind(node) == K"cmdstring" || return nothing
    inner = replace(sourcetext(node), r"^`+|`+$" => "")
    inner = expand_cmdstring_vars(inner, consts)
    return command_position_kill(inner) ? "pkill" : nothing
end

function which_kill_tool(node, consts::Dict{String, String})
    kind(node) == K"call" || return nothing
    call_head_name(node) in ("which", "Sys.which") || return nothing
    numchildren(node) < 2 && return nothing
    name = fold_string_expr(node[2], consts)
    name === nothing && (name = string_literal_value(node[2]))
    name === nothing && return nothing
    lowercase(strip(name)) in PROCESS_KILL_WORDS || return nothing
    return String(name)
end

function run_family_name(node)
    kind(node) == K"call" || return nothing
    return call_head_name(node)
end

function run_family_cmd_builder_hit(arg, consts::Dict{String, String})
    cmd_array_first_kill(arg, consts) !== nothing && return true
    shell_sh_c_string(arg, consts) !== nothing && return true
    cmdstring_first_kill(arg, consts) !== nothing && return true
    which_kill_tool(arg, consts) !== nothing && return true
    return false
end

function shellish_call_name(name::AbstractString)::Bool
    n = lowercase(name)
    return occursin("shell", n) || endswith(n, "_cmd")
end

function remote_shell_call_inner_hit(node, consts::Dict{String, String})
    kind(node) == K"call" || return false
    name = call_head_name(node)
    name === nothing && return false
    shellish_call_name(name) || return false
    numchildren(node) < 3 && return false
    inner = fold_string_expr(node[3], consts)
    inner === nothing && (inner = string_literal_value(node[3]))
    inner === nothing && return false
    return command_position_kill(inner)
end

function run_family_shell_arg_deep_hit(arg, consts::Dict{String, String})
    remote_shell_call_inner_hit(arg, consts) && return true
    run_family_cmd_builder_hit(arg, consts) && return true
    folded_cmd_first_word(arg, consts) !== nothing && return true
    kind(arg) == K"call" || return false
    if call_head_name(arg) in ("pipeline", "ignorestatus")
        for i in 2:numchildren(arg)
            run_family_shell_arg_deep_hit(arg[i], consts) && return true
        end
    end
    return false
end

function run_family_shell_arg_hit(node, consts::Dict{String, String})
    name = run_family_name(node)
    name in ("run", "pipeline", "open", "read", "success") || return false
    for i in 2:numchildren(node)
        arg = node[i]
        if name in ("open", "read")
            run_family_cmd_builder_hit(arg, consts) && return true
            if kind(arg) == K"call" && call_head_name(arg) in ("pipeline", "ignorestatus")
                for j in 2:numchildren(arg)
                    run_family_cmd_builder_hit(arg[j], consts) && return true
                end
            end
            continue
        end
        run_family_shell_arg_deep_hit(arg, consts) && return true
    end
    return false
end

function macro_is_cmd(node)
    kind(node) == K"macrocall" || return false
    h = macro_head_name(node)
    return h in ("@cmd", "cmd")
end

function cmd_macro_arg_hit(node, consts::Dict{String, String})
    macro_is_cmd(node) || return false
    for i in 1:numchildren(node)
        w = folded_cmd_first_word(node[i], consts)
        w !== nothing && return true
    end
    return false
end

function process_pattern_builder_hit(node, consts::Dict{String, String})
    cmd_macro_arg_hit(node, consts) && return true
    cmd_array_first_kill(node, consts) !== nothing && return true
    shell_sh_c_string(node, consts) !== nothing && return true
    cmdstring_first_kill(node, consts) !== nothing && return true
    remote_shell_call_inner_hit(node, consts) && return true
    run_family_shell_arg_hit(node, consts) && return true
    return false
end
