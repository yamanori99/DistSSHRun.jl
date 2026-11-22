category: breaking

- `.distssh.lock` replaces the pid-only `.kit.lock`. The record stores writer, host, pid, and start key. A foreign host or a malformed record is not taken and is not pruned. `output_dir_lock!` replaces `kit_output_dir_lock!`.
- `setup prune --id` matches the job id exactly. A go leaf with no job id is not selected. A live lock is refused and the command exits non-zero.
