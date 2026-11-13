# Private syntax scan for `ride!`. Not a lib. Publish does not call this.

const _SCRIPT_DRIVE_CALLS = (
    :pmap,
    :worker_pmap,
    :remotecall,
    :remotecall_fetch,
    :remotecall_wait,
    :remote_do,
    :workers,
    :nworkers,
    :addprocs,
    :rmprocs,
)

const _SCRIPT_DRIVE_MACROS = (
    Symbol("@distributed"),
    Symbol("@everywhere"),
    Symbol("@spawn"),
    Symbol("@spawnat"),
    Symbol("@fetch"),
    Symbol("@fetchfrom"),
)

"""Bare callee (`map`, `workers`). A qualified name such as `Foo.pmap` is not bare."""
function _plan_call_name(f)::Union{Nothing, Symbol}
    f isa Symbol && return f
    return nothing
end

"""Pieces of `A.B.name`, left to right. A one-argument `.` is a single piece."""
function _script_dot_chain(ex)::Union{Nothing, Vector{Symbol}}
    ex isa Symbol && return Symbol[ex]
    ex isa QuoteNode && ex.value isa Symbol && return Symbol[ex.value::Symbol]
    ex isa Expr && ex.head === :. || return nothing
    parts = Symbol[]
    node = ex
    while node isa Expr && node.head === :.
        piece = node.args[end]
        name = if piece isa QuoteNode && piece.value isa Symbol
            piece.value::Symbol
        elseif piece isa Symbol
            piece
        else
            return nothing
        end
        push!(parts, name)
        if length(node.args) == 1
            return reverse!(parts)
        end
        node = node.args[1]
    end
    if node isa Symbol
        push!(parts, node)
    elseif node isa QuoteNode && node.value isa Symbol
        push!(parts, node.value::Symbol)
    else
        return nothing
    end
    return reverse!(parts)
end

"""`:distributed` when an explicit `using` / `import` binds `name` from Distributed; `:other` otherwise."""
function _script_note_import!(bound::Dict{Symbol, Symbol}, ex)::Nothing
    ex isa Expr && ex.head in (:using, :import) || return nothing
    for arg in ex.args
        arg isa Expr && arg.head === :(:) && length(arg.args) >= 2 || continue
        modpath = _script_dot_chain(arg.args[1])
        modpath === nothing && continue
        source = modpath[end] === :Distributed ? :distributed : :other
        for spec in arg.args[2:end]
            chain = _script_dot_chain(spec)
            chain === nothing && continue
            length(chain) == 1 || continue
            bound[chain[1]] = source
        end
    end
    return nothing
end

function _script_is_drive_name(name::Symbol, bound::Dict{Symbol, Symbol})::Bool
    (name in _SCRIPT_DRIVE_CALLS || name in _SCRIPT_DRIVE_MACROS) || return false
    return get(bound, name, :distributed) === :distributed
end

"""`Distributed.pmap` / `Distributed.@everywhere`. `Foo.pmap` is not."""
function _script_qualified_drive(head)::Bool
    chain = _script_dot_chain(head)
    chain === nothing && return false
    length(chain) < 2 && return false
    name = chain[end]
    chain[end - 1] === :Distributed || return false
    return name in _SCRIPT_DRIVE_CALLS || name in _SCRIPT_DRIVE_MACROS
end

function _script_is_method_lhs(ex)::Bool
    ex isa Expr || return false
    h = ex.head
    h === :call && return true
    h === :where && return _script_is_method_lhs(ex.args[1])
    if h === :(::) && !isempty(ex.args)
        return _script_is_method_lhs(ex.args[1])
    end
    return false
end

function _script_parse_failed(ex)::Bool
    ex isa Expr || return false
    ex.head in (:error, :incomplete) && return true
    return any(_script_parse_failed, ex.args)
end

function _script_parse_error_message(ex)::String
    if ex isa Expr && ex.head in (:error, :incomplete) && !isempty(ex.args)
        err = ex.args[1]
        if err isa Exception
            return sprint(showerror, err)
        end
    end
    ex isa Expr || return ""
    for a in ex.args
        msg = _script_parse_error_message(a)
        isempty(msg) || return msg
    end
    return ""
end

function _script_excerpt(ex; max::Int = 72)::String
    s = replace(sprint(show, ex), r"\s+" => " ")
    n = ncodeunits(s)
    n <= max && return s
    i = prevind(s, max)
    return s[1:i] * "…"
end

function _script_expr_mentions_symbol(ex, name::Symbol)::Bool
    ex === name && return true
    ex isa Expr || return false
    for a in ex.args
        a isa LineNumberNode && continue
        _script_expr_mentions_symbol(a, name) && return true
    end
    return false
end

function _script_expr_has_escape(ex)::Bool
    ex isa Expr || return false
    h = ex.head
    h in (:break, :continue, :return) && return true
    for a in ex.args
        _script_expr_has_escape(a) && return true
    end
    return false
end

function _script_for_body_stmts(body)::Vector{Any}
    body isa Expr && body.head === :block || return Any[body]
    stmts = Any[]
    for a in body.args
        a isa LineNumberNode && continue
        a isa Expr && a.head === :linenumber && continue
        push!(stmts, a)
    end
    return stmts
end

