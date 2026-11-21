# [Placement and host lists](@id Placement)

Worker placement uses **machine tokens** shared by `--hosts`, hosts files, and
`--machine-file`:

```text
N*[user@]host[:port]
```

Examples (always quote `--hosts` so the shell does not glob-expand `*`):

```bash
julia -m DistSSHKit drive --head-workers 2 --hosts '4*user@lab:2222,2*lab-b' script.jl
```

- A bare host means **one worker** (`host` ≡ `1*host`).
- `:` after the host is the **SSH port** only (as in Julia's machine file).
- When you set a port, OpenSSH gets **`-p`** (and **`scp -P`**); with no port, DistSSH does not pass `-p` (your `~/.ssh/config` may still choose a port).
- When the token names a port, that port wins on the argv; conflicting `-p`, `-P`, and `-o Port=…` from `DISTRIBUTED_SSH_OPTS` are dropped for that connection.
- If the token already includes `user@`, that user is used for `ssh`, `scp`, and worker launch strings (ahead of a `User` from `ssh -G` on a bare host token). `DISTRIBUTED_SSH_OPTS` is prepended on the argv; an `-o User=…` there is still an OpenSSH option and can override the effective user when it appears before the destination in the final command line (including worker launch).
- Otherwise DistSSH runs `ssh -G` with the same endpoint (including explicit `-p` when set) to read the effective `User` from your SSH config, then prefixes it for scp paths and `Distributed.addprocs`.
- The same port is part of the host key for duplicates, `bind_overrides=`, and dry-run lines (`alice@lab:2222` is distinct from `alice@lab`).
- IPv6 literals (`::1`, `[::1]`, `user@[::1]:2222`, and similar) are not accepted in host tokens or SSH endpoints. Use an SSH config `Host` alias instead (for example `Host lab6` with `HostName ::1` in `~/.ssh/config`), then pass `lab6` or `lab6:2222` in `--hosts`.

Local capacity is **not** a placement token. `drive`: `--head-workers N`
(`DISTSSH_HEAD_WORKERS` only). `go`: `--head-slots N`. With no hosts and no
`--head-slots`, `go` still runs **one** head slot and prints
`head: <hostname>, 1 slot (no hosts given)`; `--head-slots 0` with no hosts
is a usage error.

## Host list sources

Exactly one source applies:

- `--hosts` CSV
- `--hosts-file` (plain lines or TOML with `[[hosts]]`, required `name`, optional `bind`)
  - TOML `bind` must be a canonical dotted-quad IPv4 literal (decimal octets
    0–255, no leading zeros, no host names or IPv6). Loopback defaults to
    `127.0.0.1`; other addresses need `--unsafe-expose-port`. `0.0.0.0` needs
    that flag and SSH tunnel enabled. `go` does not support per-host `bind`.
- `--machine-file` (one token per line)

`DISTSSH_HOSTS` / `DISTSSH_HOSTS_FILE` apply only when the CLI does not set a
host list (they are never merged with `--hosts`). Two explicit CLI sources are
an error. When a job resolves hosts, it prints `hosts (from …): …`; if
`DISTSSH_HOSTS` is set but overridden by CLI, it also prints
`DISTSSH_HOSTS is set but overridden by …`.
