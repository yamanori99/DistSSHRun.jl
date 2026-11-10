category: breaking

- Setup git modes: CLI `setup clone` / `setup sync` / `setup pull` and flags
  `--clone` / `--sync` / `--pull` are errors. Use `setup git-clone`,
  `setup git-sync`, and `setup git-pull`. API `setup!(…, :clone|:sync|:pull)`
  → `:git_clone`, `:git_sync`, `:git_pull`. `sync! mode=:sync` →
  `mode=:git_sync`.
- Pre-run git copy on `go` / `drive`: `--sync` and `sync=:sync` are errors.
  Use `--git-sync` and `sync=:git_sync`. `go --skip-sync` →
  `--skip-git-sync` (`--skip-git-guard` is unchanged).
- Drive worker script sync: `drive --sync-script` and `drive! sync_script=` are
  errors. Use `drive --worker-include` and `drive! worker_include=`.
- `pipeline!` / `SYNC_MODE=sync` is an error; use `git-sync` or omit for no
  pre-run sync.
- `--git-sync` / `sync=:git_sync` cannot combine with `--run-id` / `run_id=`
  (same as the old `--sync` rule; error messages use the new flag names).
