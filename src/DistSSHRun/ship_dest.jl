# Verified pack → arbitrary remote dest (Queue stage and other non-run layouts).
# Run layout shipping stays in `ship.jl` (`ship_tree!`).

"""
    pack_ship_tree(project; allow_external_symlinks=false, ship_max_bytes, extra_files=String[]) -> Shipment

Pack `project` for shipping with the same rules as [`ship_tree!`](@ref) (`.gitignore`
send list, path dependencies, declared-input omission, and `warn = print_warn`).

Returns [`DistSSHRun.DistSSHShip.Shipment`](@ref). A missing Manifest (including
versioned `Manifest-v*.toml` via `manifest_path`) throws `ArgumentError` with the
same message as the engine pack step.
"""
function pack_ship_tree(
        project::AbstractString;
        allow_external_symlinks::Bool = false,
        ship_max_bytes::Integer = SHIP_MAX_BYTES_DEFAULT,
        extra_files::Vector{String} = String[],
    )::DistSSHShip.Shipment
    return _pack_project_tree(
        project;
        allow_external_symlinks = allow_external_symlinks,
        ship_max_bytes = ship_max_bytes,
        extra_files = extra_files,
    )
end
public pack_ship_tree

"""
    ship_pack(pack, hosts, dest; allow_external_symlinks=false, julia=nothing, write_record=true, transfer_id=nothing) -> ShipmentReceipt

Send an existing [`DistSSHRun.DistSSHShip.Shipment`](@ref) to caller-chosen `dest`
on each host using [`DistSSHRun.DistSSHShip.ship`](@ref).

This does not allocate a run id, write `runs/<id>/run.toml`, instantiate, or touch
controller provenance. `dest` must be absolute or start with `~`; it must be missing
or an empty directory (non-empty is an error and is left unchanged). A failed host can
leave a partial tree; callers must treat `ShipmentReceipt.ok` before using the destination.

When `write_record=true` (default), writes `<dest>/.distssh/shipment.toml` after verified
extract. Optional `transfer_id` is stored in that record (for example a Queue stage id).

Returns [`DistSSHRun.DistSSHShip.ShipmentReceipt`](@ref).
"""
function ship_pack(
        pack::DistSSHShip.Shipment,
        hosts::AbstractVector{<:AbstractString},
        dest::AbstractString;
        allow_external_symlinks::Bool = false,
        julia::Union{Nothing, AbstractString} = nothing,
        write_record::Bool = true,
        transfer_id::Union{Nothing, AbstractString} = nothing,
    )::DistSSHShip.ShipmentReceipt
    return DistSSHShip.ship(
        pack, hosts, dest;
        allow_external_symlinks = allow_external_symlinks,
        julia = julia,
        write_record = write_record,
        transfer_id = transfer_id,
    )
end
public ship_pack

"""
    ship_project_to_dest(project, hosts, dest; pack keywords..., ship keywords...) -> ShipmentReceipt

[`pack_ship_tree`](@ref)`(project)` then [`ship_pack`](@ref) to `dest`, then delete
the temporary pack directory. Keyword arguments after `dest` apply to both steps
where the names match (`allow_external_symlinks`, `ship_max_bytes`, `extra_files` for
pack; `julia`, `write_record`, `transfer_id` for ship only).

Returns [`DistSSHRun.DistSSHShip.ShipmentReceipt`](@ref).
"""
function ship_project_to_dest(
        project::AbstractString,
        hosts::AbstractVector{<:AbstractString},
        dest::AbstractString;
        allow_external_symlinks::Bool = false,
        ship_max_bytes::Integer = SHIP_MAX_BYTES_DEFAULT,
        extra_files::Vector{String} = String[],
        julia::Union{Nothing, AbstractString} = nothing,
        write_record::Bool = true,
        transfer_id::Union{Nothing, AbstractString} = nothing,
    )::DistSSHShip.ShipmentReceipt
    pack = pack_ship_tree(
        project;
        allow_external_symlinks = allow_external_symlinks,
        ship_max_bytes = ship_max_bytes,
        extra_files = extra_files,
    )
    try
        return ship_pack(
            pack, hosts, dest;
            allow_external_symlinks = allow_external_symlinks,
            julia = julia,
            write_record = write_record,
            transfer_id = transfer_id,
        )
    finally
        rm(pack.directory; force = true, recursive = true)
    end
end
public ship_project_to_dest
