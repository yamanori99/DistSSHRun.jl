category: breaking

- Machine placement `:port` is kept through launch: SSH uses OpenSSH `-p` / `scp -P` only when the token names an explicit port, and host identity keys (duplicates, bind overrides, dry-run) include that port (#505).
