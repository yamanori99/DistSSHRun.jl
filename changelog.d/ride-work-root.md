category: fixed

- `ride!` with SSH children points `DISTRIBUTED_REMOTE_PROJECT_ROOT` at `runs/<id>/src` when the deploy root has no `Project.toml`, same as `drive`. A `Project.toml` at the deploy root still wins. A parent-only ride is unchanged. `ride` is experimental.
