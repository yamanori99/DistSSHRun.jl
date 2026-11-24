category: changed

- Outright removed environment variable names live in `OBSOLETE_ENV_REJECTION_NAMES` and must match the changelog `Removed:` entries below. Setting one fails at runtime with a pipeline error that asks for explicit `parent:N` / `NAME:N` arguments instead of the old env knob.
- Renamed source snapshot names (`DISTSSH_SOURCE_*` to `DISTSSH_INTERNAL_SOURCE_*`) live in `OBSOLETE_ENV_RENAME_PAIRS` only; setting an old name fails with a rename hint and is not listed under `Removed:`.

Removed: `GB_PER_WORKER`
Removed: `DISTSSH_SIZE_PROBE`
Removed: `DISTSSH_INTERNAL_SIZE_PROBE`
