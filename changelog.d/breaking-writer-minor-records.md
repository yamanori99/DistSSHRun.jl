category: breaking

- On-disk and remote records no longer carry per-format `schema` or `schema_version` integers. Each record carries `writer = "<package> <version>"` from the writing package's `Project.toml`. Readers accept a record only when the writer's `major.minor` matches their own (patch and prerelease may differ).
- Records from an earlier minor are rejected. Rerun `setup` for remote trees, ship again for `last-ship.toml`, rewrite detached `job.toml`, and rerun jobs that wrote local stamps.
- Removed public `DETACHED_JOB_BLOB_SCHEMA`. Loaded-identity wire reports use `writer=` instead of `schema=`; mismatch kind is `writer_skew` (not `schema_skew`). `COMPONENT_ID` no longer has a `schema` field. Go handshake frames use `DISTSSH-REPORT/major.minor` instead of `DISTSSH-REPORT/1`.