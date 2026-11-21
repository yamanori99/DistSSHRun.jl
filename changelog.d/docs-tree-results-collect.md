category: docs

- `drive --help` and the user guide name `DISTRIBUTED_COLLECT_DIRS`, the default collect root, re-drive `(nothing to collect)` / `--collect-missing`, worker ENV that is actually set, ship-tree `run.toml` for run id and tree hash, and `.distssh/` in `.gitignore`. `go --help` states that only the slot output directory comes back. `#513`
- `drive` no longer warns on `@everywhere include(...)`. When `Project.toml` has `name` but no `src/<name>.jl`, the line names that file instead of "no package name". `#513`
