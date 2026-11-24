# Single rejection table for removed DISTSSH_* env names (lint removed-names).

const OBSOLETE_ENV_RENAME_PAIRS = (
    "DISTSSH_SOURCE_COMMIT" => "DISTSSH_INTERNAL_SOURCE_COMMIT",
    "DISTSSH_SOURCE_DIRTY" => "DISTSSH_INTERNAL_SOURCE_DIRTY",
    "DISTSSH_SOURCE_CAPTURED" => "DISTSSH_INTERNAL_SOURCE_CAPTURED",
    "DISTSSH_SOURCE_UNTRACKED" => "DISTSSH_INTERNAL_SOURCE_UNTRACKED",
)

# Names rejected outright. Renamed source names live only in the pair list.
const OBSOLETE_ENV_REJECTION_NAMES = (
    string("GB_", "PER_WORKER"),
    string("DISTSSH_", "SIZE_PROBE"),
    string("DISTSSH_INTERNAL_", "SIZE_PROBE"),
)
