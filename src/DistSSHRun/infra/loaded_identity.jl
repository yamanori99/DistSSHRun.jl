# Loaded DistSSH component verification (separate from `run_identity` / env digests).

const LOADED_IDENTITY_SCHEMA = 1

const _RUN_PKG_UUID = Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000")
const _BASE_PKG_UUID = Base.UUID("f0a69307-14e5-4272-8c28-20680d05bac8")
const _QUEUE_PKG_UUID = Base.UUID("24254401-70d8-4a51-8ea4-cfab19f5bc73")
const _WORKER_RUN_UUID_STR = string(_RUN_PKG_UUID)
const _WORKER_QUEUE_UUID_STR = string(_QUEUE_PKG_UUID)

const _KIT_PKG_NAME = "DistSSHKit"

struct LoadedComponentId
    schema::Int
    name::String
    uuid::Base.UUID
    version::String
    digest::String
end

struct LoadedSlotReport
    component::Symbol
    state::Symbol
    version::String
    uuid::Base.UUID
    digest::String
    layout::Symbol
    probe_error::String
end

module LoadedMismatchKind
    const schema_skew = :schema_skew
    const component_id = :component_id
    const dual_layout = :dual_layout
    const probe_failed = :probe_failed
    const not_loaded = :not_loaded
    const unreadable = :unreadable
end

"""
Worker or controller loaded DistSSH component ids do not match the expected set.

Separate from manifest/project checks in [`identity_mismatches`](@ref); not waived
by `--unsafe-heterogeneous`.
"""
struct LoadedCodeMismatchError <: Exception
    kind::Symbol
    site::String
    detail::String
end

function Base.showerror(io::IO, e::LoadedCodeMismatchError)
    print(io, "LoadedCodeMismatchError: ")
    print(io, e.detail)
    print(io, " (kind=")
    print(io, e.kind)
    print(io, ")")
    isempty(e.site) || print(io, "\n  site=", e.site)
    return nothing
end

function loaded_launch_mode()::Symbol
    for (pkg, _) in Base.loaded_modules
        pkg.name == "DistSSHQueue" && return :queue_job
    end
    return :worker_job
end

function _kit_loaded_diagnostic()::String
    for (pkg, _) in Base.loaded_modules
        pkg.name == _KIT_PKG_NAME && return "controller: $_KIT_PKG_NAME is loaded (not compared on workers)"
    end
    return ""
end

function _slot_states()::Tuple{Symbol, Symbol, Symbol, Symbol}
    return (:Loaded, :NotLoaded, :Unreadable, :ProbeFailed)
end

function _component_id_from_module(mod::Module)::LoadedComponentId
    id = getfield(mod, :COMPONENT_ID)
    schema = Int(getproperty(id, :schema))
    name = String(getproperty(id, :name))
    uuid = getproperty(id, :uuid)::Base.UUID
    version = String(getproperty(id, :version))
    digest = String(getproperty(id, :digest))
    return LoadedComponentId(schema, name, uuid, version, digest)
end

function _read_top_level_base_id()::Union{Nothing, LoadedComponentId}
    for (pkg, mod) in Base.loaded_modules
        pkg == Base.PkgId(_BASE_PKG_UUID, "DistSSHBase") || continue
        parent = parentmodule(mod)
        parent === Base && return _component_id_from_module(mod)
    end
    return nothing
end

function _assert_no_dual_distsshbase!()
    top = _read_top_level_base_id()
    top === nothing && return nothing
    bundled = DistSSHBase
    bundled === nothing && return nothing
    bundled === top && return nothing
    throw(
        LoadedCodeMismatchError(
            LoadedMismatchKind.dual_layout,
            "ControllerParent",
            "top-level DistSSHBase and DistSSHRun.DistSSHBase are both loaded; project must not depend on standalone DistSSHBase when using DistSSHRun",
        ),
    )
end

function _controller_slot_for_base()::LoadedSlotReport
    id = _component_id_from_module(DistSSHRun.DistSSHBase)
    return LoadedSlotReport(
        :DistSSHBase,
        :Loaded,
        id.version,
        id.uuid,
        id.digest,
        :bundled,
        "",
    )
end

function _controller_slot_for_run()::LoadedSlotReport
    id = _component_id_from_module(DistSSHRun)
    return LoadedSlotReport(
        :DistSSHRun,
        :Loaded,
        id.version,
        id.uuid,
        id.digest,
        :top_level,
        "",
    )
