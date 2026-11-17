# Shipped-tree verification: digest list, read-only files, launch and job-end checks.

using Tar

function _deploy_executable_ship_rels(rec::Union{Nothing, AbstractDict})::Union{Nothing, Vector{String}}
    rec === nothing && return nothing
    raw = get(rec, "executable_ship_rels", nothing)
    raw isa AbstractVector || return nothing
    return String[string(r) for r in raw]
end

function _deploy_content_file_digests(rec::Union{Nothing, AbstractDict})::Vector{Pair{String, String}}
    rec === nothing && return Pair{String, String}[]
    raw = get(rec, "content_file_digests", nothing)
    raw isa AbstractVector || return Pair{String, String}[]
    rows = Pair{String, String}[]
    for row in raw
        row isa AbstractDict || continue
        p = get(row, "path", nothing)
        h = get(row, "blob", nothing)
        p isa AbstractString && h isa AbstractString || continue
        push!(rows, String(p) => lowercase(strip(String(h))))
    end
    sort!(rows; by = first)
    return rows
end

function _digest_rows_from_pack(pack::DistSSHShip.Shipment)::Vector{Any}
    return Any[
        Dict{String, Any}("path" => p, "blob" => h) for (p, h) in pack.content_file_digests
    ]
end

"""Ship-equivalent `content_tree_hash` for verify on `root` (controller send list vs worker tree)."""
function _verify_content_tree_hash(root::AbstractString, site::AbstractString)::String
    if site == "controller"
        pack = _pack_project_tree(root)
        try
            return String(pack.content_tree_hash)
        finally
            rm(pack.directory; recursive = true, force = true)
        end
    end
    buf = IOBuffer()
    Tar.create(root, buf)
    seekstart(buf)
    return String(Tar.tree_hash(buf; algorithm = "git-sha1", skip_empty = true))
end

"""True when `rel` is the archive root, a shipped path, or a parent of one.

`.distssh/`, job output, and other files written after extract are not in `allowed`.
"""
function _payload_path_included(rel::AbstractString, allowed)::Bool
    rel == "." && return true
    rel in allowed && return true
    prefix = string(rel, "/")
    for shipped in allowed
        startswith(shipped, prefix) && return true
    end
    return false
end

"""`content_tree_hash` of the shipped paths at `root`, ignoring files added after extract."""
function _payload_tree_hash(root::AbstractString, rels)::String
    allowed = Set(String.(rels))
    buf = IOBuffer()
    Tar.create(root, buf) do path
        rel = replace(relpath(path, root), '\\' => '/')
        return _payload_path_included(rel, allowed)
    end
    seekstart(buf)
    return String(Tar.tree_hash(buf; algorithm = "git-sha1", skip_empty = true))
end

"""
Fail when the on-disk tree at `root` does not match the ship record in `rec`.
"""
function assert_shipped_tree_matches_record!(
        root::AbstractString,
        rec::AbstractDict;
        site::AbstractString = "worker",
    )
    digests = _deploy_content_file_digests(rec)
    expect_hash = get(rec, "content_tree_hash", nothing)
    if expect_hash isa AbstractString && !isempty(strip(String(expect_hash)))
        want = strip(String(expect_hash))
        got = if site == "controller" || isempty(digests)
            _verify_content_tree_hash(root, String(site))
        else
            _payload_tree_hash(root, String[first(p) for p in digests])
        end
        got == want || throw(
            ErrorException(
                "shipped tree content_tree_hash mismatch on $(site): $(got) != $(want)",
            ),
        )
    end
    isempty(digests) && return nothing
    rels = String[first(p) for p in digests]
    # `0444` / `0555` is the extracted tree. The controller source stays writable;
    # execute-bit drift is already in the pack `content_tree_hash`.
    if site != "controller"
        exec_rels = _deploy_executable_ship_rels(rec)
        mode_hits = DistSSHShip.shipped_file_mode_violations(
            root, rels; executable_rels = exec_rels,
        )
        isempty(mode_hits) || throw(
            ErrorException(DistSSHShip.shipped_tree_verify_error(site, "read-only violation", mode_hits)),
        )
    end
    digest_hits = DistSSHShip.shipped_file_digest_mismatches(root, digests)
    isempty(digest_hits) || throw(
        ErrorException(DistSSHShip.shipped_tree_verify_error(site, "content digest mismatch", digest_hits)),
    )
    return nothing