function _script_rhs_index_is_loop_var(ex, var::Symbol)::Bool
    ex isa Expr || return true
    if ex.head === :ref
        length(ex.args) == 2 || return false
        ex.args[2] === var || return false
    elseif ex.head === :call && _plan_call_name(ex.args[1]) === :getindex
        length(ex.args) == 3 || return false
        ex.args[3] === var || return false
    end
    for a in ex.args
        a isa LineNumberNode && continue
        _script_rhs_index_is_loop_var(a, var) || return false
    end
    return true
end

"""
Indexed fill `for i in iter; dest[i] = rhs; end` with no `dest` in `rhs`.
Workers can compute `rhs`; the parent writes `dest` afterward.
"""
function _plan_index_fill_for(ex::Expr)
    ex.head === :for || return nothing
    length(ex.args) == 2 || return nothing
    it, body = ex.args
    it isa Expr && it.head === :(=) && length(it.args) == 2 || return nothing
    var = it.args[1]
    var isa Symbol || return nothing
    iter = it.args[2]
    stmts = _script_for_body_stmts(body)
    length(stmts) == 1 || return nothing
    asg = stmts[1]
    asg isa Expr && asg.head === :(=) && length(asg.args) == 2 || return nothing
    lhs, rhs = asg.args
    lhs isa Expr && lhs.head === :ref && length(lhs.args) == 2 || return nothing
    dest = lhs.args[1]
    dest isa Symbol || return nothing
    lhs.args[2] === var || return nothing
    _script_expr_mentions_symbol(rhs, dest) && return nothing
    _script_expr_has_escape(rhs) && return nothing
    _script_rhs_index_is_loop_var(rhs, var) || return nothing
    return (var = var, iter = iter, dest = dest, rhs = rhs)
end

function _script_scan_signature!(
        hit::Ref{Union{Nothing, Tuple{Int, String}}},
        sig,
        line::Int,
        bound::Dict{Symbol, Symbol},
    )::Int
    sig isa Expr || return _script_scan_walk!(hit, sig, line, bound)
    h = sig.head
    if h === :where || (h === :(::) && !isempty(sig.args) && sig.args[1] isa Expr)
        line = _script_scan_signature!(hit, sig.args[1], line, bound)
        for a in sig.args[2:end]
            line = _script_scan_walk!(hit, a, line, bound)
        end
        return line
    end
    if h === :call && !isempty(sig.args)
        for a in sig.args[2:end]
            line = _script_scan_walk!(hit, a, line, bound)
        end
        return line
    end
    return _script_scan_walk!(hit, sig, line, bound)
end

function _script_scan_walk!(
        hit::Ref{Union{Nothing, Tuple{Int, String}}},
        ex,
        line::Int,
        bound::Dict{Symbol, Symbol},
    )::Int
    hit[] !== nothing && return line
    if ex isa LineNumberNode
        return ex.line
    elseif !(ex isa Expr)
        return line
    end
    h = ex.head
    args = ex.args
    if h === :linenumber && !isempty(args) && args[1] isa Integer
        return Int(args[1])
    end
    if h in (:using, :import)
        _script_note_import!(bound, ex)
    elseif h === :(=) && !isempty(args) && _script_is_method_lhs(args[1])
        line = _script_scan_signature!(hit, args[1], line, bound)
        for a in args[2:end]
            line = _script_scan_walk!(hit, a, line, bound)
        end
        return line
    elseif h === :function && !isempty(args) && _script_is_method_lhs(args[1])
        line = _script_scan_signature!(hit, args[1], line, bound)
        for a in args[2:end]
            line = _script_scan_walk!(hit, a, line, bound)
        end
        return line
    elseif h === :macrocall && !isempty(args)
        m = args[1]
        bare = m isa Symbol ? m : nothing
        drive = (bare !== nothing && _script_is_drive_name(bare, bound)) ||
            _script_qualified_drive(m)
        if drive
            ln = line
            length(args) >= 2 && args[2] isa LineNumberNode && (ln = args[2].line)
            hit[] = (ln, _script_excerpt(ex))
            return line
        end
    elseif h === :call && !isempty(args)
        name = _plan_call_name(args[1])
        if (name !== nothing && _script_is_drive_name(name, bound)) ||
                _script_qualified_drive(args[1])
            hit[] = (line, _script_excerpt(ex))
            return line
        end
    end
    for a in args
        line = _script_scan_walk!(hit, a, line, bound)
        hit[] !== nothing && return line
    end
    return line
end

"""Parse `path` for `ride!`. `error` is set on missing file or parse failure."""
function _script_scan(script::AbstractString)
    path = String(script)
    if !isfile(path)
        return (error = "file not found: $path", drive_line = nothing, drive_excerpt = nothing)
    end
    src = read(path, String)
    expr = try
        Meta.parseall(src; filename = path)
    catch e
        return (error = sprint(showerror, e), drive_line = nothing, drive_excerpt = nothing)
    end
    if _script_parse_failed(expr)
        msg = _script_parse_error_message(expr)
        isempty(msg) && (msg = "syntax error")
        return (error = msg, drive_line = nothing, drive_excerpt = nothing)
    end
    hit = Ref{Union{Nothing, Tuple{Int, String}}}(nothing)
    _script_scan_walk!(hit, expr, 1, Dict{Symbol, Symbol}())
    if hit[] === nothing
        return (error = nothing, drive_line = nothing, drive_excerpt = nothing)
    end
    ln, excerpt = hit[]
    return (error = nothing, drive_line = ln, drive_excerpt = excerpt)
end