end

function _controller_slot_for_queue()::Union{Nothing, LoadedSlotReport}
    for (pkg, mod) in Base.loaded_modules
        pkg.name == "DistSSHQueue" || continue
        id = _component_id_from_module(mod)
        return LoadedSlotReport(
            :DistSSHQueue,
            :Loaded,
            id.version,
            id.uuid,
            id.digest,
            :top_level,
            "",
        )
    end
    return LoadedSlotReport(:DistSSHQueue, :NotLoaded, "", _QUEUE_PKG_UUID, "", :top_level, "")
end

function required_loaded_components(mode::Symbol)::Vector{Symbol}
    mode == :queue_job && return [:DistSSHBase, :DistSSHRun, :DistSSHQueue]
    return [:DistSSHBase, :DistSSHRun]
end

function _controller_loaded_slots(mode::Symbol)::Vector{LoadedSlotReport}
    _assert_no_dual_distsshbase!()
    slots = LoadedSlotReport[
        _controller_slot_for_base(),
        _controller_slot_for_run(),
    ]
    if mode == :queue_job
        q = _controller_slot_for_queue()
        q !== nothing && push!(slots, q)
    end
    return slots
end

function _slots_index(slots::AbstractVector{LoadedSlotReport})::Dict{Symbol, LoadedSlotReport}
    d = Dict{Symbol, LoadedSlotReport}()
    for s in slots
        d[s.component] = s
    end
    return d
end

function _slot_wire_lines(s::LoadedSlotReport)::Vector{String}
    return String[
        "component=$(s.component)",
        "state=$(s.state)",
        "version=$(s.version)",
        "uuid=$(s.uuid)",
        "digest=$(s.digest)",
        "layout=$(s.layout)",
        isempty(s.probe_error) ? "probe_error=" : "probe_error=$(s.probe_error)",
    ]
end

function encode_loaded_wire_report(slots::AbstractVector{LoadedSlotReport})::String
    lines = String["schema=$(LOADED_IDENTITY_SCHEMA)"]
    for s in slots
        append!(lines, _slot_wire_lines(s))
        push!(lines, "---")
    end
    return join(lines, '\n')
end

function _parse_slot_block(lines::AbstractVector{String})::LoadedSlotReport
    d = Dict{String, String}()
    for line in lines
        eq = findfirst('=', line)
        eq === nothing && continue
        k = strip(line[1:(eq - 1)])
        v = strip(line[(eq + 1):end])
        d[k] = v
    end
    comp = get(d, "component", "")
    isempty(comp) && throw(ArgumentError("loaded wire report: missing component"))
    state = Symbol(get(d, "state", "Unreadable"))
    ver = get(d, "version", "")
    uuid_s = get(d, "uuid", "")
    uuid = try
        Base.UUID(uuid_s)
    catch
        Base.UUID(zero(UInt128))
    end
    digest = get(d, "digest", "")
    layout = Symbol(get(d, "layout", "top_level"))
    probe = get(d, "probe_error", "")
    return LoadedSlotReport(Symbol(comp), state, ver, uuid, digest, layout, probe)
end

function decode_loaded_wire_report(text::AbstractString)::Tuple{Int, Vector{LoadedSlotReport}}
    schema = LOADED_IDENTITY_SCHEMA
    slots = LoadedSlotReport[]
    block = String[]
    for line in split(String(text), '\n'; keepempty = false)
        s = strip(line)
        isempty(s) && continue
        if s == "---"
            isempty(block) || push!(slots, _parse_slot_block(block))
            empty!(block)
            continue
        end
        if startswith(s, "schema=")
            schema = try
                parse(Int, strip(s[8:end]))
            catch
                -1
            end
            continue
        end
        push!(block, s)
    end
    isempty(block) || push!(slots, _parse_slot_block(block))
    return schema, slots
end

