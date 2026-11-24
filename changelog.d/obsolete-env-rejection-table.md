category: changed

- Outright removed environment variable names are centralized in `OBSOLETE_ENV_REJECTION_NAMES`. Setting one fails at runtime with a pipeline error that asks for explicit `parent:N` / `NAME:N` arguments instead of the old env knob. Behavior unchanged; those names were already rejected before this change.
- Renamed source snapshot names (`DISTSSH_SOURCE_*` to `DISTSSH_INTERNAL_SOURCE_*`) are centralized in `OBSOLETE_ENV_RENAME_PAIRS`; setting an old name fails with a rename hint rather than a pipeline placement error.
