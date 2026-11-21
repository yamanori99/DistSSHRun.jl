category: breaking

- Launch ranks are fixed per host before workers start. A host that fails before `addprocs` does not shift later workers to lower ranks or change their `DISTSSH_WORKER_SEED`.
- `worker_pmap` seeds the default RNG per collection item from `job_item_seed`. The first `rand` in the callback matches `rand(Random.Xoshiro(item_seed), T)` for that item. Worker count and `pmap` batch size do not change that stream. Pass `batch_size` to match plain `Distributed.pmap`.
