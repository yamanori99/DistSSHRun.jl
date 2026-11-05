category: breaking

- `WorkerPlan`, `WorkerMemorySample`, `resolved_placement_tokens`, the RSS→GB constants, and `rss_bytes_to_worker_gb` are defined in `DistSSHBase`. `DistSSHRun` still exports `WorkerPlan`. Counts and GB values are unchanged. `size_worker_count` stays in `DistSSHRun`. `WORKER_RSS_SAFETY_FACTOR` and `WORKER_MEMORY_GB_FLOOR` are `DistSSHBase` names.
