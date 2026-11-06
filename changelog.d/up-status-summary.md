category: added

- `up status` prints one line per host: channel, installed patch, whether that patch matches the parent, and the available update. The juliaup rows print only with `--verbose`. The command still exits 0 when the line shows skew. It exits nonzero when juliaup is missing, `juliaup status` fails, or SSH fails.
