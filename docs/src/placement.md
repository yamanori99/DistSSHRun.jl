# Placement and host lists

Worker placement uses **machine tokens** shared by `--hosts`, hosts files, and
`--machine-file`:

```text
N*[user@]host[:port]
```

Examples (always quote `--hosts` so the shell does not glob-expand `*`):

```bash
julia -m DistSSHKit drive --local-workers 2 --hosts '4*user@lab:2222,2*[::1]' script.jl
```

- A bare host means **one worker** (`host` ≡ `1*host`).
- `:` after the host is the **SSH port** only (as in Julia's machine file).
- IPv6 literals must be bracketed (`2*[fe80::1]:2222`).

Local workers are **not** placement tokens. Use `--local-workers N`.

## Host list sources

Exactly one source applies:

- `--hosts` CSV
- `--hosts-file` (plain lines or TOML with `[[hosts]]` and required `name`)
- `--machine-file` (one token per line)

`DISTSSH_HOSTS` / `DISTSSH_HOSTS_FILE` apply only when the CLI does not set a
host list. Two explicit CLI sources are an error.