function _compare_slot(expected::LoadedSlotReport, observed::LoadedSlotReport, site::String)
    if observed.state == :ProbeFailed
        msg = isempty(observed.probe_error) ? "identity probe failed" : observed.probe_error
        throw(LoadedCodeMismatchError(LoadedMismatchKind.probe_failed, site, msg))
    end
    if observed.state == :Unreadable
        throw(
            LoadedCodeMismatchError(
                LoadedMismatchKind.unreadable,
                site,
                "component=$(expected.component) identity was unreadable on the worker",
            ),
        )
    end
    if observed.state == :NotLoaded
        throw(
            LoadedCodeMismatchError(
                LoadedMismatchKind.not_loaded,
                site,
                "component=$(expected.component) was not loaded on the worker",
            ),
        )
    end
    observed.state == :Loaded || throw(
        LoadedCodeMismatchError(
            LoadedMismatchKind.unreadable,
            site,
            "component=$(expected.component) reported state=$(observed.state)",
        ),
    )
    expected.component == :DistSSHBase && observed.layout != :bundled &&
        throw(
        LoadedCodeMismatchError(
            LoadedMismatchKind.dual_layout,
            site,
            "component=DistSSHBase must be bundled in DistSSHRun.DistSSHBase on workers (got layout=$(observed.layout))",
        ),
    )
    if expected.version != observed.version || expected.uuid != observed.uuid ||
            expected.digest != observed.digest
        throw(
            LoadedCodeMismatchError(
                LoadedMismatchKind.component_id,
                site,
                "DistSSH $(expected.component) loaded code does not match the controller\n  controller: version=$(expected.version) uuid=$(expected.uuid) digest=$(expected.digest)\n  observed:   version=$(observed.version) uuid=$(observed.uuid) digest=$(observed.digest)",
            ),
        )
    end
    return nothing
end

function verify_loaded_slots_match!(
        expected::AbstractVector{LoadedSlotReport},
        observed::AbstractVector{LoadedSlotReport},
        site::AbstractString,
    )
    exp_idx = _slots_index(expected)
    obs_idx = _slots_index(observed)
    for name in keys(exp_idx)
        e = exp_idx[name]
        o = get(obs_idx, name, LoadedSlotReport(name, :NotLoaded, "", Base.UUID(0), "", :top_level, ""))
        _compare_slot(e, o, String(site))
    end
    return nothing
end

function _worker_loaded_identity_expr()
    return quote
        let
            lines = String[string("schema=", $(LOADED_IDENTITY_SCHEMA))]
            run_uuid = $(_WORKER_RUN_UUID_STR)
            queue_uuid = $(_WORKER_QUEUE_UUID_STR)
            function __push_slot!(component, state, version, uuid, digest, layout, probe)
                push!(lines, "component=" * string(component))
                push!(lines, "state=" * string(state))
                push!(lines, "version=" * string(version))
                push!(lines, "uuid=" * string(uuid))
                push!(lines, "digest=" * string(digest))
                push!(lines, "layout=" * string(layout))
                push!(
                    lines,
                    probe == "" ? "probe_error=" : "probe_error=" * string(probe),
                )
                push!(lines, "---")
                return nothing
            end
            function __read_component_id(mod)
                id = getfield(mod, :COMPONENT_ID)
                return (
                    version = string(getproperty(id, :version)),
                    uuid = string(getproperty(id, :uuid)),
                    digest = string(getproperty(id, :digest)),
                )
            end
            local probe_err = ""
            try
                run_mod = Base.require(Base.PkgId(Base.UUID(run_uuid), "DistSSHRun"))
                rid = __read_component_id(run_mod)
                __push_slot!(
                    "DistSSHRun",
                    "Loaded",
                    rid.version,
                    rid.uuid,
                    rid.digest,
                    "top_level",
                    "",
                )
                base_mod = getfield(run_mod, :DistSSHBase)
                bid = __read_component_id(base_mod)
                __push_slot!(
                    "DistSSHBase",
                    "Loaded",
                    bid.version,
                    bid.uuid,
                    bid.digest,
                    "bundled",
                    "",
                )
                top_base = nothing
                for (pkg, mod) in Base.loaded_modules
                    pkg == Base.PkgId($(_BASE_PKG_UUID), "DistSSHBase") || continue
                    parentmodule(mod) === Base || continue
                    top_base = mod
                    break
                end
                if top_base !== nothing && top_base !== base_mod
                    __push_slot!(
                        "DistSSHBase",
                        "ProbeFailed",
                        "",
                        string($(_BASE_PKG_UUID)),
                        "",
                        "top_level",
                        "dual DistSSHBase layout",
                    )
                end
                queue_mod = nothing
                for (pkg, mod) in Base.loaded_modules
                    pkg == Base.PkgId(Base.UUID(queue_uuid), "DistSSHQueue") || continue
                    queue_mod = mod
                    break
                end
                if queue_mod === nothing
                    __push_slot!(
                        "DistSSHQueue",
                        "NotLoaded",
                        "",
                        queue_uuid,
                        "",
                        "top_level",
                        "",
                    )
                else
                    qid = __read_component_id(queue_mod)
                    __push_slot!(
                        "DistSSHQueue",
                        "Loaded",
                        qid.version,
                        qid.uuid,
                        qid.digest,
                        "top_level",
                        "",
                    )
                end
            catch e
                probe_err = sprint(showerror, e)
                __push_slot!(
                    "DistSSHRun",
                    "ProbeFailed",
                    "",
                    run_uuid,
                    "",
                    "top_level",
                    probe_err,
                )
            end
            join(lines, '\n')
        end
    end
