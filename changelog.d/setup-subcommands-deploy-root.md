category: breaking

- `setup` operation modes are subcommands under the existing `setup`
  namespace (`setup ship-tree`, `setup instantiate`, `setup check`,
  `setup runtest`, `setup clone`, `setup sync`, `setup pull`,
  `setup cleanup`, `setup delete`, `setup prune`, `setup remote-root`).
  There is no top-level `ship` command. Legacy `setup --ship-tree` /
  `--instantiate` / `--check` and the other mode flags error with a
  migration line; they are not aliases. Multiple subcommands in one
  invocation still error before remote work. `setup remote-root` remains
  the directory-creation operation (absolute `--deploy-root PATH`; parent
  must exist; not `mkdir -p`). It is not a path-valued option.
- The deployment-location CLI option is `--deploy-root PATH` on `setup`,
  `go`, `drive`, and `ride`. `--remote-path` errors and names
  `--deploy-root`. `DISTRIBUTED_REMOTE_PROJECT_ROOT`, `session.remote`,
  and the default `~/Parent/Repo` layout from the local env_dir are
  unchanged. Omit `--deploy-root` to keep that default. Detached
  `execute!` writes `--deploy-root` into child argv. `go` / `drive`
  `--ship-tree` convenience flags are unchanged.
