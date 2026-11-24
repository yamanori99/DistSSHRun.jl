category: changed

- Runtime env rejection list is centralized in `obsolete_env.jl` and kept in sync with changelog `Removed:` lines. Renamed source env names map to internal names via `OBSOLETE_ENV_RENAME_PAIRS`; `OBSOLETE_ENV_REJECTION_NAMES` lists names that error when set.

Removed: `GB_PER_WORKER`
Removed: `DISTSSH_SIZE_PROBE`
Removed: `DISTSSH_INTERNAL_SIZE_PROBE`
