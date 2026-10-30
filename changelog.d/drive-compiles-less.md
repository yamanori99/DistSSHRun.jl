category: changed

- The first `drive` in a process compiles less. `plan` is no longer inferred inside `run_drive_parsed!`, a drive without `--sync` or `--ship-tree` does not infer that path, and that call is precompiled. The text and the exit code do not change. Loading the package from a project still needs that project's dependencies instantiated.
