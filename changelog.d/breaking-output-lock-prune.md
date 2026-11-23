category: breaking

- `.distssh.lock` replaces the pid-only `.kit.lock`. The record stores writer, host, pid, and start key. A foreign host or a malformed record is not taken and is not pruned. A mixed-version tree can contain both files; prune inspects `.distssh.lock` only, so a live older process that holds only `.kit.lock` does not stop prune and that leaf can be removed.
- `output_dir_lock!` replaces `kit_output_dir_lock!`. A pid-only `.kit.lock` is not a holder, so that function does not refuse the directory because the old file is present.
- `setup prune --id` matches the job id exactly. A go leaf with no job id is not selected. A live lock is refused and the command exits non-zero.
