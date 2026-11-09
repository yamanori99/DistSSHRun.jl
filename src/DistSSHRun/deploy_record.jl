# Remote deploy record (`.distssh/deploy.toml`) written by setup, read by run.

const _DEPLOY_RECORD_SCHEMA = 1
const _DEPLOY_RECORD_DIR = ".distssh"
const _DEPLOY_RECORD_NAME = "deploy.toml"

const _ACTIVE_DEPLOY_RECORD = Ref{Union{Nothing, Dict{String, Any}}}(nothing)

function _clear_active_deploy_record!()
    _ACTIVE_DEPLOY_RECORD[] = nothing
    return nothing
end

function active_deploy_record()::Union{Nothing, Dict{String, Any}}
    return _ACTIVE_DEPLOY_RECORD[]
end

function _set_active_deploy_record!(rec::Union{Nothing, AbstractDict})
    if rec === nothing
        _ACTIVE_DEPLOY_RECORD[] = nothing
    else
        _ACTIVE_DEPLOY_RECORD[] = Dict{String, Any}(rec)
    end
    return nothing
end

"""POSIX path to the deploy record under a deployment root."""
function deploy_record_logical_path(deploy_root::AbstractString)::String
    root = rstrip(String(strip(String(deploy_root))), '/')
    return _posix_join(root, _DEPLOY_RECORD_DIR, _DEPLOY_RECORD_NAME)
end

function _deploy_mode_string(mode::Symbol)::String
    mode == :ship_tree && return "ship-tree"
    mode == :git_clone && return "git-clone"
    mode == :git_sync && return "git-sync"
    mode == :git_pull && return "git-pull"
    mode == :clone && return "git-clone"
    mode == :sync && return "git-sync"
    mode == :pull && return "git-pull"
    throw(ArgumentError("unknown deploy mode $(repr(mode))"))
end

function _deploy_record_manifest_hash(project::AbstractString)::Union{Nothing, String}
    mf = manifest_path(project)
    if mf isa String && isfile(mf)
        return lowercase(file_sha256(mf))
    end
    return nothing
end

function _deploy_record_timestamp()::String
    return Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
end

"""
Build a schema-1 deploy record table (not yet written).
"""
function build_deploy_record(
        project::AbstractString,
        mode::Symbol;
        deploy_id::AbstractString,
        commit_sha::Union{Nothing, AbstractString} = nothing,
        dirty::Bool = false,
        snapshot_id::Union{Nothing, AbstractString} = nothing,
        content_tree_hash::Union{Nothing, AbstractString} = nothing,
        project_rel::Union{Nothing, AbstractString} = nothing,
    )::Dict{String, Any}
    data = Dict{String, Any}(
        "schema" => _DEPLOY_RECORD_SCHEMA,
        "deploy_id" => String(deploy_id),
        "mode" => _deploy_mode_string(mode),
        "dirty" => dirty,
        "local_path" => canonical_local_path(project),
        "timestamp" => _deploy_record_timestamp(),
    )
    mh = _deploy_record_manifest_hash(project)
    mh !== nothing && (data["manifest_hash"] = mh)
    if commit_sha isa AbstractString && !isempty(strip(String(commit_sha)))
        data["commit_sha"] = String(commit_sha)
    end
    if snapshot_id isa AbstractString && !isempty(strip(String(snapshot_id)))
        data["snapshot_id"] = validate_snapshot_id(snapshot_id)
    end
    if content_tree_hash isa AbstractString && !isempty(strip(String(content_tree_hash)))
        h = String(content_tree_hash)
        _valid_content_tree_hash(h) || throw(
            ArgumentError(
                "content_tree_hash must be a 40-digit git-sha1 hex string, got $(repr(h))",
            ),
        )
        data["content_tree_hash"] = h
    end
    rel = something(project_rel, ".")
    rel = _ship_project_rel(String(rel))
    rel == "." || (data["project_rel"] = rel)
    return data
end

function _parse_deploy_record_body(body::AbstractString)::Union{Nothing, Dict{String, Any}}
    s = strip(String(body))
    isempty(s) && return nothing
    try
        raw = TOML.parse(s)
        raw isa AbstractDict || return nothing
        schema = get(raw, "schema", nothing)
        schema isa Integer && schema == _DEPLOY_RECORD_SCHEMA || return nothing
        mode = get(raw, "mode", nothing)
        mode isa AbstractString && !isempty(strip(String(mode))) || return nothing
        deploy_id = get(raw, "deploy_id", nothing)
        deploy_id isa AbstractString && !isempty(strip(String(deploy_id))) || return nothing
        return Dict{String, Any}(raw)
    catch
        return nothing
    end
end

function _remote_deploy_record_path_word(host::AbstractString, deploy_root::AbstractString)::String
    logical = deploy_record_logical_path(deploy_root)
    expanded = _probe_expanded_remote_root(String(host), logical)
    return _remote_shell_path_word(expanded)
end

