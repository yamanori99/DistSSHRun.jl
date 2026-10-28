# Remote run leaf: `<remote_root>/runs/<run_id>/` with extract target `src/`.

const _RUN_ID_PATTERN = r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$"

const RSYNC_REMOVED_MSG =
    "--rsync was removed in 0.2.0; use --ship-tree. Only git-tracked and untracked non-ignored files are shipped."

function allocate_remote_run_id()::String
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyymmddTHHMMSS") * "Z"
    hex = bytes2hex(rand(UInt8, 3))
    return string(stamp, "-", hex)
end

function validate_run_id(run_id::AbstractString)::String
    s = String(run_id)
    occursin(_RUN_ID_PATTERN, s) || throw(
        ArgumentError(
            "run_id must match YYYYMMDDTHHMMSSZ-xxxxxx (6 hex), got $(repr(s))",
        ),
    )
    return s
end

function remote_runs_dir(remote_root::AbstractString)::String
    return joinpath(String(remote_root), "runs")
end

function remote_run_leaf(remote_root::AbstractString, run_id::AbstractString)::String
    return joinpath(remote_runs_dir(remote_root), validate_run_id(run_id))
end

function remote_run_src(remote_root::AbstractString, run_id::AbstractString)::String
    return joinpath(remote_run_leaf(remote_root, run_id), "src")
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
