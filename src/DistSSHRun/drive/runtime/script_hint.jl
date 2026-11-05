# Drive publish extract and the plain-script hint.
# Included after `plan.jl`: these call `_plan_call_name`, `plan`, and `KitPlan`.
# `_drive_script_hint_now` uses `invokelatest` so `run_drive_parsed!` does not infer `plan`.

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
    return _plan_call_name(ex.args[1]) === :include
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
        ": include(...) inside if/||/&& is not published (use a bare include, or --sync-script)\n",
    )
end

function _drive_print_skipped_include_warns!(warns::Vector{String})
    isempty(warns) && return nothing
    return with_kit_progress_suspended() do
        for msg in warns
            print_warn(msg)
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

function _drive_plain_script_hint(
        kp::KitPlan;
        shown::AbstractString = kp.script,
    )::String
    cmd = String(kp.suggest)
    shown_s = String(shown)
    return string(
        "drive: no Distributed vocabulary in this file (plan suggests $cmd)\n",
        "  $shown_s\n\n",
        "  Load is this include (once). Publish sends defs / using / include to workers.\n",
        "  Run is main() if defined; otherwise Load is the run. plan scans this file only.\n",
        "  Full-file worker include: --sync-script. Rewrite or independent slots:\n\n",
        "    julia --project=. -m DistSSHKit $cmd $shown_s",
    )
end

"""Same words as [`_drive_plain_script_hint`](@ref), compiled apart from `drive`.

`plan` is syntax-only here, but inferring it also infers `size!`. Resolving
the call when the hint runs keeps that tree out of `run_drive_parsed!`.
"""
function _drive_script_hint_now(
        script_path::AbstractString,
        project::AbstractString;
        shown::AbstractString,
    )::Union{Nothing, String}
    return Base.invokelatest(
        _drive_plain_script_hint,
        script_path,
        project;
        shown = shown,
    )
end

"""`nothing` if this file has Distributed vocabulary; otherwise a warning body."""
function _drive_plain_script_hint(
        script_path::AbstractString,
        project::AbstractString;
        shown::AbstractString = script_path,
    )::Union{Nothing, String}
    kp = plan(script_path; project = project)
    kp.ok || return nothing
    any(f -> f.status === :drive_vocab, kp.findings) && return nothing
    return _drive_plain_script_hint(kp; shown = shown)
end
