# Shipped-record at `<extract_dest>/.distssh/shipped.toml` (schema 1).
# `transfer_tree` writes `complete = true` only after verified extract.
# Readers treat a missing record or `complete = false` as not usable.

const SHIPPED_RECORD_SCHEMA = 1
const SHIPPED_RECORD_DIR = ".distssh"
const SHIPPED_RECORD_NAME = "shipped.toml"
const _SHIPPED_RECORD_TMP_TAIL = ".tmp"

const _SHIP_PKG_VERSION = begin
    path = joinpath(@__DIR__, "..", "Project.toml")
    if isfile(path)
        string(get(TOML.parsefile(path), "version", "0.0.0"))
    else
        "0.0.0"
    end
end

function _posix_rstrip_slash(path::AbstractString)::String
    return rstrip(replace(strip(String(path)), '\\' => '/'), '/')
end

"""POSIX path to the shipped record under an extract directory."""
function shipped_record_logical_path(extract_dest::AbstractString)::String
    root = _posix_rstrip_slash(extract_dest)
    return string(root, "/", SHIPPED_RECORD_DIR, "/", SHIPPED_RECORD_NAME)
end

function _shipped_record_writer()::String
    return "DistSSHShip $_SHIP_PKG_VERSION"
end

function _shipped_record_timestamp()::String
    return Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"
end

function _valid_content_tree_hash(hash::AbstractString)::Bool
    h = strip(String(hash))
    length(h) == 40 || return false
    for c in h
        isxdigit(c) || return false
    end
    return true
end

function _normalize_project_rel(project_rel::AbstractString)::String
    rel = replace(String(project_rel), '\\' => '/')
    rel == "." && return rel
    (isempty(rel) || startswith(rel, "/") || occursin("//", rel)) && throw(
        ArgumentError("project_rel must be a relative directory, got $(repr(project_rel))"),
    )
    for part in split(rel, '/')
        (
            isempty(part) || part == "." || part == ".." || occursin('\n', part) ||
                any(iscntrl, part)
        ) && throw(
            ArgumentError("project_rel must be a relative directory, got $(repr(project_rel))"),
        )
    end
    return rel
end

"""
Build a schema-1 shipped record table (not yet written).

`project_rel` is stored in TOML only; remote shell paths for the record use
`DistSSHBase._remote_shell_path_word` (POSIX-quoted).
"""
function build_shipped_record(
        snapshot::ShipSnapshot;
        complete::Bool = false,
        transfer_id::Union{Nothing, AbstractString} = nothing,
    )::Dict{String, Any}
    h = String(snapshot.content_tree_hash)
    _valid_content_tree_hash(h) || throw(
        ArgumentError(
            "content_tree_hash must be a 40-digit git-sha1 hex string, got $(repr(h))",
        ),
    )
    rel = _normalize_project_rel(snapshot.project_rel)
    data = Dict{String, Any}(
        "schema" => SHIPPED_RECORD_SCHEMA,
        "writer" => _shipped_record_writer(),
        "complete" => complete,
        "algorithm" => TREE_HASH_ALGORITHM,
        "content_tree_hash" => h,
        "bytes" => snapshot.bytes,
        "files" => snapshot.files,
        "timestamp" => _shipped_record_timestamp(),
    )
    rel == "." || (data["project_rel"] = rel)
    if !isempty(snapshot.extra_rels)
        data["extra_rels"] = String[String(r) for r in snapshot.extra_rels]
    end
    if transfer_id isa AbstractString && !isempty(strip(String(transfer_id)))
        data["transfer_id"] = strip(String(transfer_id))
    end
    return data
end

function _parse_shipped_record_body(body::AbstractString)::Union{Nothing, Dict{String, Any}}
    s = strip(String(body))
    isempty(s) && return nothing
    try
        raw = TOML.parse(s)
        raw isa AbstractDict || return nothing
        schema = get(raw, "schema", nothing)
        schema isa Integer && schema == SHIPPED_RECORD_SCHEMA || return nothing
        writer = get(raw, "writer", nothing)
        writer isa AbstractString && startswith(strip(String(writer)), "DistSSHShip") || return nothing
        complete = get(raw, "complete", nothing)
        complete isa Bool || return nothing
        algo = get(raw, "algorithm", nothing)
        algo isa AbstractString && strip(String(algo)) == TREE_HASH_ALGORITHM || return nothing
        hash = get(raw, "content_tree_hash", nothing)
        hash isa AbstractString && _valid_content_tree_hash(strip(String(hash))) || return nothing
        if haskey(raw, "project_rel")
            pr = get(raw, "project_rel", nothing)
            pr isa AbstractString || return nothing
            try
                _normalize_project_rel(String(pr))
            catch
                return nothing
            end
        end
        return Dict{String, Any}(raw)
    catch
        return nothing
    end
end

"""
`:missing`, `:invalid`, `:in_progress`, or `:complete` for a parsed or absent record.
"""
function shipped_record_status(rec::Union{Nothing, AbstractDict})::Symbol
    rec === nothing && return :missing
    parsed = _parse_shipped_record_body(sprint(TOML.print, rec))
    parsed === nothing && return :invalid
    get(parsed, "complete", false) == true && return :complete
    return :in_progress
end

function _shipped_record_write_nonce()::String
    salt = UInt64(0x244696c4bcd4083a)
    seed = hash((time_ns(), objectid(current_task()), Threads.threadid()), salt)
    hex = string(seed, base = 16, pad = 16)
    return lowercase(hex[1:min(end, 16)])
end

function _shipped_record_tmp_path(record_path::AbstractString)::String
    stamp = replace(_shipped_record_timestamp(), ':' => '-')
    nonce = _shipped_record_write_nonce()
    return string(record_path, ".", stamp, "-", nonce, _SHIPPED_RECORD_TMP_TAIL)
