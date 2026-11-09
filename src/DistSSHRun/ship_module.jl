"""
Project shipping: root, file selection, path dependencies, one external file.

Not a `[deps]` entry. General installs DistSSHRun with this source included,
the same way it includes DistSSHUp. DistSSHShip is not registered.
"""
module DistSSHShip

using ..DistSSHBase
using TOML
using Tar

const EXTERNAL_DIR_NAME = "_distsshrun_external"
const TREE_HASH_ALGORITHM = "git-sha1"

let _ship_entry = joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "DistSSHShip.jl")
    isfile(_ship_entry) || error(
        "DistSSHRun: $_ship_entry is missing. Copy the whole DistSSHRun package directory, including lib/, not only src/.",
    )
end

# The package file opens `module DistSSHShip` and `using DistSSHBase`.
# Include the bodies here so this nested module is the one Run calls.
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "project.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "select.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "deps.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "contain.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "snapshot.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "transfer.jl"))

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
