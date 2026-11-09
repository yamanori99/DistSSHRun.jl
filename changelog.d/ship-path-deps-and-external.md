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
- `setup ship-tree --extra-file PATH` (single-use flag, a second occurrence
  is an error, only valid for `ship-tree`) stores that one file at
  `_distsshrun_external/<basename>` under the remote project. A symlink is
  followed once. Siblings are not sent. In-process `go!` / `drive!` with
  `sync=:ship_tree` use the same path for a script outside the project.
  Without `:ship_tree`, an outside script is still an error. Detached
  `execute!(…; sync=:ship_tree)` remains an error.
- The content hash covers project files, path dependencies, and that extra
  file by relative path and content. After extract, ship, pull, and
  `DistSSHShip.transfer_tree` walk symlinks and compare the `git-sha1` tree
  hash. `--allow-external-symlinks` keeps the old escape allowance.
- Shipping lives in `lib/DistSSHShip`, included by DistSSHRun the same way
  as DistSSHUp. It is not a `[deps]` entry and it is not registered.
  Queue should call `DistSSHShip.snapshot` then `DistSSHShip.transfer_tree`.
