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
  with `tunnel=true`. SSH adds `ExitOnForwardFailure=yes`. When the controller
  has a non-empty Manifest byte digest (`manifest.sha256` from `run_identity`),
  drive / ride workers and go slots compare Julia version and commit,
  DistSSH* `pkg.*` versions, and Manifest and Project byte digests via
  `identity_mismatches` (paths and lock file names are not compared; only
  digest bytes). When the controller digest is empty, both
  `verify_workers_match_job!` and `verify_go_slots_match_job!` return before
  any of those comparisons (including Julia version/commit and Project
  digest). `--unsafe-heterogeneous` skips verification for that job the same
  way (no per-field waiver). Identity hashing uses whatever Manifest Base
  resolves for `--project=` (including `Manifest-v{major}.{minor}.toml`;
  format 2 `[[deps.Name]]` tables are read). A remote Julia that cannot print
  `Sys.BINDIR` fails instead
  of launching the starter path. Parent `LOAD_PATH`
  and `@v#.#` are no longer visible to workers. Worker `JULIA_LOAD_PATH`
  uses Unix `:` (native Windows is still unsupported).
