"""
Shipping contract: project root, file selection, path dependencies, one
external file, content hash, and a verified copy to a caller-chosen dest.

Not registered. DistSSHRun includes this source as `DistSSHRun.DistSSHShip`,
the same way it includes DistSSHUp. Names marked `public` are a contract
inside the DistSSH family. A 0.x patch does not change them.

Queue should call this package directly (`snapshot` then `transfer_tree`).
DistSSHRun does not list it in `[deps]`, so a General install of DistSSHRun
does not need an unregistered package.
"""
module DistSSHShip

using DistSSHBase
using TOML
using Tar

const EXTERNAL_DIR_NAME = "_distsshrun_external"
const TREE_HASH_ALGORITHM = "git-sha1"

include("project.jl")
include("select.jl")
include("deps.jl")
include("contain.jl")
include("snapshot.jl")
include("transfer.jl")

public EXTERNAL_DIR_NAME
public resolve_ship_project
public gitignore_paths
public selected_paths
public send_paths
public snapshot
public transfer_tree
public ShipProject
public ShipSnapshot
public TransferResult
public TransferHostResult
public content_tree_hash
public assert_extracted_tree_contained!

end # module DistSSHShip
