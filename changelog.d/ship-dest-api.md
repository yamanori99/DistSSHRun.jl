category: added

- `pack_ship_tree`, `ship_pack`, and `ship_project_to_dest` send a project tree to a caller-chosen remote directory with the same pack rules as `ship_tree!` (`.gitignore` send list, path dependencies, declared-input omission). They use `DistSSHShip` tar transfer and verification; they do not allocate `runs/<id>/`, write run leaf metadata, or instantiate. A missing Manifest at pack time is an error. Optional `transfer_id` is stored in `<dest>/.distssh/ship.toml` when `write_record=true` (default).