end
public assert_shipped_tree_matches_record!

function _active_ship_deploy_record()::Union{Nothing, Dict{String, Any}}
    rec = active_deploy_record()
    rec isa AbstractDict || return nothing
    String(get(rec, "mode", "")) == "ship-tree" || return nothing
    return Dict{String, Any}(rec)
end

"""Controller-side check before launch when the active deploy record is ship-tree."""
function assert_controller_shipped_tree_current!(project::AbstractString)
    rec = _active_ship_deploy_record()
    rec === nothing && return nothing
    root = canonical_local_path(project)
    assert_shipped_tree_matches_record!(root, rec; site = "controller")
    return nothing
end
public assert_controller_shipped_tree_current!

"""SSH workers run the extracted tree. Local workers share the controller project."""
function _worker_runs_extracted_tree(pid::Integer)::Bool
    try
        w = Distributed.map_pid_wrkr[Int(pid)]
        return w isa Distributed.Worker && w.manager isa Distributed.SSHManager
    catch
        return false
    end
end

"""
Worker-site check as an expr for `Core.eval`. Names no DistSSHRun binding.

The hash covers the shipped paths only, same rule as `_payload_tree_hash`.
"""
function _worker_shipped_tree_verify_expr(rec::AbstractDict)
    expect_hash = get(rec, "content_tree_hash", nothing)
    want = expect_hash isa AbstractString ? strip(String(expect_hash)) : ""
    rows = _deploy_content_file_digests(rec)
    exec = _deploy_executable_ship_rels(rec)
    exec_payload = exec === nothing ? nothing : String[string(r) for r in exec]
    return quote
        using SHA, Tar
        let want = $(want), rows = $(rows), exec_rels = $(exec_payload)
            function blob_hex(data::AbstractVector{UInt8})
                ctx = SHA.SHA1_CTX()
                SHA.update!(ctx, codeunits(string("blob ", length(data), "\0")))
                SHA.update!(ctx, data)
                return SHA.bytes2hex(SHA.digest!(ctx))
            end
            function node_digest(root, rel)
                dest = joinpath(root, split(rel, '/'; keepempty = false)...)
                if islink(dest)
                    return blob_hex(Vector{UInt8}(codeunits(String(readlink(dest)))))
                elseif isfile(dest)
                    return blob_hex(read(dest))
                else
                    error(string("shipped path is not a file or symlink: ", rel))
                end
            end
            function format_paths(paths)
                shown = String[string(p) for p in paths]
                length(shown) <= 12 && return join(shown, ", ")
                return string(join(shown[1:12], ", "), ", … (", length(shown), " total)")
            end
            function payload_included(rel, allowed)
                rel == "." && return true
                rel in allowed && return true
                prefix = string(rel, "/")
                for shipped in allowed
                    startswith(shipped, prefix) && return true
                end
                return false
            end
            proj = Base.active_project()
            proj === nothing && error("worker has no active project for shipped-tree verify")
            root = isfile(proj) ? dirname(String(proj)) : String(proj)
            if !isempty(want)
                allowed = Set{String}(String[first(p) for p in rows])
                buf = IOBuffer()
                Tar.create(root, buf) do path
                    rel = replace(relpath(path, root), '\\' => '/')
                    return payload_included(rel, allowed)
                end
                seekstart(buf)
                got = String(Tar.tree_hash(buf; algorithm = "git-sha1", skip_empty = true))
                got == want ||
                    error(string("shipped tree content_tree_hash mismatch on worker: ", got, " != ", want))
            end
            if !isempty(rows)
                rels = String[first(p) for p in rows]
                mode_hits = String[]
                exec_set = exec_rels === nothing ? nothing : Set(exec_rels)
                for rel in rels
                    dest = joinpath(root, split(rel, '/'; keepempty = false)...)
                    isfile(dest) && !islink(dest) || continue
                    mode = filemode(dest) & 0o777
                    if exec_set !== nothing
                        target = rel in exec_set ? 0o555 : 0o444
                        mode == target || push!(mode_hits, rel)
                    else
                        (mode & 0o222) != 0 && push!(mode_hits, rel)
                        mode != 0o444 && mode != 0o555 && push!(mode_hits, rel)
                    end
                end
                isempty(mode_hits) || error(
                    string(
                        "shipped tree read-only violation on worker: ",
                        format_paths(mode_hits),
                    ),
                )
                digest_hits = String[]
                for (rel, blob) in rows
                    dest = joinpath(root, split(rel, '/'; keepempty = false)...)
                    if !(isfile(dest) || islink(dest))
                        push!(digest_hits, rel)
                        continue
                    end
                    node_digest(root, rel) == blob || push!(digest_hits, rel)
                end
                isempty(digest_hits) || error(
                    string(
                        "shipped tree content digest mismatch on worker: ",
                        format_paths(digest_hits),
                    ),
                )
            end
            nothing
        end
    end