end

function _shipped_record_scp_argv(
        host::AbstractString,
        remote_tmp::AbstractString,
        local_path::AbstractString,
    )::Vector{String}
    h = DistSSHBase.validate_ssh_host(String(host))
    remote = String(remote_tmp)
    any(iscntrl, remote) && throw(
        ArgumentError("shipped record remote path contains a control character"),
    )
    dest = string(h, ":", remote)
    return String[DistSSHBase.ssh_opts()..., String(local_path), dest]
end

function _shipped_record_atomic_install_script(record_path::AbstractString, tmp_path::AbstractString)::String
    final_q = DistSSHBase._remote_shell_path_word(record_path)
    tmp_q = DistSSHBase._remote_shell_path_word(tmp_path)
    return "mv -f $tmp_q $final_q"
end

function _shipped_record_mkdir_script(extract_dest::AbstractString)::String
    record = shipped_record_logical_path(extract_dest)
    parent = dirname(record)
    pq = DistSSHBase._remote_shell_path_word(parent)
    return "mkdir -p $pq && chmod 755 $pq"
end

"""
Write `data` to `<extract_dest>/.distssh/shipped.toml` on `host` (atomic tmp + mv).
"""
function write_shipped_record!(
        host::AbstractString,
        extract_dest::AbstractString,
        data::AbstractDict,
    )
    body = sprint(TOML.print, data)
    parsed = _parse_shipped_record_body(body)
    parsed === nothing && throw(ArgumentError("shipped record body is invalid before write"))
    tmp = tempname()
    record_path = shipped_record_logical_path(extract_dest)
    record_tmp = _shipped_record_tmp_path(record_path)
    try
        open(tmp, "w") do io
            print(io, body)
        end
        code_mk, _ = DistSSHBase._remote_shell_status(String(host), _shipped_record_mkdir_script(extract_dest))
        code_mk == 0 || throw(ArgumentError("shipped record: mkdir on $(host) failed"))
        proc_scp = run(
            pipeline(
                ignorestatus(DistSSHBase._scp_cmd(_shipped_record_scp_argv(String(host), record_tmp, tmp)));
                stdout = devnull,
                stderr = devnull,
            );
            wait = true,
        )
        DistSSHBase.shell_status(proc_scp) == 0 ||
            throw(ArgumentError("shipped record: scp to $(host) failed"))
        install = _shipped_record_atomic_install_script(record_path, record_tmp)
        code_mv, _ = DistSSHBase._remote_shell_status(String(host), install)
        code_mv == 0 || begin
            tmp_q = DistSSHBase._remote_shell_path_word(record_tmp)
            try
                run(
                    pipeline(
                        ignorestatus(DistSSHBase._host_sync_remote_shell_cmd(String(host), "rm -f $tmp_q"));
                        stdout = devnull,
                        stderr = devnull,
                    );
                    wait = true,
                )
            catch e
                e isa InterruptException && rethrow()
            end
            throw(ArgumentError("shipped record: install on $(host) failed"))
        end
    catch e
        DistSSHBase._rethrow_missing_host_tool(e)
        rethrow()
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
    return nothing
end

"""Read `<extract_dest>/.distssh/shipped.toml` on `host`, or `nothing` when missing or invalid."""
function read_shipped_record(
        host::AbstractString,
        extract_dest::AbstractString,
    )::Union{Nothing, Dict{String, Any}}
    pq = DistSSHBase._remote_shell_path_word(shipped_record_logical_path(extract_dest))
    out = IOBuffer()
    err = IOBuffer()
    proc = run(
        pipeline(
            ignorestatus(DistSSHBase._host_sync_remote_shell_cmd(String(host), "test -f $pq && cat $pq"));
            stdout = out,
            stderr = err,
        );
        wait = true,
    )
    DistSSHBase.shell_status(proc) == 0 || return nothing
    return _parse_shipped_record_body(String(take!(out)))
end

"""
Read the record and return `(status, record)` where `status` is
[`shipped_record_status`](@ref).
"""
function read_shipped_record_status(
        host::AbstractString,
        extract_dest::AbstractString,
    )::Tuple{Symbol, Union{Nothing, Dict{String, Any}}}
    rec = read_shipped_record(host, extract_dest)
    return shipped_record_status(rec), rec
end

"""
Require a complete record at `extract_dest`. `expect_hash`, when set, must match.

This checks the record on the host (`complete` and optional hash field). It does
not re-hash the tree. Tree equality is defined by `content_tree_hash` of the
shipped payload; files under `<extract_dest>/.distssh/` are not part of that
hash.
"""
function verify_shipped_record(
        host::AbstractString,
        extract_dest::AbstractString;
        expect_hash::Union{Nothing, AbstractString} = nothing,
    )::Tuple{Symbol, Dict{String, Any}}
    status, rec = read_shipped_record_status(host, extract_dest)
    status == :complete || throw(
        ArgumentError("shipped record on $(host) is not complete (status=$(status))"),
    )
    rec === nothing && throw(ArgumentError("shipped record on $(host) is missing"))
    if expect_hash isa AbstractString && !isempty(strip(String(expect_hash)))
        want = strip(String(expect_hash))
        got = strip(String(get(rec, "content_tree_hash", "")))
        want == got || throw(
            ArgumentError(
                "shipped record content_tree_hash $(got) does not match expected $(want)",
            ),
        )
    end
    return status, rec
end

function _write_complete_record!(
        host::AbstractString,
        extract_dest::AbstractString,
        snapshot::ShipSnapshot,
    )
    data = build_shipped_record(snapshot; complete = true)
    write_shipped_record!(host, extract_dest, data)
    return nothing
end
