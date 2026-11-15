# Common errors (`DSSH-E###`)

Stable codes are defined in `src/DistSSHRun/messages/errors.jl`. Each code has a
unique anchor (for example `removed-cli-flag` for `DSSH-E001`). Typed errors print
**What / Where / Why / Fix** (and **Reproduce** when available).

## DSSH-E001 — Removed CLI flag

**When:** A flag was removed in 0.2.0 with no alias.

**Example:** `--unsafe-heterogeneous` → use `--unsafe-skip-env-digests`.

## DSSH-E002 — Unknown CLI option

**When:** The parser sees a flag not defined for that command.

## DSSH-E003 — Conflicting verbosity environment variables

**When:** More than one of `DISTSSH_QUIET`, `DISTSSH_PROGRESS`, and `DISTSSH_VERBOSE` is set.

## DSSH-E010 — Hosts file not found

**When:** `--hosts-file` or `DISTSSH_HOSTS_FILE` points at a missing path.

## DSSH-E011 — Hosts file empty

**When:** The hosts file has no non-comment lines.

## DSSH-E020 — Invalid placement token

**When:** A worker/placement token does not match `parent:N` / `child:NAME:N` grammar.

## DSSH-E030 — Topology or bind rejected

**When:** Resolved topology, tunnel, or bind settings are incompatible (see upcoming topology rules).

## DSSH-E040 — Worker environment mismatch

**When:** Julia build, DistSSH* versions, or Manifest/Project digests differ between controller and worker.

See also: [Options](@ref Options).