category: breaking

- Worker sizing (`WorkerPlan`, `compute_worker_plan`, `size_worker_count`, `get_local_resources`, `resolved_placement_tokens`, `WorkerMemorySample`, and the RSS constants) is defined in `DistSSHSize`. `parentmodule` is `DistSSHRun.DistSSHSize`. `DistSSHRun` still exports `WorkerPlan` and rebinds the same functions. Counts, constants, and defaults are unchanged. `DistSSHBase` no longer defines these names.
