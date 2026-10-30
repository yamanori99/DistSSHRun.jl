category: added

- A project may declare `.distsshkit/inputs.toml` entries with `name`, `path`, and optional `hash`. Those paths are left out of the ship tree. Each remote copy is SHA-256 hashed, or fingerprinted with `stat` when `hash = false`. The result is written only under `DISTSSHKIT_RUN_DIR`. With no declaration, the ship tree is unchanged.
