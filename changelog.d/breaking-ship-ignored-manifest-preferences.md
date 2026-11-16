category: breaking

- `setup ship-tree` and `DistSSHShip.pack_tree` force ignored-on-disk
  `Manifest.toml`, `JuliaManifest.toml`, project files, and
  `LocalPreferences.toml` / `JuliaLocalPreferences.toml` into the pack when they
  exist (Cargo.lock-style). Unreadable or missing required lock files fail
  before SSH. One startup line and provenance record the forced paths.
  Deploy records carry Manifest and preference SHA-256 digests. Remote
  `setup instantiate` refuses when deployed Manifest bytes differ from the
  record.