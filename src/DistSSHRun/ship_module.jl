"""
Project shipping: root, file selection, path dependencies, one external file.

Not a `[deps]` entry. General installs DistSSHRun with this source included,
the same way it includes DistSSHUp. DistSSHShip is not registered.
"""
module DistSSHShip

using Dates
using ..DistSSHBase
using ..DistSSHBase: HostResult
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
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "pack.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "record.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHShip", "src", "ship.jl"))

public EXTERNAL_DIR_NAME
public resolve_ship_project
public gitignore_paths
public selected_paths
public pack_paths
public pack_entry_paths
public pack_tree
public ship
public ShipProject
public Shipment
public ShipmentReceipt
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
