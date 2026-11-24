# String constant folding and split-token detection for diff_lint.jl (included into Main).

const FOLD_CONST_PASS = 2

function fold_module_consts!(tree, consts::Dict{String, String})
    function walk(node)
        if kind(node) == K"const" && numchildren(node) >= 2
            lhs = node[1]
            rhs = node[2]
            if kind(lhs) == K"Identifier"
                v = fold_string_expr(rhs, consts; partial = false)
                v !== nothing && (consts[sourcetext(lhs)] = v)
            end
        end
        for i in 1:numchildren(node)
            walk(node[i])
        end
        return
    end
    for _ in 1:FOLD_CONST_PASS
        walk(tree)
    end
    return
end

function fold_string_expr(node, consts::Dict{String, String}; partial::Bool = false)::Union{Nothing, String}
    v = try_fold_string_expr(node, consts)
    v !== nothing && return v
    partial || return nothing
    return fold_string_expr_partial(node, consts)
end

function try_fold_string_expr(node, consts::Dict{String, String})
    if kind(node) == K"string" || kind(node) == K"String"
        return string_literal_value_src(node, "")
    end
    kind(node) == K"call" || return nothing
    head = call_head_name(node)
    head == "Symbol" && return fold_symbol_string(node, consts)
    head == "string" && return fold_string_call(node, consts)
    head == "String" && numchildren(node) >= 2 && return fold_string_expr(node[2], consts)
    if is_star_call(node)
        return fold_star_call(node, consts)
    end
    if head == "join"
        return fold_join_call(node, consts)
    end
    if head == "repeat"
        return fold_repeat_call(node, consts)
    end
    if head in ("prod", "reduce") && occursin("*", sourcetext(node))
        return fold_prod_reduce_star(node, consts)
    end
    return nothing
end

function fold_string_expr_partial(node, consts::Dict{String, String})
    kind(node) == K"string" && return string_literal_value_src(node, "")
    kind(node) != K"call" && return nothing
    if call_head_name(node) == "string"
        io = IOBuffer()
        for i in 2:numchildren(node)
            part = fold_string_expr(node[i], consts; partial = true)
            part === nothing && return nothing
            write(io, part)
        end
        return String(take!(io))
    end
    is_star_call(node) || return nothing
    return fold_star_operands(star_operands(node), consts; partial = true)
end

function fold_star_operands(ops, consts; partial::Bool = false)
    isempty(ops) && return nothing
    io = IOBuffer()
    for op in ops
        p = fold_string_expr(op, consts; partial = partial)
        p === nothing && return nothing
        write(io, p)
    end
    return String(take!(io))
end

function is_star_call(node)
    kind(node) == K"call" || return false
    return sourcetext(node[1]) == "*" || (numchildren(node) >= 3 && sourcetext(node[2]) == "*")
end

# JuliaSyntax keeps a * b * c as one call with every operand.
function star_operands(node)
    if sourcetext(node[1]) == "*"
        return [node[i] for i in 2:numchildren(node)]
    end
    ops = Any[node[1]]
    for i in 3:numchildren(node)
        push!(ops, node[i])
    end
    return ops
end

function fold_symbol_string(node, consts)
    call_head_name(node) == "Symbol" || return nothing
    parts = String[]
    for i in 2:numchildren(node)
        p = fold_string_expr(node[i], consts)
        p === nothing && return nothing
        push!(parts, p)
    end
    return string(Symbol(parts...))
end

function fold_string_call(node, consts)
    io = IOBuffer()
    for i in 2:numchildren(node)
        p = fold_string_expr(node[i], consts)
        p === nothing && return nothing
        write(io, p)
    end
    return String(take!(io))
end

function fold_star_call(node, consts)
    return fold_star_operands(star_operands(node), consts; partial = false)
end

function fold_join_call(node, consts)
    # join(iterator) or join(iterator, delim); delim defaults to "".
    numchildren(node) < 2 && return nothing
    parts = fold_string_vector(node[2], consts)
    parts === nothing && return nothing
    sep = ""
    if numchildren(node) >= 3
        s = fold_string_expr(node[3], consts)
        s === nothing && return nothing
        sep = s
    end
    return join(parts, sep)
