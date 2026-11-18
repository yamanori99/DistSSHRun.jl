category: breaking

- Machine placement `:port` is kept through launch: SSH uses OpenSSH `-p` / `scp -P` only when the token names an explicit port, and host identity keys (duplicates, bind overrides, dry-run) include that port (#505).
- IPv6 literals in host tokens and SSH endpoints are rejected (use an SSH config `Host` alias with a `HostName` instead).
- Ctrl-C and reap SSH phases skip unparsable hosts per host instead of aborting the whole batch; worker interrupt falls back to `Distributed.interrupt` when the placement endpoint cannot be recovered.
