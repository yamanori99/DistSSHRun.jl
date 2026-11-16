category: breaking

- Placement tokens use Julia-style `N*[user@]host[:port]` (issue #458). Removed `parent:N`, `child:NAME:N`, and `-w` / `--workers` local specs; use `--local-workers` and quoted machine tokens.
- One host-list source among `--hosts`, `--hosts-file`, and `--machine-file`; TOML `[[hosts]]` hosts files; duplicate hosts error (#460).
- Reject remote `tunnel=false` with loopback bind; topology defaults to `master_worker` (#461).