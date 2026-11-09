category: breaking

- `setup ship-tree` ships relative path dependencies, including ones outside
  the project directory, under their common ancestor. A parent `.gitignore`
  no longer drops a declared path dependency. Files that dependency's own
  `.gitignore` names are still left out, including a force-added file.
  A workspace member ships the workspace `Project.toml` and the shared
  Manifest at that ancestor and does not walk sibling members. An absolute
  `[sources]` path is still an error. A layout that would root the tar at
  `$HOME` or `/` is an error. The recorded project path is
  `runs/<run_id>/src` plus the project directory inside that tar.
- `setup ship-tree --extra-file PATH` may be repeated and is only valid
  for `ship-tree`. This version accepts one path; a second is
  `more than one extra file is not yet supported`. The same limit and
  message apply to `setup!`, `sync!`, and `snapshot` `extra_files`.
  The file is stored at `_distsshrun_external/<basename>` under the remote
  project. A symlink is followed once. Siblings are not sent. In-process
  `go!` / `drive!` with `sync=:ship_tree` use that path for one script
  outside the project. Detached `execute!(…; sync=:ship_tree)` stays an
  error before spawn. After the ship, `execute!(…; snapshot=id)` and
  `go` / `drive --snapshot ID` run that same local script; the remote
  command is `remote_script_path`. Without `:ship_tree` or `snapshot=`,
  an outside script is still an error.
- The content hash covers project files, path dependencies, and that extra
  file by relative path and content. After extract, ship, pull, and
  `DistSSHShip.transfer_tree` walk symlinks and compare the `git-sha1` tree
  hash. `--allow-external-symlinks` keeps the old escape allowance.
- Shipping lives in `lib/DistSSHShip`, included by DistSSHRun the same way
  as DistSSHUp. It is not a `[deps]` entry and it is not registered.
  Queue packs with `DistSSHShip.snapshot(project; extra_files=[script])`,
  places that tar with `transfer_tree` or `ship`, and runs
  `execute!(…; detached=true, snapshot=id)` on the same local script.
  `ship` writes the run id and completion stamp that `snapshot=` selects.
  `transfer_tree` extracts the same tar, including
  `_distsshrun_external/<basename>`, and does not allocate that id.
