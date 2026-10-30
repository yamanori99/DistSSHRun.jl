category: breaking

- Each worker gets a seed from the job seed and its launch rank (`DISTSSHKIT_JOB_SEED`, `DISTSSHKIT_WORKER_RANK`, `DISTSSHKIT_WORKER_SEED`). The rank is the order workers were started, not `myid()`. `worker_pmap` records item-to-rank in provenance under `seeds`, schema 1. `OPENBLAS_NUM_THREADS` and `OMP_NUM_THREADS` are set only when `DISTSSHKIT_BLAS_THREADS` is set. A present `CondaPkg.toml`, `conda-lock.yml`, or `pixi.lock` is hashed into provenance. Unknown provenance source keys stay ignored.
