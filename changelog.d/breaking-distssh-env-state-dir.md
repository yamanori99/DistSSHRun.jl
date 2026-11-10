category: breaking

- **`DISTSSH_*` environment variables** replace every `DISTSSHKIT_*` name. Old names are not read; set the new variables (for example `DISTSSH_RUN_DIR`, `DISTSSH_QUIET`, `DISTSSH_TEST_SSH`).
- **Local state directory** is `.distssh/` (writes only). An existing `.distsshkit/` tree remains **read-only fallback** for the rest of 0.2.x; no removal date is encoded yet.
- **Remote state** uses the same rule: new artifacts under `.distssh/`, with read-only fallback for an existing remote `.distsshkit/`.
- **Ship / rsync / prune** treat both `.distssh/` and `.distsshkit/` as state directories, so neither is shipped.
- **SSH probe markers** are `DISTSSH_*` (for example `DISTSSH_HOSTINFO`, `DISTSSH_DEST_STATUS`, `DISTSSH_PRUNE_LEAVES`). Mixing an older controller with workers built for 0.2.0 is unsupported.
- **Out of scope here** (Queue naming): `DISTSSHQUEUE_*`, `~/.distsshkitqueue`, `org.distsshkitqueue.serve`, `DIST_SSH_KIT_CLI_INCLUDE`.
