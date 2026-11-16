category: breaking

- `setup check` is removed. The command prints a migration line and exits 2; use `julia -m DistSSHKit doctor --deploy [--run-id ID] HOSTS` instead.
- `doctor --deploy` runs the former setup check prerequisites (SSH, Julia, project, deps, git commit parity).
- Bare `doctor` (no flags or host tokens) prints the same help as `doctor --help` and exits 0; hosts without `--deploy` still error with a `--deploy` hint.
- Go launch preflight uses the shared `doctor_launch_assert_hosts!` helper (same behavior, one implementation).
- `setup cleanup` is job-scoped: pass `--job-id` (or `setup!(…, :cleanup; job_id=…)`). Untagged machine-wide worker sweeps are removed.