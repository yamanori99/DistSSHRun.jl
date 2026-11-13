# Drive publish extract. Independent of `script_scan.jl`.

function _drive_call_name(f)::Union{Nothing, Symbol}
    f isa Symbol && return f
    return nothing
end

function _drive_is_short_method(ex::Expr)::Bool
    ex.head === :(=) || return false
    lhs = ex.args[1]
    lhs isa Expr || return false
    h = lhs.head
    h === :call && return true
    h === :where && return true
    return h === :(::) && lhs.args[1] isa Expr && lhs.args[1].head === :call
end

function _drive_is_include_call(ex::Expr)::Bool
    ex.head === :call && !isempty(ex.args) || return false
    return _drive_call_name(ex.args[1]) === :include
end

function _drive_keep_publish(ex)::Bool
    ex isa Expr || return false
    h = ex.head
    h in (:function, :macro, :struct, :abstract, :primitive, :using, :import, :module, :const) &&
        return true
    _drive_is_short_method(ex) && return true
    return _drive_is_include_call(ex)
end

function _drive_nested_include_line(ex, line::Int)::Union{Nothing, Int}
    if ex isa LineNumberNode
        return nothing
    end
    ex isa Expr || return nothing
    _drive_is_include_call(ex) && return line
    found = nothing
    cur = line
    for a in ex.args
        if a isa LineNumberNode
            cur = Int(a.line)
            continue
        end
        loc = _drive_nested_include_line(a, cur)
        if loc !== nothing && found === nothing
            found = loc
        end
    end
    return found
end

function _drive_skipped_include_warn(line::Int)::String
    return string(
        "  warn: line ",
        line,
        ": include(...) inside if/||/&& is not published (use a bare include, or --worker-include)\n",
    )
end

function _drive_print_skipped_include_warns!(warns::Vector{String})
    isempty(warns) && return nothing
    return with_kit_progress_suspended() do
        for msg in warns
            print_warn(endswith(msg, '\n') ? msg : msg * "\n")
        end
        return nothing
    end
end

function _drive_collect_publish!(
        pieces::Vector{Any},
        warns::Vector{String},
        ex;
        line::Int = 1,
    )
    if ex isa LineNumberNode
        return
    end
    ex isa Expr || return
    h = ex.head
    if h === :block || h === :toplevel
        cur = line
        for a in ex.args
            if a isa LineNumberNode
                cur = Int(a.line)
                continue
            end
            _drive_collect_publish!(pieces, warns, a; line = cur)
        end
        return
    end
    if _drive_keep_publish(ex)
        push!(pieces, ex)
        return
    end
    loc = _drive_nested_include_line(ex, line)
    loc !== nothing && push!(warns, _drive_skipped_include_warn(loc))
    return
end

"""Worker source: defs / `using` / `import` / `include`, not top-level work.

Also returns warn lines for nested `include(...)` that publish drops.
"""
function _drive_publish_extract(script_path::AbstractString)::Tuple{String, Vector{String}}
    path = String(script_path)
    src = read(path, String)
    expr = Meta.parseall(src; filename = path)
    pieces = Any[]
    warns = String[]
    _drive_collect_publish!(pieces, warns, expr)
    body = isempty(pieces) ? "" : sprint(print, Expr(:block, pieces...))
    return body, warns
end

"""Worker source: defs / `using` / `import` / `include`, not top-level work."""
function _drive_publish_source(
        script_path::AbstractString;
        warn_skipped_include::Bool = true,
    )::String
    src, warns = _drive_publish_extract(script_path)
    warn_skipped_include && _drive_print_skipped_include_warns!(warns)
    return src
end
