category: breaking

- **One `DISTSSH_` prefix.** Every `DISTRIBUTED_*` job variable is now `DISTSSH_*` with no alias. If an old name is set, the process errors and names the replacement (for example `DISTRIBUTED_SSH_OPTS` → `DISTSSH_SSH_OPTS`).
- **Fail closed.** `DISTSSH_JOBS`, heartbeat interval/deadline, named waits, `DISTSSH_INIT_DELAY_SEC`, `DISTSSH_PING_RETRIES`, `DISTSSH_JOB_SEED`, `DISTSSH_WORKER_RANK`, `DISTSSH_SSH_TUNNEL`, `DISTSSH_SKIP_COLLECT`, leftover-worker skip, `DISTSSH_PROGRESS_BG`, and other boolean flags reject unparsable values with an error that names the variable. Unset `DISTSSH_JOB_SEED` still draws a random seed.
- **User table.** `docs/src/options.md` lists every user-facing variable from `src/DistSSHRun/options/env_table.jl`. Parent-to-child hand-offs use `DISTSSH_INTERNAL_*` and are not options.
- **`go` slot SSH** uses the same `DISTSSH_JOBS` cap as host jobs (default 1).
- DistSSHQueue still writes `DISTRIBUTED_PROJECT_ROOT` / `DISTRIBUTED_REMOTE_PROJECT_ROOT` until it locksteps.
