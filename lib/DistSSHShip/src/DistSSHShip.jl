"""
Shipping contract: project root, file selection, path dependencies, one
external file, content hash, and a verified copy to a caller-chosen dest.

Not registered. DistSSHRun includes this source as `DistSSHRun.DistSSHShip`,
the same way it includes DistSSHUp. Names marked `public` are a contract
inside the DistSSH family. A 0.x patch does not change them.

Queue should call this package directly (`pack_tree` then `ship`).
DistSSHRun does not list it in `[deps]`, so a General install of DistSSHRun
does not need an unregistered package.
"""
module DistSSHShip

using Dates
using DistSSHBase
using TOML
using Tar

const EXTERNAL_DIR_NAME = "_distsshrun_external"
const TREE_HASH_ALGORITHM = "git-sha1"

include("project.jl")
include("select.jl")
include("deps.jl")
include("contain.jl")
include("pack.jl")
include("record.jl")
include("ship.jl")

public EXTERNAL_DIR_NAME
public resolve_ship_project
public gitignore_paths
public selected_paths
public pack_paths
public pack_tree
public ship
public ShipProject
public ShipPack
public ShipResult
public ShipHostResult
public content_tree_hash
public assert_extracted_tree_contained!
public ship_record_logical_path
public build_ship_record
public write_ship_record
public read_ship_record
public read_ship_record_status
public ship_record_status
public verify_ship_record

end # module DistSSHShip