end

function fold_string_vector(node, consts)
    if kind(node) == K"vect"
        out = String[]
        for i in 1:numchildren(node)
            p = fold_string_expr(node[i], consts)
            p === nothing && return nothing
            push!(out, p)
        end
        return out
    end
    if kind(node) == K"string"
        v = string_literal_value_src(node, "")
        v === nothing && return nothing
        return [v]
    end
    return nothing
end

const FOLD_REPEAT_MAX_CHARS = 4096

function fold_repeat_call(node, consts)
    numchildren(node) < 3 && return nothing
    s = fold_string_expr(node[2], consts)
    n = fold_int_literal(node[3])
    (s === nothing || n === nothing) && return nothing
    n < 0 && return nothing
    # Refuse huge expansions while scanning source (keeps lint bounded).
    typemax(Int) ÷ max(sizeof(s), 1) < n && return nothing
    sizeof(s) * n > FOLD_REPEAT_MAX_CHARS && return nothing
    return repeat(s, n)
end

function fold_int_literal(node)
    txt = sourcetext(node)
    m = match(r"^-?\d+$", strip(txt))
    if m !== nothing
        v = try
            Base.parse(Int, m.match)
        catch
            return nothing
        end
        return v
    end
    kind(node) == K"call" && call_head_name(node) == "-" && numchildren(node) >= 2 || return nothing
    inner = fold_int_literal(node[2])
    inner === nothing && return nothing
    return -inner
end

function fold_prod_reduce_star(node, consts)
    # reduce(*, ["a", "b"]) or prod(...)
    return fold_join_call(node, consts) # simplify: same as join for string vect
end

const SPLIT_TOKEN_CHAR = r"[A-Za-z0-9_]"

function split_token_bad_join(left::AbstractString, right::AbstractString)::Bool
    (isempty(left) || isempty(right)) && return false
    return occursin(SPLIT_TOKEN_CHAR, string(last(left))) && occursin(SPLIT_TOKEN_CHAR, string(first(right)))
end

function folded_string_parts(node, consts::Dict{String, String})::Union{Vector{String}, Nothing}
    if kind(node) == K"string"
        v = string_literal_value_src(node, "")
        v === nothing && return nothing
        return [v]
    end
    kind(node) == K"call" || return nothing
    if call_head_name(node) == "string"
        out = String[]
        for i in 2:numchildren(node)
            sub = folded_string_parts(node[i], consts)
            sub === nothing && return nothing
            append!(out, sub)
        end
        return out
    end
    if is_star_call(node)
        out = String[]
        for op in star_operands(node)
            sub = folded_string_parts(op, consts)
            sub === nothing && return nothing
            append!(out, sub)
        end
        return out
    end
    if call_head_name(node) == "Symbol"
        # Keep argument boundaries so Symbol("A", "B") stays a split.
        out = String[]
        for i in 2:numchildren(node)
            sub = folded_string_parts(node[i], consts)
            sub === nothing && return nothing
            append!(out, sub)
        end
        return out
    end
    v = try_fold_string_expr(node, consts)
    v === nothing && return nothing
    return [v]
end

function split_token_candidate(node)
    kind(node) == K"call" || return false
    head = call_head_name(node)
    head in ("string", "Symbol", "join") && return true
    return is_star_call(node)
end

function split_token_expr_hit(node, consts::Dict{String, String})::Bool
    split_token_candidate(node) || return false
    parts = folded_string_parts(node, consts)
    parts === nothing && return false
    parts = filter(!isempty, parts)
    length(parts) < 2 && return false
    for i in 1:(length(parts) - 1)
        split_token_bad_join(parts[i], parts[i + 1]) && return true
    end
    return false
end

function split_token_path(path::AbstractString)::Bool
    p = replace(String(path), '\\' => '/')
    startswith(p, "src/") && return true
    startswith(p, "test/") && return true
    startswith(p, "scripts/") && return true
    occursin(r"^lib/[^/]+/src/", p) && return true
    return occursin(r"^lib/[^/]+/test/", p)
end
