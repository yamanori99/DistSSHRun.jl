#!/usr/bin/env julia
# Name-only check: Queue and Kit `src/` may not gain a new non-public
# DistSSHRun, DistSSHBase, or DistSSHUp reference. Field reads are #201.
# `test/` is not scanned. Run from the Downstream job:
#   julia --startup-file=no --project=. .github/downstream_public.jl SRC_DIR

import Pkg

if abspath(PROGRAM_FILE) == @__FILE__
    Pkg.instantiate()
end

using DistSSHRun

# #57 exported `parse_ride_args`. Remaining entries wait for #201.
# #201 is the public-surface freeze. `main` is public, so it is not listed.
const DOWNSTREAM_PUBLIC_ALLOW = Dict{Tuple{Symbol, Symbol}, Int}(
    (:DistSSHBase, :_ssh_host_args) => 201,
    (:DistSSHBase, :_test_doubles_on) => 201,
    (:DistSSHRun, :KIT_PROGRESS) => 201,
    (:DistSSHRun, :KIT_PROGRESS_SUSPEND) => 201,
    (:DistSSHRun, :KitCliSession) => 201,
    (:DistSSHRun, :KitProgressState) => 201,
    (:DistSSHRun, :WORKER_MEMORY_GB_FALLBACK) => 201,
    (:DistSSHRun, :apply_kit_cli_session!) => 201,
    (:DistSSHRun, :close_log_file) => 201,
    (:DistSSHRun, :compute_worker_plan) => 201,
    (:DistSSHRun, :dist_ssh_kit_version) => 201,
    (:DistSSHRun, :get_local_git_hash) => 201,
    (:DistSSHRun, :kit_confirm) => 201,
    (:DistSSHRun, :kit_job_mark_comment) => 201,
    (:DistSSHRun, :kit_job_pkill_pattern) => 201,
    (:DistSSHRun, :kit_println) => 201,
    (:DistSSHRun, :kit_process_start_key) => 201,
    (:DistSSHRun, :kit_progress_done!) => 201,
    (:DistSSHRun, :kit_progress_latest) => 201,
    (:DistSSHRun, :kit_verbosity) => 201,
    (:DistSSHRun, :parse_plan_args) => 201,
    (:DistSSHRun, :parse_pool_args) => 201,
    (:DistSSHRun, :parse_size_args) => 201,
    (:DistSSHRun, :per_worker_gb_dict) => 201,
    (:DistSSHRun, :print_header) => 201,
    (:DistSSHRun, :print_size_report) => 201,
    (:DistSSHRun, :print_warn) => 201,
    (:DistSSHRun, :resolve_distributed_output_dir!) => 201,
    (:DistSSHRun, :resolve_worker_memory_samples) => 201,
    (:DistSSHRun, :resolved_placement_tokens) => 201,
    (:DistSSHRun, :set_kit_verbosity!) => 201,
    (:DistSSHRun, :setup_cli_host_token) => 201,
    (:DistSSHRun, :show_plan_usage) => 201,
    (:DistSSHRun, :show_pool_usage) => 201,
    (:DistSSHRun, :show_ride_usage) => 201,
    (:DistSSHRun, :show_size_usage) => 201,
    (:DistSSHRun, :writeln_field) => 201,
)

function _owner_module(owner::Symbol)::Module
    if owner === :DistSSHRun
        return DistSSHRun
    elseif owner === :DistSSHBase
        return DistSSHRun.DistSSHBase
    elseif owner === :DistSSHUp
        return DistSSHRun.DistSSHUp
    else
        error("downstream_public: unknown owner $(owner)")
    end
end

function _binding_is_public(owner::Symbol, name::Symbol)::Bool
    mod = _owner_module(owner)
    return isdefined(mod, name) && Base.ispublic(mod, name)
end

function _binding_label(owner::Symbol, name::Symbol)::String
    if owner === :DistSSHBase
        return "DistSSHRun.DistSSHBase.$(name)"
    elseif owner === :DistSSHUp
        return "DistSSHRun.DistSSHUp.$(name)"
    else
        return "DistSSHRun.$(name)"
    end
end

