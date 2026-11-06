category: added

- `up status` prints one line per host: channel, installed patch, and the available update. A worker line also says whether that patch matches the parent. The parent line does not compare the parent to itself. The juliaup rows print only with `--verbose`. The command still exits 0 when the line shows skew. It exits nonzero when juliaup is missing, `juliaup status` fails, or SSH fails.
