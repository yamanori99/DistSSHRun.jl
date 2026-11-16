category: fixed

- `drive!` and `ride!` with `run_id` skip controller-local Manifest checks and worker precompile gates, but still verify workers homogeneously against the ship deploy record (`verified-against-run-id`); `last-ship.toml` is not used for that verification (only the in-memory or remote deploy record for the requested run id).
- Worker init loads a project package only when `src/<name>.jl` exists.
- Provenance records a missing Manifest as `absent` again.
- Launch reports count workers joined since the launch snapshot (`workers()` on Julia 1.13), not `nworkers() - 1`.
- `ride!` evicts unrelated workers before joining so a prior test job cannot leave a foreign process that breaks init.