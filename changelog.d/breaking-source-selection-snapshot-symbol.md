category: breaking

- `SourceSelection(:snapshot, …)` no longer normalizes to `:ship`; it throws `ArgumentError`. Use `source_kind = :ship`. Persisted legacy keys (`last-snapshot.toml`, `snapshot_id`, `provenance.shipped`, `source_kind = "snapshot"`) are still read for one release.
