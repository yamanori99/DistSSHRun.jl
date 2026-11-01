# Per-run bundle (pid, logs, `run.toml`) separate from user artifact output.

const DISTSSHKIT_RUN_DIR_ENV::String = "DISTSSHKIT_RUN_DIR"
const _KIT_EXECUTE_KINDS = (:go, :drive, :ride)

function _require_execute_kind!(kind::Symbol)
    kind in _KIT_EXECUTE_KINDS || throw(
        ArgumentError(
            "execute! kind must be :go, :drive, or :ride, got $(repr(kind))",
        )
    )
    return nothing
end

"""`ENV["DISTSSHKIT_RUN_DIR"]` when set and non-blank, else `nothing`."""
function kit_run_dir()::Union{Nothing, String}
    raw = strip(get(ENV, DISTSSHKIT_RUN_DIR_ENV, ""))
    isempty(raw) && return nothing
    return canonical_local_path(raw)
end

function _is_permission_denied(e)::Bool
    e isa Base.IOError || return false
    return e.code == Base.UV_EACCES || e.code == Base.UV_EPERM
end

"""Exclusive `mkdir` of `dir`. On EEXIST, retry `dir-<time_ns>`."""
function _mkdir_unique!(dir::AbstractString)::String
    mkpath(dirname(dir))
    base = String(dir)
    made = ""
    while isempty(made)
        try
            mkdir(base)
            made = canonical_local_path(base)
        catch e
            e isa Base.IOError || rethrow()
            e.code == Base.UV_EEXIST || rethrow()
            base = String(dir) * "-" * string(time_ns())
        end
    end
    return made
end

"""
    allocate_run_dir(kind, script; project=pwd(), job_id=nothing) -> String

Create a unique Kit run directory (cancel / logs / `run.toml`), not the
artifact `output_dir`.

Layout: `{script dir}/.distsshkit/runs/<kind>/<script-stem>_<UTC-stamp>/`.
When `job_id` is set it is appended after the stamp (same charset as
[`execute!`](@ref) `job_id`).

If that parent tree is not writable (read-only `pkgdir` / Registry
install), the same leaf is created under `{project}/.distsshkit/runs/…`,
then under `tempdir()/distsshkit-runs/…`.
"""
function allocate_run_dir(
        kind::Symbol,
        script::AbstractString;
        project::AbstractString = pwd(),
        job_id::Union{Nothing, AbstractString} = nothing,
    )::String
    _require_execute_kind!(kind)
    proj = canonical_local_path(project)
    isdir(proj) || throw(ArgumentError("allocate_run_dir: project is not a directory: $proj"))
    stem = splitext(basename(String(script)))[1]
    isempty(stem) && throw(ArgumentError("allocate_run_dir: empty script basename"))
    stamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyymmddTHHMMSS") * "Z"
    leaf = if job_id !== nothing && !isempty(strip(String(job_id)))
        "$(stem)_$(stamp)_$(_parse_kit_job_id(String(job_id)))"
    else
        "$(stem)_$(stamp)"
    end
    raw = String(script)
    script_path = isabspath(raw) ? raw : joinpath(proj, raw)
    script_dir = dirname(canonical_local_path(script_path))
    rel = joinpath(".distsshkit", "runs", String(kind), leaf)
    candidates = (
        joinpath(script_dir, rel),
        joinpath(proj, rel),
        joinpath(tempdir(), "distsshkit-runs", String(kind), leaf),
    )
    last = nothing
    seen = Set{String}()
    for dir in candidates
        dir in seen && continue
        push!(seen, dir)
        try
            return _mkdir_unique!(dir)
        catch e
            _is_permission_denied(e) || rethrow()
            last = e
        end
    end
    last === nothing && error("allocate_run_dir: no candidate path")
    throw(last)
end

