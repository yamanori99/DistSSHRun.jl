category: changed

- `size_worker_count` and `get_local_resources` are defined in `DistSSHBase`. Callers in `DistSSHRun` use those functions. Counts are unchanged, including `nproc === nothing` (RAM only) and a missing remote `nproc` coerced to 1.
