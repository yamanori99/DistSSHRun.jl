category: added

- `setup --remote-root` creates the directory given by an absolute `--remote-path`. The parent must already exist. `mkdir` is not `mkdir -p`. A symlink at that path is refused. The directory must be owned by the SSH user and must not be group-writable or world-writable. No marker file is written, and `runs/` is not created. A `~` path or `DISTRIBUTED_REMOTE_PROJECT_ROOT` is not used.