function _ensure_kit_run_dir!(
        kind::Symbol,
        script::AbstractString;
        project::AbstractString = pwd(),
        job_id::Union{Nothing, AbstractString} = nothing,
    )::String
    existing = kit_run_dir()
    if existing !== nothing
        mkpath(existing)
        return existing
    end
    jid = job_id
    if jid === nothing
        jid = resolved_kit_job_id()
    end
    dir = allocate_run_dir(kind, script; project = project, job_id = jid)
    ENV[DISTSSHKIT_RUN_DIR_ENV] = dir
    return dir
end

function _restore_kit_run_dir_env!(old)::Nothing
    if old === nothing || (old isa AbstractString && isempty(strip(String(old))))
        delete!(ENV, DISTSSHKIT_RUN_DIR_ENV)
    else
        ENV[DISTSSHKIT_RUN_DIR_ENV] = String(old)
    end
    return nothing
end

"""Setup log directory: this run's `DISTSSHKIT_RUN_DIR`, else `{project}/.distsshkit/setup`."""
function setup_log_dir(project::AbstractString)::String
    rd = kit_run_dir()
    rd !== nothing && return rd
    return joinpath(canonical_local_path(project), ".distsshkit", "setup")
end

function kit_run_toml_path(run_dir::AbstractString)::String
    return joinpath(canonical_local_path(run_dir), "run.toml")
end

function _list_kit_run_logs(run_dir::AbstractString)::Vector{String}
    isdir(run_dir) || return String[]
    out = String[]
    for name in readdir(run_dir)
        endswith(lowercase(name), ".log") || continue
        push!(out, joinpath(run_dir, String(name)))
    end
    sort!(out)
    return out
end

function _collect_dirs_from_env(;
        project_root::Union{Nothing, AbstractString} = nothing,
    )::Vector{String}
    spec = String(strip(get(ENV, "DISTRIBUTED_COLLECT_DIRS", "")))
    isempty(spec) && return String[]
    repo = project_root isa AbstractString ? canonical_local_path(project_root) : nothing
    out = String[]
    seen = Set{String}()
    for chunk in split(spec, ':')
        p = String(strip(String(chunk)))
        isempty(p) && continue
        raw = String(expanduser(p))
        ap = if repo isa String
            canonical_local_path(isabspath(raw) ? raw : joinpath(repo, raw))
        else
            canonical_local_path(raw)
        end
        ap in seen && continue
        push!(seen, ap)
        push!(out, ap)
    end
    return out
end

function _record_path(path::AbstractString, project_root::Union{Nothing, AbstractString})::String
    s = canonical_local_path(path)
    if project_root isa AbstractString && !isempty(project_root)
        root = canonical_local_path(project_root)
        if s == root
            return "."
        end
        if startswith(s, root * "/")
            return relpath(s, root)
        end
    end
    tmp = try
        canonical_local_path(tempdir())
    catch
        ""
    end
    if !isempty(tmp) && (s == tmp || startswith(s, tmp * "/"))
        b = basename(s)
        return isempty(b) ? "." : b
    end
    home = homedir()
    if !isempty(home) && (s == home || startswith(s, home * "/"))
        return s == home ? "~" : "~" * s[(ncodeunits(home) + 1):end]
    end
    b = basename(s)
    return isempty(b) ? "." : b
end

function _recorded_env_names()::Vector{String}
    names = String[]
    for k in keys(ENV)
        ks = String(k)
        occursin("COOKIE", uppercase(ks)) && continue
        startswith(ks, "DISTSSHKIT_") || startswith(ks, "DISTRIBUTED_") || continue
        push!(names, ks)
    end
    sort!(names)
    return names
end

