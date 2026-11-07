# Explicit placement counts (`parent:N` / `child:NAME:N`). Not a size estimate.

"""Explicit worker counts per host (`parent_workers` + `child_workers`)."""
struct WorkerPlan
    parent_workers::Int
    child_workers::Dict{String, Int}
end

WorkerPlan() = WorkerPlan(0, Dict{String, Int}())

"""Resolved `parent:N` / `child:NAME:N` lines from a [`WorkerPlan`](@ref)."""
function resolved_placement_tokens(plan::WorkerPlan)::Vector{String}
    out = String[]
    plan.parent_workers > 0 &&
        push!(out, format_placement_token(:parent, PARENT_HOST_NAME, plan.parent_workers))
    for (host, n) in plan.child_workers
        n > 0 && push!(out, format_placement_token(:child, host, n))
    end
    return out
end

function resolved_placement_tokens(
        parent_workers::Integer,
        hosts::AbstractVector{<:Tuple{<:AbstractString, <:Any}},
        default_workers,
    )::Vector{String}
    remotes = Dict{String, Int}()
    for pair in hosts
        remotes[pair[1]] = something(pair[2], default_workers, 1)
    end
    return resolved_placement_tokens(WorkerPlan(Int(parent_workers), remotes))
end

public resolved_placement_tokens
