category: breaking

- Collect, `collect!`, and go slot pull-back use stdlib Tar instead of rsync. Remote mtimes are not kept. A symlink that points outside the copied tree is refused. The extract step uses an empty local directory. Cache pull is still rsync.