# Outermost name last. A one-argument `.` is a bare name, not a chain.
function _chain_names(ex)::Union{Nothing, Vector{Symbol}}
    names = Symbol[]
    node = ex
    while node isa Expr && node.head === :. && length(node.args) >= 2
        piece = node.args[2]
        if piece isa QuoteNode && piece.value isa Symbol
            push!(names, piece.value::Symbol)
        elseif piece isa Symbol
            push!(names, piece)
        else
            return nothing
        end
        node = node.args[1]
    end
    if node isa Symbol
        push!(names, node)
    elseif node isa Expr && node.head === :. && length(node.args) == 1 && node.args[1] isa Symbol
        push!(names, node.args[1]::Symbol)
    else
        return nothing
    end
    return reverse!(names)
end

# First name on DistSSHRun, DistSSHBase, or DistSSHUp. A further name is a field.
function _owner_and_name(chain::Vector{Symbol})::Union{Nothing, Tuple{Symbol, Symbol}}
    if length(chain) < 2 || chain[1] !== :DistSSHRun
        return nothing
    elseif chain[2] === :DistSSHBase
        length(chain) < 3 && return nothing
        return (:DistSSHBase, chain[3])
    elseif chain[2] === :DistSSHUp
        length(chain) < 3 && return nothing
        return (:DistSSHUp, chain[3])
    else
        return (:DistSSHRun, chain[2])
    end
end

function _import_name(ex)::Union{Nothing, Symbol}
    if ex isa Symbol
        return ex
    elseif ex isa Expr && ex.head === :. && length(ex.args) == 1 && ex.args[1] isa Symbol
        return ex.args[1]::Symbol
    elseif ex isa Expr && ex.head === :as && !isempty(ex.args)
        return _import_name(ex.args[1])
    else
        return nothing
    end
end

function _walk(ex, file::String, line::Base.RefValue{Int}, hits::Vector{Tuple{String, Int, Symbol, Symbol}})
    if ex isa LineNumberNode
        line[] = ex.line
        return nothing
    end
    ex isa Expr || return nothing
    if ex.head === :. && length(ex.args) >= 2
        chain = _chain_names(ex)
        if chain !== nothing
            picked = _owner_and_name(chain)
            if picked !== nothing
                push!(hits, (file, line[], picked[1], picked[2]))
            end
        end
        return nothing
    elseif ex.head === :using || ex.head === :import
        for arg in ex.args
            _walk_import(arg, file, line[], hits)
        end
        return nothing
    end
    for arg in ex.args
        _walk(arg, file, line, hits)
    end
    return nothing
end

function _walk_import(arg, file::String, line::Int, hits::Vector{Tuple{String, Int, Symbol, Symbol}})
    base = arg
    selected = Symbol[]
    if arg isa Expr && arg.head === :(:)
        base = arg.args[1]
        for name_ex in arg.args[2:end]
            name = _import_name(name_ex)
            name === nothing || push!(selected, name)
        end
    end
    isempty(selected) && return nothing
    chain = _chain_names(base)
    chain === nothing && return nothing
    picked = _owner_and_name(chain)
    # `using DistSSHRun.DistSSHBase: name` has no name after the submodule.
    owner = if picked !== nothing
        picked[1]
    elseif length(chain) == 2 && chain[1] === :DistSSHRun && chain[2] === :DistSSHBase
        :DistSSHBase
    elseif length(chain) == 2 && chain[1] === :DistSSHRun && chain[2] === :DistSSHUp
        :DistSSHUp
    elseif length(chain) == 1 && chain[1] === :DistSSHRun
        :DistSSHRun
    else
        return nothing
    end
    for name in selected
        push!(hits, (file, line, owner::Symbol, name))
    end
    return nothing
end

function _body_binds_run(ex)::Bool
    ex isa Expr || return false
    if ex.head === :call && !isempty(ex.args) && ex.args[1] === :_bind!
        for arg in ex.args[2:end]
            arg === :DistSSHRun && return true
        end
    end
    for arg in ex.args
        _body_binds_run(arg) && return true
    end
    return false
end