"""Read `.distssh/deploy.toml` on `host`, or `nothing` when missing or invalid."""
function read_deploy_record_on_host(
        host::AbstractString,
        deploy_root::AbstractString,
    )::Union{Nothing, Dict{String, Any}}
    pq = _remote_deploy_record_path_word(host, deploy_root)
    out = IOBuffer()
    err = IOBuffer()
    proc = run(
        pipeline(
            ignorestatus(_host_sync_remote_shell_cmd(String(host), "test -f $pq && cat $pq"));
            stdout = out,
            stderr = err,
        );
        wait = true,
    )
    DistSSHBase.shell_status(proc) == 0 || return nothing
    return _parse_deploy_record_body(String(take!(out)))
end

function _deploy_records_equivalent(a::AbstractDict, b::AbstractDict)::Bool
    keys = (
        "schema",
        "deploy_id",
        "mode",
        "commit_sha",
        "dirty",
        "manifest_hash",
        "local_path",
        "snapshot_id",
        "content_tree_hash",
        "project_rel",
    )
    for k in keys
        va = get(a, k, nothing)
        vb = get(b, k, nothing)
        va == vb || return false
    end
    return true
end

"""
Read deploy records from `hosts` and require equivalent content, or `nothing` when absent on all.
"""
function read_deploy_record_consensus(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
    )::Union{Nothing, Dict{String, Any}}
    isempty(hosts) && return nothing
    reference = nothing
    for h in hosts
        rec = read_deploy_record_on_host(String(h), deploy_root)
        rec === nothing && continue
        if reference === nothing
            reference = rec
        elseif !_deploy_records_equivalent(reference, rec)
            throw(
                _selection_error(
                    "deploy record on $(h) does not match other hosts; run setup on every host",
                ),
            )
        end
    end
    return reference
end

function _write_deploy_record_via_scp!(
        host::AbstractString,
        deploy_root::AbstractString,
        data::AbstractDict,
    )
    body = sprint(TOML.print, data)
    tmp = tempname()
    record_path = deploy_record_logical_path(deploy_root)
    try
        open(tmp, "w") do io
            print(io, body)
        end
        record_abs = _probe_expanded_remote_root(String(host), record_path)
        parent = record_abs
        i = findlast(==('/'), parent)
        i !== nothing && (parent = parent[1:prevind(parent, i)])
        pq_parent = _remote_shell_path_word(parent)
        run(
            pipeline(
                ignorestatus(
                    _host_sync_remote_shell_cmd(
                        String(host),
                        "mkdir -p $pq_parent && chmod 755 $pq_parent",
                    ),
                );
                stdout = devnull,
                stderr = devnull,
            ),
        )
        dest = string(String(host), ":", record_path)
        run(
            pipeline(
                _scp_cmd(String[ssh_opts()..., _ssh_host_args(dest)..., tmp]);
                stdout = devnull,
                stderr = devnull,
            ),
        )
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
    return nothing
end

"""
Write the same deploy record to every host (best-effort per host; failures do not roll back setup).
"""
function write_deploy_record_to_hosts!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        project::AbstractString,
        mode::Symbol;
        deploy_id::AbstractString,
        commit_sha::Union{Nothing, AbstractString} = nothing,
        dirty::Bool = false,
        snapshot_id::Union{Nothing, AbstractString} = nothing,
        content_tree_hash::Union{Nothing, AbstractString} = nothing,
        project_rel::Union{Nothing, AbstractString} = nothing,
    )
    isempty(hosts) && return nothing
    data = build_deploy_record(
        project,
        mode;
        deploy_id = deploy_id,
        commit_sha = commit_sha,
        dirty = dirty,
        snapshot_id = snapshot_id,
        content_tree_hash = content_tree_hash,
        project_rel = project_rel,
    )
    for h in hosts
        try
            _write_deploy_record_via_scp!(String(h), deploy_root, data)
        catch e
            e isa InterruptException && rethrow()
            # Deploy record is metadata; the tree transfer already succeeded.
        end
    end
    return data
end

function _selection_from_deploy_record(
        rec::AbstractDict,
        deploy::AbstractString,
        host_list::Vector{String},
    )::SnapshotSelection
    mode_s = String(get(rec, "mode", ""))
    if mode_s == "ship-tree"
        rid_raw = get(rec, "snapshot_id", nothing)
        rid_raw isa AbstractString || throw(
            _selection_error("deploy record is missing snapshot_id; pass --snapshot ID"),
        )
        rid = validate_snapshot_id(rid_raw)
        checked = _validate_snapshot_on_hosts!(host_list, deploy, rid)
        stored_hash = get(rec, "content_tree_hash", nothing)
        if stored_hash isa AbstractString && !isempty(strip(String(stored_hash)))
            stored = strip(String(stored_hash))
            stored == checked.hash || throw(
                _selection_error(
                    "deploy record content_tree_hash $(stored) does not match remote $(checked.hash); pass --snapshot ID",
                ),
            )
        end
        return SnapshotSelection(
            :snapshot,
            rid,
            deploy,
            _snapshot_project_logical(deploy, rid, checked.project_rel),
            checked.hash,
            host_list,
        )
    end
    if mode_s in ("git-clone", "git-sync", "git-pull")
        _validate_git_on_hosts!(host_list, deploy)
        return SnapshotSelection(:git, nothing, deploy, deploy, nothing, host_list)
    end
    throw(_selection_error("deploy record mode $(repr(mode_s)) is not recognized; pass --snapshot ID"))
