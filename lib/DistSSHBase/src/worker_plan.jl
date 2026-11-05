# Worker counts and the RSS→GB estimate shared by DistSSHRun and DistSSHPlan.
# The formula that turns these numbers into a count stays in DistSSHRun for now.

"""Default RAM fraction usable for workers (`size!` / `size` / drive preflight).

Leave a quarter of RAM for the OS and other jobs. Drive preflight uses the
same `mem_headroom` / `parent_gb` / CPU reserve as `size_worker_count`.
"""
const DEFAULT_MEM_HEADROOM = 0.75
"""GB reserved for the parent process on parent sizing (`size` / drive preflight)."""
const DEFAULT_PARENT_GB = 0.4
"""RSS→GB: 10% padding on the measured set (unexported; no CLI flag)."""
const WORKER_RSS_SAFETY_FACTOR = 1.1
"""RSS→GB floor after the safety factor (unexported; no CLI flag)."""
const WORKER_MEMORY_GB_FLOOR = 0.5
"""RSS→GB when RSS is unavailable (drive preflight / size fallback)."""
const WORKER_MEMORY_GB_FALLBACK = 1.5

"""
Convert RSS bytes to a per-worker GB estimate (safety factor + floor).
"""
function rss_bytes_to_worker_gb(rss_bytes::Integer)::Float64
    rss_bytes > 0 || return WORKER_MEMORY_GB_FALLBACK
    gb = rss_bytes / 1024^3 * WORKER_RSS_SAFETY_FACTOR
    return round(max(gb, WORKER_MEMORY_GB_FLOOR), digits = 2)
end

"""Sized worker counts per host (`parent_workers` + `child_workers`)."""
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
        hosts::AbstractVector{Tuple{String, Union{Int, Nothing}}},
        default_workers,
    )::Vector{String}
    remotes = Dict{String, Int}()
    for pair in hosts
        remotes[pair[1]] = something(pair[2], default_workers, 1)
    end
    return resolved_placement_tokens(WorkerPlan(Int(parent_workers), remotes))
end

"""
Per-host RSS sample from `measure_rss`.

`baseline_gb` is after package load. `peak_gb` is after an optional warm-up
probe script (equals baseline when no probe runs). Suggestions use
`effective_worker_gb` = `max(baseline, peak)`.
"""
struct WorkerMemorySample
    baseline_gb::Float64
    peak_gb::Float64
end

"""GB used for worker-count math (`max` of baseline and peak)."""
effective_worker_gb(s::WorkerMemorySample)::Float64 = max(s.baseline_gb, s.peak_gb)

"""Map host → effective GB for `compute_worker_plan`."""
function per_worker_gb_dict(samples::Dict{String, WorkerMemorySample})::Dict{String, Float64}
    return Dict{String, Float64}(h => effective_worker_gb(s) for (h, s) in samples)
end
