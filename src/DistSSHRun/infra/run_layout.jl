# Remote ship leaf: `<remote_root>/ships/<ship_id>/` with extract target `src/`.

const _SHIP_ID_PATTERN = r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$"

const RSYNC_REMOVED_MSG =
    "--rsync was removed in 0.2.0; use setup ship-tree. Each directory's .gitignore under the ship root is the filter. A gitignored LocalPreferences.toml needs !LocalPreferences.toml. Declared inputs do not ship."

function allocate_remote_ship_id()::String
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyymmddTHHMMSS") * "Z"
    hex = bytes2hex(rand(UInt8, 3))
    return string(stamp, "-", hex)
end

"""
    validate_ship_id(ship_id) -> String

Validate a remote `ships/<ship_id>/` leaf id: `YYYYMMDDTHHMMSSZ-xxxxxx` (6 hex)
and a single safe path component (no `/`, `\\`, `.`, or `..`).
"""
function validate_ship_id(ship_id::AbstractString)::String
    s = String(ship_id)
    (occursin('/', s) || occursin('\\', s) || occursin('\0', s) || s == "." || s == "..") &&
        throw(
        ArgumentError(
            "ship_id must be a single path component matching YYYYMMDDTHHMMSSZ-xxxxxx, got $(repr(s))",
        ),
    )
    match(_SHIP_ID_PATTERN, s) === nothing && throw(
        ArgumentError(
            "ship_id must match YYYYMMDDTHHMMSSZ-xxxxxx (6 hex), got $(repr(s))",
        ),
    )
    return s
end
public validate_ship_id

function remote_ships_dir(remote_root::AbstractString)::String
    return joinpath(String(remote_root), "ships")
end

function remote_ship_leaf(remote_root::AbstractString, ship_id::AbstractString)::String
    return joinpath(remote_ships_dir(remote_root), validate_ship_id(ship_id))
end

function remote_ship_src(remote_root::AbstractString, ship_id::AbstractString)::String
    return joinpath(remote_ship_leaf(remote_root, ship_id), "src")
end

"""Reject `/` and a host's home after expansion. `abs_root` is already absolute."""
function validate_expanded_remote_root(
        abs_root::AbstractString,
        home::AbstractString,
    )::String
    p = String(abs_root)
    isempty(p) && throw(ArgumentError("remote_root is empty"))
    p == "/" && throw(ArgumentError("remote_root must not be /"))
    h = String(home)
    !isempty(h) && p == h && throw(ArgumentError("remote_root must not be \$HOME"))
    return p
end

function _posix_join(parts::AbstractString...)::String
    return join((replace(String(p), '\\' => '/') for p in parts), "/")
end