"""Write machine-readable `run.toml` under `run_dir`. Never throws."""
function write_kit_run_toml!(
        run_dir::AbstractString;
        kind::Symbol,
        output_dir::Union{Nothing, AbstractString} = nothing,
        log_dir::Union{Nothing, AbstractString} = nothing,
        result::Union{Nothing, KitRunResult} = nothing,
        project_root::Union{Nothing, AbstractString} = nothing,
        provenance::Union{Nothing, AbstractDict} = nothing,
    )
    d = canonical_local_path(run_dir)
    data = Dict{String, Any}(
        "schema" => 1,
        "writer" => "DistSSHRun $(dist_ssh_kit_version())",
        "kind" => String(kind),
        "run_dir" => _record_path(d, project_root),
    )
    jid = resolved_kit_job_id()
    jid !== nothing && (data["job_id"] = jid)
    if output_dir !== nothing && !isempty(strip(String(output_dir)))
        data["output_dir"] = _record_path(String(output_dir), project_root)
    end
    if log_dir !== nothing && !isempty(strip(String(log_dir)))
        data["log_dir"] = _record_path(String(log_dir), project_root)
    end
    logs = _list_kit_run_logs(d)
    isempty(logs) || (data["logs"] = String[_record_path(p, project_root) for p in logs])
    cols = _collect_dirs_from_env(; project_root = project_root)
    isempty(cols) || (data["collect_dirs"] = String[_record_path(p, project_root) for p in cols])
    env_names = _recorded_env_names()
    isempty(env_names) || (data["env"] = env_names)
    if result !== nothing
        data["ok"] = result.ok
        data["exit_code"] = result.exit_code
        result.failed_step !== nothing && (data["failed_step"] = result.failed_step)
        result.stop !== nothing && (data["stop"] = String(result.stop))
    end
    provenance !== nothing && (data["provenance"] = provenance)
    recorded_inputs = _read_declared_input_rows(d)
    recorded_inputs === nothing || (data["inputs"] = recorded_inputs)
    try
        mkpath(d)
        dest = kit_run_toml_path(d)
        tmp = dest * ".tmp"
        open(tmp, "w") do io
            TOML.print(io, data)
        end
        mv(tmp, dest; force = true)
    catch
        # best-effort only
    end
    _write_provenance_sidecar(output_dir, provenance)
    return nothing
end

"""True when `run.toml` is this package's schema 1 manifest, not an arbitrary TOML file."""
function _kit_run_toml_owned(raw::AbstractDict)::Bool
    schema = get(raw, "schema", nothing)
    schema isa Integer || return false
    schema == 1 || return false
    writer = get(raw, "writer", nothing)
    writer isa AbstractString || return false
    startswith(String(writer), "DistSSHRun ") || return false
    kind = get(raw, "kind", nothing)
    kind isa AbstractString || return false
    ks = String(kind)
    return ks == "go" || ks == "drive" || ks == "ride" || ks == "pipeline" ||
        ks == "ship"
end

"""Set `stop` on this package's `run.toml`. Leaves any other file alone. Never throws."""
function _stamp_run_toml_stop!(run_dir::AbstractString, stop::Symbol)
    _kit_stop_symbol(stop) === nothing && return nothing
    raw = read_kit_run_toml(run_dir)
    raw === nothing && return nothing
    _kit_run_toml_owned(raw) || return nothing
    data = Dict{String, Any}(String(k) => v for (k, v) in raw)
    data["stop"] = String(stop)
    try
        d = canonical_local_path(run_dir)
        isdir(d) || return nothing
        dest = kit_run_toml_path(d)
        tmp = dest * ".tmp"
        open(tmp, "w") do io
            TOML.print(io, data)
        end
        mv(tmp, dest; force = true)
    catch
        # best-effort only
    end
    return nothing
end

"""Read `run.toml` from a run directory (or the file itself). `nothing` if missing."""
function read_kit_run_toml(path::AbstractString)
    p = canonical_local_path(path)
    file = isdir(p) ? kit_run_toml_path(p) : p
    isfile(file) || return nothing
    raw = try
        TOML.parsefile(file)
    catch
        return nothing
    end
    return raw isa AbstractDict ? raw : nothing
end