end

const _WORKER_LOADED_IDENTITY_OVERRIDE = Ref{Any}(nothing)
const _LOADED_VERIFIED_WORKER_IDS = Ref{Union{Nothing, Set{Int}}}(nothing)

function _fetch_worker_loaded_wire(pid::Integer)::String
    override = _WORKER_LOADED_IDENTITY_OVERRIDE[]
    if override isa Function
        return String(override(Int(pid)))
    end
    return String(fetch(remotecall_eval(Main, pid, _worker_loaded_identity_expr())))
end

export LoadedCodeMismatchError

public LoadedComponentId, LoadedSlotReport
public decode_loaded_wire_report, encode_loaded_wire_report, loaded_launch_mode
public required_loaded_components, verify_loaded_slots_match!

function assert_controller_loaded_identity!()
    mode = loaded_launch_mode()
    diag = _kit_loaded_diagnostic()
    isempty(diag) || @debug diag
    _ = _controller_loaded_slots(mode)
    return nothing
end
public assert_controller_loaded_identity!

function verify_workers_loaded_identity!()
    mode = loaded_launch_mode()
    expected = _controller_loaded_slots(mode)
    worker_ids = _live_owned_worker_ids()
    mismatch_lock = ReentrantLock()
    errors = LoadedCodeMismatchError[]
    @sync for w in worker_ids
        @async begin
            host, rank = _worker_placement(w)
            rank_s = rank > 0 ? string(rank) : "?"
            site = "DistributedWorker rank=$(rank_s) pid=$(w) host=$(host)"
            try
                wire = _fetch_worker_loaded_wire(w)
                schema, observed = decode_loaded_wire_report(wire)
                schema == LOADED_IDENTITY_SCHEMA || throw(
                    LoadedCodeMismatchError(
                        LoadedMismatchKind.schema_skew,
                        site,
                        "loaded identity schema=$(schema); expected $(LOADED_IDENTITY_SCHEMA)",
                    ),
                )
                verify_loaded_slots_match!(expected, observed, site)
            catch e
                e isa LoadedCodeMismatchError || rethrow()
                lock(mismatch_lock) do
                    push!(errors, e)
                end
            end
        end
    end
    isempty(errors) || begin
        detail = join(["$(e.detail) (kind=$(e.kind), site=$(e.site))" for e in errors], "\n  ")
        throw(LoadedCodeMismatchError(LoadedMismatchKind.component_id, "", detail))
    end
    _record_loaded_verified_workers!(worker_ids)
    return nothing
end

function _record_loaded_verified_workers!(ids::AbstractVector{<:Integer})
    _LOADED_VERIFIED_WORKER_IDS[] = Set(Int.(ids))
    return nothing
end

"""After loaded verification, worker set must be unchanged when user code starts."""
function assert_loaded_verified_worker_set!()
    verified = _LOADED_VERIFIED_WORKER_IDS[]
    verified === nothing && return nothing
    live = Set(_live_owned_worker_ids())
    live == verified && return nothing
    added = setdiff(live, verified)
    removed = setdiff(verified, live)
    throw(
        LoadedCodeMismatchError(
            LoadedMismatchKind.probe_failed,
            "ControllerParent",
            "worker set changed after loaded verification (added=$(collect(added)); removed=$(collect(removed)))",
        ),
    )
end
public assert_loaded_verified_worker_set!
