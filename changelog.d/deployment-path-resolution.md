category: breaking

- Deployment location resolution keeps the existing precedence (per-call
  `--remote-path` / `session.remote`, then caller
  `DISTRIBUTED_REMOTE_PROJECT_ROOT`, then the default `~/Parent/Repo` from
  the local package `env_dir`). `apply_session_env!` no longer writes
  `DISTRIBUTED_REMOTE_PROJECT_ROOT`, so one session's `remote=` cannot leak
  into a later session. Drive still sets that ENV inside
  `_with_drive_process!` (restored on exit) so worker path mapping keeps
  working. Overlapping in-process kit runs remain unsupported.
- `setup --ship-tree`, `go` / `drive` `--ship-tree`, and
  `sync!(mode=:ship_tree)` create a missing deployment root when safe: a
  `~/…` layout may create components under the remote home with mode
  `700`; an absolute path still requires its parent and creates only the
  final component. When `$HOME` is a symlink, `~/…` expansion is remapped
  onto `cd -P ~ && pwd -P` so a logical path is not refused as outside the
  physical home. Symlink targets, unsafe ownership or permissions, `/`,
  and the remote home are refused. Existing directories are not chmod'd.
  Transfer failure after create leaves the directory.
  `setup --remote-root` is unchanged (absolute `--remote-path` only).
  Ship still does not instantiate; go/drive instantiate after ship as
  before. This is location and root preparation only, not deterministic
  snapshot-source selection.
