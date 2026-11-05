# `plan` — inspect a script; do not start a job.

const _PLAN_DRIVE_CALLS = (
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

const _PLAN_DRIVE_MACROS = (
    Symbol("@distributed"),
    Symbol("@everywhere"),
    Symbol("@spawn"),
    Symbol("@spawnat"),
    Symbol("@fetch"),
    Symbol("@fetchfrom"),
)

"""Experimental. One syntax finding from [`plan`](@ref).

`plan` may change in a 0.2 patch. Pin `DistSSHRun = "=0.2.0"` to keep this surface.
[`size!`](@ref) and [`WorkerPlan`](@ref) are not experimental.
"""
struct PlanFinding
    line::Int
    kind::Symbol
    status::Symbol
    excerpt::String
end

"""Experimental. Result of [`plan`](@ref). Does not start a job.

`plan` may change in a 0.2 patch. Pin `DistSSHRun = "=0.2.0"` to keep this surface.
[`size!`](@ref) and [`WorkerPlan`](@ref) are not experimental.
"""
struct KitPlan
    script::String
    suggest::Symbol
    findings::Vector{PlanFinding}
    julia::String
    ok::Bool
    error::Union{Nothing, String}
    slots::Union{Nothing, WorkerPlan}
end

"""Bare callee (`map`, `workers`). A qualified name such as `Foo.pmap` is not bare."""
function _plan_call_name(f)::Union{Nothing, Symbol}
    f isa Symbol && return f
    return nothing
end

"""Pieces of `A.B.name`, left to right. A one-argument `.` is a single piece."""
function _plan_dot_chain(ex)::Union{Nothing, Vector{Symbol}}
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
function _plan_note_import!(bound::Dict{Symbol, Symbol}, ex)::Nothing
    ex isa Expr && ex.head in (:using, :import) || return nothing
    for arg in ex.args
        arg isa Expr && arg.head === :(:) && length(arg.args) >= 2 || continue
        modpath = _plan_dot_chain(arg.args[1])
        modpath === nothing && continue
        source = modpath[end] === :Distributed ? :distributed : :other
        for spec in arg.args[2:end]
            chain = _plan_dot_chain(spec)
            chain === nothing && continue
            length(chain) == 1 || continue
            bound[chain[1]] = source
        end
    end
    return nothing
end

function _plan_is_drive_name(name::Symbol, bound::Dict{Symbol, Symbol})::Bool
    (name in _PLAN_DRIVE_CALLS || name in _PLAN_DRIVE_MACROS) || return false
    return get(bound, name, :distributed) === :distributed
end

"""`Distributed.pmap` / `Distributed.@everywhere`. `Foo.pmap` is not."""
function _plan_qualified_drive(head)::Bool
    chain = _plan_dot_chain(head)
    chain === nothing && return false
    length(chain) < 2 && return false
    name = chain[end]
    chain[end - 1] === :Distributed || return false
    return name in _PLAN_DRIVE_CALLS || name in _PLAN_DRIVE_MACROS
end

function _plan_is_method_lhs(ex)::Bool
    ex isa Expr || return false
    h = ex.head
    h === :call && return true
    h === :where && return _plan_is_method_lhs(ex.args[1])
    if h === :(::) && !isempty(ex.args)
        return _plan_is_method_lhs(ex.args[1])
    end
    return false
end

"""`:map`, `:filter`, `:comprehension`, or `:for` when [`_ride_rewrite`](@ref) rewrites this expr."""
function _plan_candidate_kind(ex)::Union{Nothing, Symbol}
    ex isa Expr || return nothing
    h = ex.head
    if h === :call && length(ex.args) == 3
        name = _plan_call_name(ex.args[1])
        name === :map && return :map
        name === :filter && return :filter
    elseif h === :comprehension && length(ex.args) == 1
        gen = ex.args[1]
        gen isa Expr && gen.head === :generator && length(gen.args) == 2 || return nothing
        it = gen.args[2]
        it isa Expr && it.head === :(=) && length(it.args) == 2 || return nothing
        return :comprehension
    elseif h === :for && _plan_index_fill_for(ex) !== nothing
        return :for
    end
    return nothing
end

function _plan_parse_failed(ex)::Bool
    ex isa Expr || return false
    ex.head in (:error, :incomplete) && return true
    return any(_plan_parse_failed, ex.args)
end

function _plan_parse_error_message(ex)::String
    if ex isa Expr && ex.head in (:error, :incomplete) && !isempty(ex.args)
        err = ex.args[1]
        if err isa Exception
            return sprint(showerror, err)
        end
    end
    ex isa Expr || return ""
    for a in ex.args
        msg = _plan_parse_error_message(a)
        isempty(msg) || return msg
    end
    return ""
end

function _plan_excerpt(ex; max::Int = 72)::String
    s = replace(sprint(show, ex), r"\s+" => " ")
    n = ncodeunits(s)
    n <= max && return s
    i = prevind(s, max)
    return s[1:i] * "…"
end

function _plan_push!(
        acc::Vector{PlanFinding},
        line::Int,
        kind::Symbol,
        status::Symbol,
        ex,
    )
    push!(acc, PlanFinding(line, kind, status, _plan_excerpt(ex)))
    return nothing
end

function _plan_expr_mentions_symbol(ex, name::Symbol)::Bool
    ex === name && return true
    ex isa Expr || return false
    for a in ex.args
        a isa LineNumberNode && continue
        _plan_expr_mentions_symbol(a, name) && return true
    end
    return false
end

function _plan_expr_has_escape(ex)::Bool
    ex isa Expr || return false
    h = ex.head
    h in (:break, :continue, :return) && return true
    for a in ex.args
        _plan_expr_has_escape(a) && return true
    end
    return false
end

function _plan_for_body_stmts(body)::Vector{Any}
    body isa Expr && body.head === :block || return Any[body]
    stmts = Any[]
    for a in body.args
        a isa LineNumberNode && continue
        a isa Expr && a.head === :linenumber && continue
        push!(stmts, a)
    end
    return stmts
end

"""
Indexed fill `for i in iter; dest[i] = rhs; end` with no `dest` in `rhs`.
Workers can compute `rhs`; the parent writes `dest` afterward.
"""
function _plan_rhs_index_is_loop_var(ex, var::Symbol)::Bool
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
        _plan_rhs_index_is_loop_var(a, var) || return false
    end
    return true
end

function _plan_index_fill_for(ex::Expr)
    ex.head === :for || return nothing
    length(ex.args) == 2 || return nothing
    it, body = ex.args
    it isa Expr && it.head === :(=) && length(it.args) == 2 || return nothing
    var = it.args[1]
    var isa Symbol || return nothing
    iter = it.args[2]
    stmts = _plan_for_body_stmts(body)
    length(stmts) == 1 || return nothing
    asg = stmts[1]
    asg isa Expr && asg.head === :(=) && length(asg.args) == 2 || return nothing
    lhs, rhs = asg.args
    lhs isa Expr && lhs.head === :ref && length(lhs.args) == 2 || return nothing
    dest = lhs.args[1]
    dest isa Symbol || return nothing
    lhs.args[2] === var || return nothing
    _plan_expr_mentions_symbol(rhs, dest) && return nothing
    _plan_expr_has_escape(rhs) && return nothing
    _plan_rhs_index_is_loop_var(rhs, var) || return nothing
    return (var = var, iter = iter, dest = dest, rhs = rhs)
end

function _plan_walk_signature!(
        acc::Vector{PlanFinding},
        sig,
        line::Int,
        bound::Dict{Symbol, Symbol},
    )::Int
    sig isa Expr || return _plan_walk!(acc, sig, line, bound)
    h = sig.head
    if h === :where || (h === :(::) && !isempty(sig.args) && sig.args[1] isa Expr)
        line = _plan_walk_signature!(acc, sig.args[1], line, bound)
        for a in sig.args[2:end]
            line = _plan_walk!(acc, a, line, bound)
        end
        return line
    end
    if h === :call && !isempty(sig.args)
        for a in sig.args[2:end]
            line = _plan_walk!(acc, a, line, bound)
        end
        return line
    end
    return _plan_walk!(acc, sig, line, bound)
end

function _plan_walk!(
        acc::Vector{PlanFinding},
        ex,
        line::Int,
        bound::Dict{Symbol, Symbol} = Dict{Symbol, Symbol}(),
    )::Int
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
        _plan_note_import!(bound, ex)
    elseif h === :(=) && !isempty(args) && _plan_is_method_lhs(args[1])
        line = _plan_walk_signature!(acc, args[1], line, bound)
        for a in args[2:end]
            line = _plan_walk!(acc, a, line, bound)
        end
        return line
    elseif h === :function && !isempty(args) && _plan_is_method_lhs(args[1])
        line = _plan_walk_signature!(acc, args[1], line, bound)
        for a in args[2:end]
            line = _plan_walk!(acc, a, line, bound)
        end
        return line
    elseif h === :macrocall && !isempty(args)
        m = args[1]
        bare = m isa Symbol ? m : nothing
        drive = (bare !== nothing && _plan_is_drive_name(bare, bound)) || _plan_qualified_drive(m)
        if drive
            ln = line
            length(args) >= 2 && args[2] isa LineNumberNode && (ln = args[2].line)
            _plan_push!(acc, ln, :distributed, :drive_vocab, ex)
        end
    elseif h === :call && !isempty(args)
        name = _plan_call_name(args[1])
        if (name !== nothing && _plan_is_drive_name(name, bound)) || _plan_qualified_drive(args[1])
            _plan_push!(acc, line, :distributed, :drive_vocab, ex)
        else
            kind = _plan_candidate_kind(ex)
            kind === nothing || _plan_push!(acc, line, kind, :candidate, ex)
        end
    else
        kind = _plan_candidate_kind(ex)
        if kind === :for
            _plan_push!(acc, line, :for, :candidate, ex)
        elseif h === :for
            _plan_push!(acc, line, :for, :out_of_scope, ex)
        elseif kind !== nothing
            _plan_push!(acc, line, kind, :candidate, ex)
        end
    end
    for a in args
        line = _plan_walk!(acc, a, line, bound)
    end
    return line
end

function _plan_suggest(findings::Vector{PlanFinding})::Symbol
    any(f -> f.status === :drive_vocab, findings) && return :drive
    any(f -> f.status === :candidate, findings) && return :ride
    return :go
end

"""
    plan(script; session=nothing, workers=[], project=pwd(),
         gb_per_worker=nothing, probe=nothing, mem_headroom, parent_gb) -> KitPlan

Experimental. Inspect `script` without starting a job. May change in a 0.2 patch.
Pin `DistSSHRun = "=0.2.0"` to keep this surface. [`size!`](@ref) and
[`WorkerPlan`](@ref) are not experimental.

Syntax only: Distributed vocabulary,
`map` / `filter` / comprehensions, and independent indexed `for`
(`dest[i] = …` with loop-var indices and no `return` in the RHS).
Accumulating, stencil, or multi-statement `for` is out of scope.
Effect analysis is not applied at this stage.

Suggests `:drive`, `:ride`, or `:go`. The caller still chooses the command.

Slot estimates (`slots::WorkerPlan`) run only when `session` is given, or
when `workers` / `gb_per_worker` / `probe` request sizing. That path calls
[`size!`](@ref) internally. Default is syntax only (no SSH probe).
"""
function plan(
        script::AbstractString;
        session::Union{Nothing, KitSession} = nothing,
        workers::AbstractVector{<:AbstractString} = String[],
        project::AbstractString = pwd(),
        gb_per_worker::Union{Nothing, Real} = nothing,
        probe::Union{Nothing, AbstractString} = nothing,
        mem_headroom::Real = DEFAULT_MEM_HEADROOM,
        parent_gb::Real = DEFAULT_PARENT_GB,
    )::KitPlan
    path = _as_string(script)
    julia = string(VERSION)
    empty = KitPlan(
        path, :go, PlanFinding[], julia, false, "file not found: $path", nothing,
    )
    isfile(path) || return empty
    src = read(path, String)
    expr = try
        Meta.parseall(src; filename = path)
    catch e
        return KitPlan(
            path, :go, PlanFinding[], julia, false, sprint(showerror, e), nothing,
        )
    end
    if _plan_parse_failed(expr)
        msg = _plan_parse_error_message(expr)
        isempty(msg) && (msg = "syntax error")
        return KitPlan(path, :go, PlanFinding[], julia, false, msg, nothing)
    end
    findings = PlanFinding[]
    _plan_walk!(findings, expr, 1)
    suggest = _plan_suggest(findings)
    want_size = session !== nothing || !isempty(workers) ||
        gb_per_worker !== nothing || probe !== nothing
    slots = nothing
    err = nothing
    ok = true
    if want_size
        sess = if session !== nothing
            session
        else
            KitSession(;
                project = project,
                workers = workers,
                yes = true,
                quiet = true,
            )
        end
        try
            slots = size!(
                sess;
                gb_per_worker = gb_per_worker,
                probe = probe,
                mem_headroom = mem_headroom,
                parent_gb = parent_gb,
            )
        catch e
            ok = false
            err = sprint(showerror, e)
        end
    end
    return KitPlan(path, suggest, findings, julia, ok, err, slots)
end

function _plan_status_label(st::Symbol)::String
    st === :candidate && return "distributable (syntax)"
    st === :out_of_scope && return "out of scope (rewrite as map)"
    st === :drive_vocab && return "Distributed vocabulary"
    return String(st)
end

"""Experimental. Print a [`KitPlan`](@ref) (CLI and tests).

`plan` may change in a 0.2 patch. Pin `DistSSHRun = "=0.2.0"` to keep this surface.
[`size!`](@ref) and [`WorkerPlan`](@ref) are not experimental.
"""
function print_plan(kp::KitPlan; io::IO = stdout)
    println(io, "Planning ", kp.script, "...")
    println(io)
    if !kp.ok
        println(io, "  error: ", something(kp.error, "unknown"))
        return nothing
    end
    if isempty(kp.findings)
        println(io, "  (no map / filter / comprehension / for / Distributed calls)")
        println(io)
    else
        for f in kp.findings
            loc = "$(basename(kp.script)):$(f.line)"
            println(
                io, "  ", rpad(loc, 28), " ", rpad(String(f.kind), 14), " ",
                _plan_status_label(f.status)
            )
        end
        println(io)
    end
    cmd = String(kp.suggest)
    println(io, "  suggest:  ", cmd, " ", kp.script)
    if kp.slots !== nothing
        toks = resolved_placement_tokens(kp.slots)
        if isempty(toks)
            println(io, "  slots:    (none)")
        else
            println(io, "  slots:    ", join(toks, " "))
        end
    end
    println(io, "  julia:    ", kp.julia, " / syntax")
    kp.suggest === :ride && println(
        io,
        "  note:     effect_free is not proven here; ride decides at run time"
    )
    kp.suggest === :go && any(f -> f.status === :out_of_scope, kp.findings) &&
        println(io, "  note:     rewrite independent loops as map or a comprehension")
    return nothing
end