end

function verify_workers_shipped_trees!()
    rec = _active_ship_deploy_record()
    rec === nothing && return nothing
    digests = _deploy_content_file_digests(rec)
    isempty(digests) && return nothing
    sel = active_source_selection()
    sel === nothing && return nothing
    sel.source_kind === :ship || return nothing
    expr = _worker_shipped_tree_verify_expr(rec)
    for pid in _live_owned_worker_ids()
        _worker_runs_extracted_tree(pid) || continue
        remotecall_fetch(Core.eval, pid, Main, expr)
    end
    return nothing
end
public verify_workers_shipped_trees!

function _verify_worker_shipped_tree!(rec)
    proj = Base.active_project()
    proj === nothing && error("worker has no active project for shipped-tree verify")
    root = isfile(proj) ? dirname(String(proj)) : String(proj)
    assert_shipped_tree_matches_record!(root, rec; site = "worker")
    return nothing
end

"""At job end, warn once when the controller project tree drifted from the deploy record."""
function note_controller_shipped_tree_drift!(project::AbstractString)
    rec = _active_ship_deploy_record()
    rec === nothing && return nothing
    expect_hash = get(rec, "content_tree_hash", nothing)
    expect_hash isa AbstractString || return nothing
    root = canonical_local_path(project)
    got = _verify_content_tree_hash(root, "controller")
    want = strip(String(expect_hash))
    got == want && return nothing
    msg = "controller source tree changed after ship (content_tree_hash $(got) != deployed $(want))"
    @warn msg
    _note_provenance_shipped_tree_drift!(got, want)
    kit_println(msg)
    return nothing
end
public note_controller_shipped_tree_drift!

const _PROVENANCE_SHIPPED_TREE_DRIFT = Ref{Union{Nothing, Dict{String, String}}}(nothing)

function _note_provenance_shipped_tree_drift!(got::AbstractString, want::AbstractString)
    _PROVENANCE_SHIPPED_TREE_DRIFT[] = Dict{String, String}(
        "observed" => String(got),
        "deployed" => String(want),
    )
    return nothing
end

function _shipped_tree_drift_provenance()::Union{Nothing, Dict{String, String}}
    return _PROVENANCE_SHIPPED_TREE_DRIFT[]
end

function announce_forced_ignore_ship!(forced::AbstractVector{<:AbstractString})
    isempty(forced) && return nothing
    rels = sort(String[string(p) for p in forced])
    line = string("ship includes ignore-rule files: ", join(rels, ", "))
    kit_println(line)
    _note_forced_ignore_ship_provenance!(rels)
    return nothing
end
public announce_forced_ignore_ship!

const _PROVENANCE_FORCED_IGNORE = Ref{Union{Nothing, Vector{String}}}(nothing)

function _note_forced_ignore_ship_provenance!(rels::Vector{String})
    _PROVENANCE_FORCED_IGNORE[] = rels
    return nothing
end

function _forced_ignore_ship_provenance()::Union{Nothing, Vector{String}}
    return _PROVENANCE_FORCED_IGNORE[]
end
