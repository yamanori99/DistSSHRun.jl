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
  with `tunnel=true`. SSH adds `ExitOnForwardFailure=yes`. Environment
  verification compares Julia version and commit, DistSSH* `pkg.*` versions,
  and Manifest and Project byte digests (`identity_mismatches`; paths and lock
  file names are not compared). A controller with no Manifest digest fails
  before worker or remote launch unless `--unsafe-heterogeneous` is set (see
  `worker-env-manifest-fail-closed` fragment). Identity hashing uses whatever
  Manifest Base resolves for `--project=` (including `Manifest-v{major}.{minor}.toml`;
  format 2 `[[deps.Name]]` tables are read). A remote Julia that cannot print
  `Sys.BINDIR` fails instead
  of launching the starter path. Parent `LOAD_PATH`
  and `@v#.#` are no longer visible to workers. Worker `JULIA_LOAD_PATH`
  uses Unix `:` (native Windows is still unsupported).