end

function _warn_deploy_staleness!(project::AbstractString, rec::Union{Nothing, AbstractDict})
    if rec === nothing
        print_warn("Deploy provenance unknown (no .distssh/deploy.toml on remotes).")
        kit_println()
        return nothing
    end
    mode_s = String(get(rec, "mode", ""))
    if mode_s in ("git-clone", "git-sync", "git-pull")
        local_sha = get_local_git_hash(project)
        remote_sha = get(rec, "commit_sha", nothing)
        if !(local_sha isa AbstractString) || !(remote_sha isa AbstractString)
            return nothing
        end
        local_sha == strip(String(remote_sha)) && return nothing
        print_warn(
            "Local git commit $(local_sha[1:min(end, 12)]) differs from deployed $(strip(String(remote_sha))[1:min(end, 12)]) (setup may be stale).",
        )
        kit_println()
        return nothing
    end
    if mode_s == "ship-tree"
        remote_hash = get(rec, "content_tree_hash", nothing)
        remote_hash isa AbstractString || return nothing
        local_mf = manifest_path(project)
        remote_mh = get(rec, "manifest_hash", nothing)
        if local_mf isa String && isfile(local_mf) && remote_mh isa AbstractString
            local_mh = _deploy_record_manifest_hash(project)
            local_mh !== nothing && local_mh != strip(String(remote_mh)) && begin
                print_warn("Local Manifest hash differs from deploy record (tree may be stale).")
                kit_println()
            end
        end
    end
    return nothing
end

function _log_deploy_record_fields!(rec::Union{Nothing, AbstractDict})
    rec === nothing && return nothing
    mode = get(rec, "mode", "—")
    writeln_field("Deploy mode", mode)
    haskey(rec, "deploy_id") && writeln_field("Deploy id", String(rec["deploy_id"]))
    haskey(rec, "commit_sha") && writeln_field("Deployed commit", String(rec["commit_sha"]))
    haskey(rec, "snapshot_id") && writeln_field("Deployed snapshot", String(rec["snapshot_id"]))
    haskey(rec, "content_tree_hash") && writeln_field("Deployed tree", String(rec["content_tree_hash"]))
    get(rec, "dirty", false) == true && writeln_field("Deployed dirty", "true")
    return nothing
end

function _deploy_record_for_provenance(rec::Union{Nothing, AbstractDict})::Union{Nothing, Dict{String, Any}}
    rec === nothing && return nothing
    out = Dict{String, Any}()
    for k in (
            "schema",
            "deploy_id",
            "mode",
            "commit_sha",
            "dirty",
            "manifest_hash",
            "local_path",
            "timestamp",
            "snapshot_id",
            "content_tree_hash",
            "project_rel",
        )
        haskey(rec, k) || continue
        out[k] = rec[k]
    end
    isempty(out) && return nothing
    return out
end

"""After work-root resolution: refresh deploy record, stale warnings, and header fields."""
function record_deploy_status_for_run!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        project::AbstractString;
        skip_deploy_record::Bool = false,
    )
    isempty(hosts) && return nothing
    skip_deploy_record && return nothing
    rec = try
        read_deploy_record_consensus(hosts, deploy_root)
    catch e
        e isa ArgumentError && rethrow()
        nothing
    end
    _set_active_deploy_record!(rec)
    _warn_deploy_staleness!(project, rec)
    _log_deploy_record_fields!(rec)
    return rec
end

function commit_deploy_record_after_git!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        project::AbstractString,
        mode::Symbol;
        dirty::Bool = false,
    )
    sha = get_local_git_hash(project)
    sha isa String || return nothing
    return write_deploy_record_to_hosts!(
        hosts,
        deploy_root,
        project,
        mode;
        deploy_id = sha,
        commit_sha = sha,
        dirty = dirty,
    )
end

function commit_deploy_record_after_ship!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        project::AbstractString,
        run_id::AbstractString,
        content_tree_hash::AbstractString;
        project_rel::AbstractString = ".",
    )
    return write_deploy_record_to_hosts!(
        hosts,
        deploy_root,
        project,
        :ship_tree;
        deploy_id = String(run_id),
        snapshot_id = run_id,
        content_tree_hash = content_tree_hash,
        project_rel = project_rel,
    )
end

let prev = _CLEAR_SELECTION_HOOK[]
    _CLEAR_SELECTION_HOOK[] = () -> begin
        prev()
        _clear_active_deploy_record!()
    end
end