function _symbol_tuples!(ex, line::Base.RefValue{Int}, out::Dict{Symbol, Vector{Tuple{Symbol, Int}}})
    if ex isa LineNumberNode
        line[] = ex.line
        return nothing
    end
    ex isa Expr || return nothing
    if ex.head === :const && length(ex.args) == 1
        assign = ex.args[1]
        if assign isa Expr && assign.head === :(=) && length(assign.args) >= 2 &&
                assign.args[1] isa Symbol && assign.args[2] isa Expr &&
                assign.args[2].head === :tuple
            syms = Tuple{Symbol, Int}[]
            at = line[]
            for arg in assign.args[2].args
                if arg isa LineNumberNode
                    at = arg.line
                elseif arg isa QuoteNode && arg.value isa Symbol
                    push!(syms, (arg.value::Symbol, at))
                end
            end
            out[assign.args[1]::Symbol] = syms
        end
    end
    for arg in ex.args
        _symbol_tuples!(arg, line, out)
    end
    return nothing
end

function _bind_consts!(ex, found::Vector{Symbol})
    ex isa Expr || return nothing
    if ex.head === :for && length(ex.args) >= 2
        iter = ex.args[1]
        if iter isa Expr && iter.head === :(=) && length(iter.args) >= 2 &&
                iter.args[2] isa Symbol && _body_binds_run(ex.args[2])
            push!(found, iter.args[2]::Symbol)
        end
    end
    for arg in ex.args
        _bind_consts!(arg, found)
    end
    return nothing
end

function _scan_file!(path::String, root::String, hits::Vector{Tuple{String, Int, Symbol, Symbol}})
    ex = Meta.parseall(read(path, String); filename = path)
    rel = relpath(path, root)
    line = Ref(1)
    _walk(ex, rel, line, hits)
    tuples = Dict{Symbol, Vector{Tuple{Symbol, Int}}}()
    _symbol_tuples!(ex, Ref(1), tuples)
    consts = Symbol[]
    _bind_consts!(ex, consts)
    for const_name in consts
        for (name, at) in get(tuples, const_name, Tuple{Symbol, Int}[])
            push!(hits, (rel, at, :DistSSHRun, name))
        end
    end
    return nothing
end

function _scan_tree(srcdir::AbstractString)::Vector{Tuple{String, Int, Symbol, Symbol}}
    hits = Tuple{String, Int, Symbol, Symbol}[]
    root = abspath(String(srcdir))
    for (dir, _, files) in walkdir(root)
        for file in files
            endswith(file, ".jl") || continue
            _scan_file!(joinpath(dir, file), root, hits)
        end
    end
    return hits
end

"""Failures for `srcdir` (`src/` of Queue or Kit). Empty means the tree is allowed."""
function downstream_public_failures(
        srcdir::AbstractString;
        allow::Dict{Tuple{Symbol, Symbol}, Int} = DOWNSTREAM_PUBLIC_ALLOW,
    )::Vector{String}
    fails = String[]
    seen = Set{Tuple{String, Int, Symbol, Symbol}}()
    for (file, line, owner, name) in _scan_tree(srcdir)
        key = (file, line, owner, name)
        key in seen && continue
        push!(seen, key)
        _binding_is_public(owner, name) && continue
        haskey(allow, (owner, name)) && continue
        label = _binding_label(owner, name)
        push!(fails, "$(file):$(line): $(label) is not public")
    end
    for ((owner, name), issue) in allow
        _binding_is_public(owner, name) || continue
        label = _binding_label(owner, name)
        push!(fails, "allowlist: $(label) is public; remove the #$(issue) entry")
    end
    return sort!(fails)
end

function downstream_public_main(args::Vector{String})::Cint
    if length(args) != 1
        println(stderr, "usage: downstream_public.jl SRC_DIR")
        return Cint(2)
    end
    src = args[1]
    if !isdir(src)
        println(stderr, "downstream_public: not a directory: $(src)")
        return Cint(2)
    end
    fails = downstream_public_failures(src)
    if isempty(fails)
        n = length(DOWNSTREAM_PUBLIC_ALLOW)
        println("downstream public names: ok ($(n) allowlisted)")
        return Cint(0)
    end
    for line in fails
        println(stderr, line)
    end
    return Cint(1)
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(downstream_public_main(ARGS))
end
