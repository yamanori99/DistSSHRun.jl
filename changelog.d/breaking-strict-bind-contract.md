category: breaking

- Per-host `bind` accepts only canonical dotted-quad IPv4 literals; host names, IPv6, ports, and invalid forms are rejected with an actionable fix before any SSH (#503). `go` rejects `bind` in the hosts file; `bind_overrides=` keys must match a planned host.
- Launch validates bind, tunnel, and topology once for all hosts before SSH; `--dry-run` uses the same host keys and validation as drive, ride, and go. Config bind errors are not demoted by `--best-effort` (CLI exit 2).
