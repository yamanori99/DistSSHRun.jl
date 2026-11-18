category: breaking

- Machine placement `:port` is kept through launch: SSH uses OpenSSH `-p` / `scp -P` only when the token names an explicit port, and host identity keys (duplicates, bind overrides, dry-run) include that port (#505).
- Bracketed IPv6 placement tokens are rejected before `Distributed.addprocs` (use an SSH `Host` alias or IPv4); `ssh` / `scp` still accept bracketed IPv6 destinations.
