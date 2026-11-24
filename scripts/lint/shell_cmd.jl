# Shell command-building context for process-pattern (included into Main).

const PROCESS_KILL_WORDS = ("pkill", "killall", "pgrep")

function process_kill_word(s::AbstractString)
    w = strip(s)
    isempty(w) && return nothing
    m = match(r"^([A-Za-z0-9_]+)", w)
    m === nothing && return nothing
    word = lowercase(String(m.captures[1]))
    word in PROCESS_KILL_WORDS && return word
    return nothing
end

function folded_cmd_first_word(node, consts::Dict{String, String})
    s = fold_string_expr(node, consts)
    s === nothing && (s = string_literal_value(node))
    s === nothing && return nothing
    return process_kill_word(s)
end

function cmd_argv_vector(node)
    kind(node) == K"vect" && return node
    # Typed argv: String["pgrep"] parses as (::)(vect, Type) in JuliaSyntax.
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
        return folded_cmd_first_word(vect[1], consts)
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
        return folded_cmd_first_word(vect[i + 1], consts)
    end
    return nothing
end

function cmdstring_first_kill(node)
    kind(node) == K"cmdstring" || return nothing
    if numchildren(node) >= 1
        return process_kill_word(sourcetext(node[1]))
    end
    return process_kill_word(replace(sourcetext(node), r"^`+|`+$" => ""))
end

function run_family_name(node)
    kind(node) == K"call" || return nothing
    return call_head_name(node)
end

function run_family_cmd_builder_hit(arg, consts::Dict{String, String})
    cmd_array_first_kill(arg, consts) !== nothing && return true
    shell_sh_c_string(arg, consts) !== nothing && return true
    cmdstring_first_kill(arg) !== nothing && return true
    return false
end

function run_family_shell_arg_hit(node, consts::Dict{String, String})
    name = run_family_name(node)
    name in ("run", "pipeline", "open", "read", "success") || return false
    for i in 2:numchildren(node)
        arg = node[i]
        # open/read take a filename string; only Cmd/backtick builders count.
        if name in ("open", "read")
            run_family_cmd_builder_hit(arg, consts) && return true
            continue
        end
        folded_cmd_first_word(arg, consts) !== nothing && return true
        run_family_cmd_builder_hit(arg, consts) && return true
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
    run_family_shell_arg_hit(node, consts) && return true
    return false
end
