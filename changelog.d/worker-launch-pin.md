category: breaking

- Detached `execute!` always uses `--project=` of the job tree. A job that
  does not list DistSSHKit or DistSSHRun in `[deps]` fails instead of using
  serve's active project.
- `go`, `ride`, and `drive` pin the real Julia binary (`Sys.BINDIR`), start
  with `--startup-file=no --history-file=no` and an explicit `--threads`,
  set worker `JULIA_LOAD_PATH=@:@stdlib` (local workers also add the parent
  project, then DistSSHRun's package directory), and unset `JULIA_PROJECT`
  so it cannot override `--project=`. SSH workers wrap the binary with
  `env -u … JULIA_LOAD_PATH=@:@stdlib` (not `env -u JULIA_LOAD_PATH`) and
  `cd` to the project root (not the script directory) and bind `127.0.0.1`
  with `tunnel=true`. SSH adds `ExitOnForwardFailure=yes`. Drive / ride
  workers and go slots error on Julia / DistSSH* / Manifest path mismatch
  unless `--allow-mismatch` lists `julia`, `distssh`, and/or `manifest`
  (Manifest format 2 `[[deps.Name]]` tables are read; a missing Manifest
  is a mismatch only when the parent job has one. `JuliaManifest.toml` vs
  `Manifest.toml` is a mismatch unless `manifest` is waived). Parent `LOAD_PATH`
  and `@v#.#` are no longer visible to workers. Worker `JULIA_LOAD_PATH`
  uses Unix `:` (native Windows is still unsupported).
