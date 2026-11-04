category: changed

- Remote Tar Julia sets `JULIA_DEPOT_PATH` empty so 1.14+ does not write
  `cache/` under the default depot. Stdlib Tar still loads; compiled modules
  stay unused.
