category: fixed

## Drive / ride snapshot runs

- `drive!` and `ride!` with `run_id` skip worker precompile gates and Manifest digest verification (recorded as unverified `run-id`), matching shipped sibling path dependencies.
- Worker init loads a project package only when `src/<name>.jl` exists.
- Provenance records a missing Manifest as `absent` again.
- Launch reports count workers joined since the launch snapshot (`workers()` on Julia 1.13), not `nworkers() - 1`.
- `ride!` evicts unrelated workers before joining so a prior test job cannot leave a foreign process that breaks init.