# Explicit placement counts (`parent:N` / `NAME:N`). Not a size estimate.

"""Explicit worker counts per host (`head_workers` + `child_workers`)."""
struct WorkerPlan
    head_workers::Int
    child_workers::Dict{String, Int}
end

WorkerPlan() = WorkerPlan(0, Dict{String, Int}())

"""Resolved machine tokens from a [`WorkerPlan`](@ref) (local workers are not tokens)."""
function resolved_placement_tokens(plan::WorkerPlan)::Vector{String}
    out = String[]
    for (host, n) in plan.child_workers
        n > 0 && push!(out, DistSSHBase.format_machine_token(n, host))
    end
    return out
end

function resolved_placement_tokens(
        head_workers::Integer,
        hosts::AbstractVector{<:Tuple{<:AbstractString, <:Any}},
        default_workers,
    )::Vector{String}
    remotes = Dict{String, Int}()
    for pair in hosts
        remotes[pair[1]] = something(pair[2], default_workers, 1)
    end
    return resolved_placement_tokens(WorkerPlan(Int(head_workers), remotes))
end

public resolved_placement_tokens
