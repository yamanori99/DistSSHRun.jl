category: breaking

- `setup check` is removed. The command prints a migration line and exits 2; use `julia -m DistSSHKit doctor --deploy [--run-id ID] HOSTS` instead.
- `doctor --deploy` runs the former setup check prerequisites (SSH, Julia, project, deps, git commit parity).
- Doctor CLI exit semantics (clap-style): bare `doctor` prints full help on stderr and exits 2; `doctor --help` prints the same text on stdout and exits 0; `doctor HOSTS` without `--deploy` and other usage errors exit 2 with a deploy hint.
- Go launch preflight uses the shared `doctor_launch_assert_hosts!` helper (same behavior, one implementation).
- `setup cleanup` is job-scoped: pass `--job-id` (or `setup!(…, :cleanup; job_id=…)`). Untagged machine-wide worker sweeps are removed.