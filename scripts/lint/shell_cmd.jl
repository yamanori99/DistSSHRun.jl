# Shell command-building context for process-pattern (included into Main).

const PROCESS_KILL_WORDS = ("pkill", "killall", "pgrep")
const SHELL_WRAPPERS = ("sudo", "env", "nice", "command", "nohup")
const BRACKET_TRICK_RE = r"(^|[^A-Za-z0-9_])\[[A-Za-z]\][A-Za-z]"

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
    s = replace(script, "&&" => "\n", "||" => "\n")
    s = replace(s, ';' => '\n', '|' => '\n')
    return split(s, '\n'; keepempty = false)
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
        toks = split(strip(seg))
        isempty(toks) && continue
        i = 1
        while i <= length(toks)
            raw = String(toks[i])
            base = basename(replace(raw, r"^['\"]|['\"]$" => ""))
            low = lowercase(base)
            if low in SHELL_WRAPPERS
                i += 1
                continue
            end
            if low == "timeout"
                i += 1
                i <= length(toks) && (i += 1)
                continue
            end
            if low in ("sh", "bash") && i < length(toks) && String(toks[i + 1]) == "-c"
                payload = join(String.(toks[(i + 2):end]), " ")
                payload = strip(payload, ['"', '\''])
                command_position_kill(payload; second = true) && return true
                break
            end
            nxt = i < length(toks) ? basename(replace(String(toks[i + 1]), r"^['\"]|['\"]$" => "")) : ""
            return process_kill_word(base) !== nothing ||
                (second && process_kill_word(nxt) !== nothing) ||
                occursin(BRACKET_TRICK_RE, raw)
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
    # Typed argv String["pgrep"] is a ref whose later children are the elements.
    if kind(node) == K"ref" && numchildren(node) >= 2
        return node
    end
    if kind(node) == K"::" && numchildren(node) >= 1 && kind(node[1]) == K"vect"
        return node[1]
    end
    return nothing
end

function cmd_array_first_kill(node, consts::Dict{String, String})
    kind(node) == K"call" || return nothing
    call_head_name(node) == "Cmd" || return nothing
    numchildren(node) < 2 && return nothing
    arg = node[2]
    vect = cmd_argv_vector(arg)
    if vect !== nothing
        numchildren(vect) < 1 && return nothing
        words = String[]
        for i in 1:numchildren(vect)
            w = fold_string_expr(vect[i], consts)
            w === nothing && (w = string_literal_value(vect[i]))
            if w === nothing && kind(vect[i]) == K"Identifier"
                w = get(consts, sourcetext(vect[i]), nothing)
            end
            w === nothing && which_kill_tool(vect[i], consts) !== nothing && (w = which_kill_tool(vect[i], consts))
            push!(words, something(w, ""))
        end
        any(isempty, words) && (words = filter(!isempty, words))
        isempty(words) && return nothing
        return command_position_kill(join(words, " ")) ? "pkill" : nothing
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

function cmdstring_first_kill(node)
    kind(node) == K"cmdstring" || return nothing
    inner = replace(sourcetext(node), r"^`+|`+$" => "")
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
    cmdstring_first_kill(arg) !== nothing && return true
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
        # open/read take a filename string; only Cmd/backtick builders count.
        if name in ("open", "read")
            run_family_shell_arg_deep_hit(arg, consts) && return true
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
    cmdstring_first_kill(node) !== nothing && return true
    remote_shell_call_inner_hit(node, consts) && return true
    run_family_shell_arg_hit(node, consts) && return true
    return false
end
