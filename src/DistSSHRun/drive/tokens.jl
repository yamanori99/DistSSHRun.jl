# Resolve CLI-style worker tokens to a concrete [`WorkerPlan`](@ref).

"""
Build a [`WorkerPlan`](@ref) from tokens.

Every token must have `:N`. Omitted counts are not filled in here.
"""
function worker_plan_from_tokens(
        tokens::AbstractVector{<:AbstractString};
        head_workers::Union{Nothing, Integer} = nothing,
    )::WorkerPlan
    parsed = parse_worker_tokens(tokens; head_workers = head_workers)
    local_n = parsed.head_workers
    remotes = Dict{String, Int}(parsed.child_workers)

    worker_tokens_fully_specified(parsed) || throw(
        ArgumentError(explain_bare_placement_tokens(tokens; surface = :api)),
    )
    return WorkerPlan(local_n, remotes)
end
