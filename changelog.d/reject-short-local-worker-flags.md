category: breaking

- `drive`, `ride`, and `go` reject mistaken short flags `-p`, `-l`, `-L` (including glued forms like `-p4`) with usage hints instead of treating them as worker counts. There is no `-p` alias for `--local-workers` or `--local-slots`.