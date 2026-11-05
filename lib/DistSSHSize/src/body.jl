using .DistSSHBase
using .DistSSHBase: PARENT_HOST_NAME, format_placement_token,
    get_remote_nproc, get_remote_total_gb, is_parent_host_name

include("worker_plan.jl")
include("compute_worker_plan.jl")

public DEFAULT_MEM_HEADROOM, DEFAULT_PARENT_GB
public WORKER_MEMORY_GB_FALLBACK, WORKER_MEMORY_GB_FLOOR, WORKER_RSS_SAFETY_FACTOR
public WorkerMemorySample, WorkerPlan
public effective_worker_gb, get_local_resources, per_worker_gb_dict
public resolved_placement_tokens, rss_bytes_to_worker_gb, size_worker_count
