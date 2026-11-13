category: breaking

- Drive worker heartbeat self-exit when the controller (master) stops
  answering is opt-in (off by default). Use CLI
  `--unsafe-master-silence-exit` or `DISTSSH_UNSAFE_MASTER_SILENCE_EXIT=1`
  and a positive `DISTRIBUTED_HEARTBEAT_DEADLINE_SEC` (no implicit 600
  second fallback). When off, workers do not install the exit monitor; the
  startup summary and run provenance record `self_exit = false`. When on,
  startup emits an `unsafe:` line with deadline and interval and provenance
  records the values.
