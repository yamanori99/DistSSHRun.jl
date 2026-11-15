# Go slot stdin handshake for loaded-component verification (same process as the user script).

using Random: RandomDevice, randstring
import SHA

const _GO_HANDSHAKE_LOADER_NAME = "go-handshake.jl"
const _GO_HANDSHAKE_FRAME_PREFIX = "DISTSSH-REPORT/1"
const _GO_HANDSHAKE_ABORT_EXIT = 2
const _GO_HANDSHAKE_FRAME_PREFIX_S = string(_GO_HANDSHAKE_FRAME_PREFIX)

const _GO_HANDSHAKE_LOADER_SRC = let schema = 1,
        run_uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000",
        base_uuid = "f0a69307-14e5-4272-8c28-20680d05bac8",
        queue_uuid = "24254401-70d8-4a51-8ea4-cfab19f5bc73"

    """
    import SHA
    function __distssh_go_handshake!()
        hello = readline(stdin)
        startswith(hello, "HELLO ") || error("go handshake: expected HELLO on stdin")
        nonce = strip(hello[7:end])
        lines = String["schema=$schema"]
        function __push_slot!(component, state, version, uuid, digest, layout, probe)
            push!(lines, "component=\$(component)")
            push!(lines, "state=\$(state)")
            push!(lines, "version=\$(version)")
            push!(lines, "uuid=\$(uuid)")
            push!(lines, "digest=\$(digest)")
            push!(lines, "layout=\$(layout)")
            push!(lines, probe == "" ? "probe_error=" : "probe_error=\$(probe)")
            push!(lines, "---")
            return nothing
        end
        function __read_id(mod)
            id = getfield(mod, :COMPONENT_ID)
            (
                version = string(getproperty(id, :version)),
                uuid = string(getproperty(id, :uuid)),
                digest = string(getproperty(id, :digest)),
            )
        end
        try
            run_mod = Base.require(Base.PkgId(Base.UUID("$run_uuid"), "DistSSHRun"))
            rid = __read_id(run_mod)
            __push_slot!("DistSSHRun", "Loaded", rid.version, rid.uuid, rid.digest, "top_level", "")
            base_mod = getfield(run_mod, :DistSSHBase)
            bid = __read_id(base_mod)
            __push_slot!("DistSSHBase", "Loaded", bid.version, bid.uuid, bid.digest, "bundled", "")
            top_base = nothing
            for (pkg, mod) in Base.loaded_modules
                pkg == Base.PkgId(Base.UUID("$base_uuid"), "DistSSHBase") || continue
                parentmodule(mod) === Base || continue
                top_base = mod
                break
            end
            if top_base !== nothing && top_base !== base_mod
                __push_slot!(
                    "DistSSHBase", "ProbeFailed", "", "$base_uuid", "", "top_level", "dual DistSSHBase layout",
                )
            end
            queue_mod = nothing
            for (pkg, mod) in Base.loaded_modules
                pkg == Base.PkgId(Base.UUID("$queue_uuid"), "DistSSHQueue") || continue
                queue_mod = mod
                break
            end
            if queue_mod === nothing
                __push_slot!("DistSSHQueue", "NotLoaded", "", "$queue_uuid", "", "top_level", "")
            else
                qid = __read_id(queue_mod)
                __push_slot!("DistSSHQueue", "Loaded", qid.version, qid.uuid, qid.digest, "top_level", "")
            end
        catch e
            __push_slot!("DistSSHRun", "ProbeFailed", "", "$run_uuid", "", "top_level", sprint(showerror, e))
        end
        payload = join(lines, '\\n')
        bytes = codeunits(payload)
        plen = length(bytes)
        digest = SHA.bytes2hex(SHA.sha256(bytes))
        hexpay = SHA.bytes2hex(collect(bytes))
        print('\\n', "$(_GO_HANDSHAKE_FRAME_PREFIX_S)", ' ', nonce, ' ', plen, ' ', digest, ' ', hexpay, '\\n')
        flush(stdout)
        cmd = readline(stdin)
        if startswith(cmd, "ABORT ")
            exit($(_GO_HANDSHAKE_ABORT_EXIT))
        end
        startswith(cmd, "GO ") || error("go handshake: expected GO or ABORT on stdin")
        go_nonce = strip(cmd[4:end])
        go_nonce == nonce || error("go handshake: GO nonce mismatch")
        redirect_stderr(stdout)
        return nothing
    end
    __distssh_go_handshake!()
    """
end

function go_handshake_nonce()::String
    return randstring(RandomDevice(), 16)
end

function write_go_handshake_loader(slot_dir::AbstractString)::Union{Nothing, String}
    dest = DistSSHBase.resolve_local_state_dir(String(slot_dir))
    mkpath(dest)
    path = joinpath(dest, _GO_HANDSHAKE_LOADER_NAME)
    write(path, _GO_HANDSHAKE_LOADER_SRC)
    return path
