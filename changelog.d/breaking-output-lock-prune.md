category: breaking

- `.distssh.lock` replaces the pid-only `.kit.lock`. The record stores writer, host, pid, and start key. A foreign host or a malformed record is not taken and is not pruned. A mixed-version tree can contain both files; prune inspects `.distssh.lock` only, so a live older process that holds only `.kit.lock` does not stop prune and that leaf can be removed.
- While a holder owns `.distssh.lock`, the acquirer also creates `.distssh.lock.hold.<pid>.<ns>` as a hard link to that inode so release can match inode and bytes. A normal release removes the hold link. If the process exits before release, the hold file can remain next to `.distssh.lock`; it is not another lock and does not block a new acquirer, but it shows the directory was not released cleanly.
- `output_dir_lock!` replaces `kit_output_dir_lock!`. A pid-only `.kit.lock` is not a holder, so that function does not refuse the directory because the old file is present.
- `setup prune --id` matches the text after the last `_YYYYMMDDTHHMMSSZ` and an optional `-<digits>` suffix. A leaf with no such text is not selected. A live lock is refused and the command exits non-zero.
