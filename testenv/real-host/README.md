# Real-host developer smoke (manual)

Run the public DistSSHRun CLI against **your** SSH machines (lab Mac minis,
a colleague’s host, or the local docker-ssh / apple-container workers as a
dry run). This is **not** CI, not `Pkg.test()`, and not
[`test/e2e.jl`](../../test/e2e.jl): no automated verdict, no fixture wrapper.

Use it before releases, after risky SSH/ship changes, or to collect evidence
for [#200](https://github.com/yamanori99/DistSSHRun.jl/issues/200).

## When to use this vs docker-ssh E2E

| Goal | Path |
| --- | --- |
| Full kit regression on disposable Linux workers | [`../docker-ssh`](../docker-ssh) `scripts/up.sh --e2e` |
| Same suite on macOS via Apple Container | [`../apple-container-ssh`](../apple-container-ssh) `scripts/up.sh --e2e` |
| **Your** topology, real `ssh`, short smoke + pasteable report | This README |

Do not run docker-ssh compose and apple-container workers at once (shared
`.generated/ssh_config`).

## Prerequisites

- A **clone** of this repo at the commit you mean to test.
- Shell on the **controller** (the machine that runs `julia -m DistSSHRun`).
- Each **worker**: OpenSSH (`sshd`), non-interactive login
  (`ssh worker true` exits 0 without a password prompt).
- Julia on workers (align with `julia -m DistSSHRun up …`; see
  [`up`](../../docs/src/cli.md)).
- Placement tokens: `N*host` or bare `host` (one worker). Quote tokens so the
  shell does not glob `*`. Details:
  [placement.md](../../docs/src/placement.md).
- A dedicated **deploy root** on remotes, for example `~/distssh-realhost`.
  Use the same path on every host in one pass.
- Until TTY progress is trusted on your machines, pass **`--verbose`** on
  setup and `doctor` so lines are not swallowed.

Optional (container dry run): after `../docker-ssh/scripts/up.sh` or
`../apple-container-ssh/scripts/up.sh` (workers only, no `--e2e`), use hosts
`child-1` and `child-2`, deploy root `/home/dev/distssh-realhost`. DistSSHRun
must see the generated SSH config — either `source` the env file once:

```bash
set -a
source testenv/docker-ssh/.generated/env.sh
set +a
```

or prefix each Julia command with
`testenv/docker-ssh/scripts/with-env.sh` (see
[`with-env.sh`](../docker-ssh/scripts/with-env.sh)).

On macOS without Local Network permission for Homebrew `ssh`, use apple-container
`./scripts/up.sh --system-ssh` (see
[apple-container-ssh README](../apple-container-ssh/README.md)).

## Variables (set once per session)

```bash
cd /path/to/DistSSHRun.jl
export ROOT='~/distssh-realhost'          # remote deploy root (same on all workers)
export HOSTS='2*child-1'                  # example: two workers on child-1; use your lab tokens
# Container dry run:
# export HOSTS='child-1 child-2'
```

From the repo root, every command below uses:

```bash
julia --project=. --startup-file=no -m DistSSHRun …
```

Record **exit code** and **stdout/stderr** for each step when filing a report.

## 1. Controller identity

```bash
git rev-parse HEAD
julia --project=. --startup-file=no -e 'using InteractiveUtils; versioninfo()'
```

**Success:** prints a 40-char commit SHA and Julia `versioninfo()`.

## 2. `hostinfo`

```bash
julia --project=. --startup-file=no -m DistSSHRun hostinfo --verbose --hosts "$HOSTS"
```

**Success:** exit 0; one block per host (Julia path, OS, CPU, RAM).  
**If it fails:** fix SSH config, keys, or Julia on the worker before shipping.

## 3. `setup ship-tree`

Ship the **current repo** (`.`) into `runs/<run_id>/src/` under `ROOT`.

```bash
julia --project=. --startup-file=no -m DistSSHRun setup ship-tree \
  --deploy-root "$ROOT" --verbose --hosts "$HOSTS"
```

**Success:** exit 0; log mentions a new run id under `runs/…`. The kit writes
`last-ship.toml` beside this checkout for the same deploy root, so later steps
can omit `--run-id` if you keep this tree and `ROOT` unchanged.

Copy the **run id** from the log if you need it explicitly (timestamp-style
directory name under `runs/`).

## 4. `setup instantiate`

```bash
julia --project=. --startup-file=no -m DistSSHRun setup instantiate \
  --deploy-root "$ROOT" --verbose --hosts "$HOSTS"
```

If you shipped from a different deploy root or cleared `last-ship.toml`, add
`--run-id ID` matching the ship step.

**Success:** exit 0; remote project deps resolve on each host.

## 5. `doctor --deploy`

```bash
julia --project=. --startup-file=no -m DistSSHRun doctor --deploy \
  --deploy-root "$ROOT" --verbose --hosts "$HOSTS"
```

Add `--run-id ID` when `last-ship.toml` does not match this pass.

**Success:** exit 0; deploy prerequisites pass on each host.

## 6. Short `go` (select only, no transfer)

`go` does not ship; it runs a script against the deployed tree.

```bash
julia --project=. --startup-file=no -m DistSSHRun go --verbose \
  --deploy-root "$ROOT" --hosts "$HOSTS" \
  demos/without_kit/pi_echo.jl
```

**Success:** exit 0; π lines on each slot/host in the output.

## 7. Short `drive` (select only)

```bash
julia --project=. --startup-file=no -m DistSSHRun drive --verbose \
  --deploy-root "$ROOT" --hosts "$HOSTS" \
  demos/with_kit/square_echo.jl
```

**Success:** exit 0; `param^2:` (or similar) from workers in the log.

## What to paste in a report

Paste these into a GitHub issue or PR comment (for example #200):

1. Controller `git rev-parse HEAD` and `versioninfo()` output.
2. The exact `HOSTS`, `ROOT`, and Julia used on workers (from `hostinfo`).
3. Exit code and full output (or stderr tail on failure) for steps 2–7.
4. Run id and any `content_tree_hash` line from the ship-tree log, if printed.
5. Topology in one line (for example “Mac mini controller → Mac mini worker
   over Thunderbolt”).

Do not auto-run destructive setup. This runbook never calls
`setup delete`, `setup prune`, or `setup cleanup`.

## Cleanup (optional, manual)

Leaving `ROOT` in place is fine for the next pass. To remove a deploy tree
**only when you chose the path yourself**, use setup delete with
`--confirm-path` set to the **exact** remote path you type (not copied from
error text). See `setup delete --help`.

## Related

- Release gate discussion: [#200](https://github.com/yamanori99/DistSSHRun.jl/issues/200)
- CLI reference: [docs — CLI](https://yamanori99.github.io/DistSSHRun.jl/dev/cli.html)
- Full automated SSH suite: [test/README.md § SSH E2E](../../test/README.md#ssh-e2e)