end

function _parse_go_handshake_frame(line::AbstractString, nonce::AbstractString)
    s = strip(String(line))
    startswith(s, _GO_HANDSHAKE_FRAME_PREFIX) || return nothing
    parts = split(s)
    length(parts) < 5 && throw(ArgumentError("go handshake frame: too few fields"))
    parts[2] == String(nonce) ||
        throw(LoadedCodeMismatchError(LoadedMismatchKind.probe_failed, "", "go handshake nonce mismatch"))
    plen = parse(Int, parts[3])
    want = lowercase(String(parts[4]))
    hexpay = String(parts[5])
    bytes = UInt8[]
    for i in 1:2:(length(hexpay) - 1)
        push!(bytes, parse(UInt8, hexpay[i:(i + 1)], base = 16))
    end
    length(bytes) == plen || throw(LoadedCodeMismatchError(LoadedMismatchKind.probe_failed, "", "go handshake length mismatch"))
    got = SHA.bytes2hex(SHA.sha256(bytes))
    got == want || throw(LoadedCodeMismatchError(LoadedMismatchKind.component_id, "", "go handshake payload digest mismatch"))
    return String(bytes)
end

function _go_handshake_log_line!(log_io::Union{Nothing, IO}, line::AbstractString)
    log_io === nothing && return nothing
    println(log_io, line)
    flush(log_io)
    return nothing
end

function _go_handshake_frame_line(payload::AbstractString, nonce::AbstractString)::String
    bytes = codeunits(String(payload))
    plen = length(bytes)
    digest = SHA.bytes2hex(SHA.sha256(bytes))
    hexpay = SHA.bytes2hex(collect(bytes))
    return string(_GO_HANDSHAKE_FRAME_PREFIX, ' ', nonce, ' ', plen, ' ', digest, ' ', hexpay)
end

"""Controller-expected DISTSSH-REPORT/1 line (test doubles and remote sh helpers)."""
function go_handshake_report_frame(nonce::AbstractString)::String
    slots = _controller_loaded_slots(loaded_launch_mode())
    return _go_handshake_frame_line(encode_loaded_wire_report(slots), nonce)
end

function _go_handshake_read_frame(
        io::IO,
        nonce::AbstractString,
        log_io::Union{Nothing, IO} = nothing,
    )::String
    while !eof(io)
        line = readline(io)
        _go_handshake_log_line!(log_io, line)
        wire = _parse_go_handshake_frame(line, nonce)
        wire === nothing && continue
        return wire
    end
    throw(LoadedCodeMismatchError(LoadedMismatchKind.probe_failed, "", "go handshake: no report frame before EOF"))
end

function _go_drain_slot_stdout!(io::IO, log_io::IO)
    while !eof(io)
        try
            data = readavailable(io)
            if isempty(data)
                yield()
                continue
            end
            write(log_io, data)
            flush(log_io)
        catch e
            e isa EOFError && break
            rethrow()
        end
    end
    return nothing
end

function verify_go_handshake_wire!(wire::AbstractString, site::AbstractString)
    schema, observed = decode_loaded_wire_report(wire)
    schema == LOADED_IDENTITY_SCHEMA || throw(
        LoadedCodeMismatchError(
            LoadedMismatchKind.schema_skew,
            site,
            "loaded identity schema=$(schema); expected $(LOADED_IDENTITY_SCHEMA)",
        ),
    )
    mode = loaded_launch_mode()
    expected = _controller_loaded_slots(mode)
    verify_loaded_slots_match!(expected, observed, site)
    return nothing
end

function go_slot_controller_handshake!(
        io::IO,
        site::AbstractString,
        log_io::Union{Nothing, IO} = nothing,
    )
    nonce = go_handshake_nonce()
    println(io, "HELLO ", nonce)
    flush(io)
    wire = _go_handshake_read_frame(io, nonce, log_io)
    verify_go_handshake_wire!(wire, site)
    println(io, "GO ", nonce)
    flush(io)
    return nothing
end

function _go_handshake_await_drain!(drain_task::Task)
    try
        fetch(drain_task)
    catch
    end
    return nothing
end

function run_go_slot_with_handshake(cmd::Cmd, site::AbstractString, log_path::AbstractString)
    log_io = open(String(log_path), "w")
    return try
        proc = open(ignorestatus(cmd); write = true, read = true)
        try
            try
                go_slot_controller_handshake!(proc, site, log_io)
            catch e
                try
                    println(proc, "ABORT ", go_handshake_nonce())
                    flush(proc)
                catch
                end
                rethrow(e)
            end
            drain_task = @async _go_drain_slot_stdout!(proc, log_io)
            wait(proc)
            _go_handshake_await_drain!(drain_task)
            return proc
        finally
            if proc.exitcode === nothing
                try
                    kill(proc)
                catch
                end
            end
        end
    finally
        close(log_io)
    end
end
