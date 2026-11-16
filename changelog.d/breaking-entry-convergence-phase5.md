category: breaking

- Detached `execute!` writes a versioned `job.toml` under the run directory and starts children with bootstrap argv only (`-m DistSSHKit KIND -y --job-blob PATH`). Unknown blob schema fails closed. Placement host env vars are scrubbed in the child after the blob loads.
- `collect!` gains `remote_root=` and records skipped hosts on [`CollectResult`](@ref). Collect fails when any host is skipped unless `best_effort=true` or drive `--best-effort` on a collect-only invocation. Removed `--collect-strict` and `strict=`.
- `pipeline!` and `PipelineConfig` accept `run_id=` forwarded to `drive!` and `collect!`.
- In-process `execute!` accepts an `ExecuteEnvelope` for keyword parity.
- CLI `setup` subcommands for check, ship-tree, instantiate, and related modes call `setup!`; check runs SSH diagnostics before selection errors fail the command.
- `juliaup_status_lines` defaults to fail-closed (`strict=true`). Worker project precompile uses one shared path that warns on stderr instead of swallowing errors.