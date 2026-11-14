# Worker environment vs the job tree. Default errors; `--unsafe-heterogeneous` waives checks.

const _UNSAFE_HETEROGENEOUS = Ref(false)

"""Process-global waiver used by drive, ride, and go during worker checks."""
function unsafe_heterogeneous_active()::Bool
    return _UNSAFE_HETEROGENEOUS[]
end

function with_unsafe_heterogeneous(f::Function, enabled::Bool)
    enabled || return f()
    old = _UNSAFE_HETEROGENEOUS[]
    _UNSAFE_HETEROGENEOUS[] = true
    try
        _record_unsafe_heterogeneous!()
        @warn "unsafe: heterogeneous cluster (Julia, packages, and environment files may differ across workers)"
        return f()
    finally
        _UNSAFE_HETEROGENEOUS[] = old
    end
end

function unsafe_heterogeneous_argv(enabled::Bool)::Vector{String}
    enabled || return String[]
    return String["--unsafe-heterogeneous"]
end

function _record_unsafe_heterogeneous!()
    return _note_provenance_unsafe!("heterogeneous")
end

function _located_project_file_for_identity(project::AbstractString)::String
    pf = DistSSHBase._located_project_file(project)
    pf isa String || return ""
    return String(pf)
end

function _env_file_shas(project::AbstractString)::Tuple{String, String, String, String}
    man = _existing_project_manifest(project)
    pf = _located_project_file_for_identity(project)
    man_sha = ""
    proj_sha = ""
    if !isempty(man) && isfile(man)
        man_sha = DistSSHBase.file_sha256(man)
    end
    if !isempty(pf) && isfile(pf)
        proj_sha = DistSSHBase.file_sha256(pf)
    end
    return man, man_sha, pf, proj_sha
end

"""Manifest format 1 stores `deps.Name` as a table; format 2 as an array of tables."""
function _manifest_dep_table(entry)
    entry isa AbstractDict && return entry
    if entry isa AbstractVector && !isempty(entry)
        first_entry = first(entry)
        first_entry isa AbstractDict && return first_entry
    end
    return nothing
end

function _distssh_versions_from_parsed(raw)::Dict{String, String}
    out = Dict{String, String}()
    raw isa AbstractDict || return out
    deps = get(raw, "deps", nothing)
    deps isa AbstractDict || return out
    for name in ("DistSSHRun", "DistSSHKit", "DistSSHQueue", "DistSSHBase")
        tab = _manifest_dep_table(get(deps, name, nothing))
        tab === nothing && continue
        v = get(tab, "version", nothing)
        v isa AbstractString && (out[name] = String(v))
    end
    return out
end

function _distssh_versions_from_manifest(path::AbstractString)::Dict{String, String}
    isfile(path) || return Dict{String, String}()
    raw = try
        TOML.parsefile(String(path))
    catch
        return Dict{String, String}()
    end
    return _distssh_versions_from_parsed(raw)
end

function _existing_project_manifest(project::AbstractString)::String
    mp = DistSSHBase.manifest_path(project)
    mp === nothing && return ""
    return String(mp)
end

"""
    run_identity(project::AbstractString) -> Dict{String,String}

This process, plus resolved Manifest and Project file paths and SHA-256 digests
(same definition as the deploy record: raw file bytes, lowercase hex).

Reads the project tree. Does not activate it, write the depot, set environment
variables, or SSH.
"""
function run_identity(project::AbstractString)::Dict{String, String}
    proj = canonical_local_path(project)
    man, man_sha, pf, proj_sha = _env_file_shas(proj)
    ident = Dict{String, String}(
        "version" => string(VERSION),
        "commit" => string(Base.GIT_VERSION_INFO.commit),
        "julia" => joinpath(Sys.BINDIR, "julia"),
        "manifest" => man,
        "manifest.sha256" => man_sha,
        "project" => pf,
        "project.sha256" => proj_sha,
    )
    for (k, v) in _distssh_versions_from_manifest(man)
        ident["pkg." * k] = v
    end
    return ident
end
public run_identity

const _WORKER_PKG_UUID_TOML = Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76")
const _WORKER_PKG_UUID_SHA = Base.UUID("ea8e919c-243c-51af-8825-aaa63cd721ce")

function _worker_production_identity_expr()
    return quote
        let man = "", man_sha = "", pf = "", proj_sha = ""
            sha_mod = try
                Base.require(Base.PkgId($(_WORKER_PKG_UUID_SHA), "SHA"))
                Base.loaded_modules[Base.PkgId($(_WORKER_PKG_UUID_SHA), "SHA")]
            catch
                nothing
            end
            function __env_sha256(path)
                isfile(path) || return ""
                sha_mod === nothing && return ""
                try
                    return lowercase(sha_mod.bytes2hex(sha_mod.sha256(read(path))))
                catch
                    return ""
                end
            end
            proj0 = Base.active_project()
            if proj0 !== nothing
                pf = String(proj0)
                man0 = try
                    Base.project_file_manifest_path(pf)
                catch
                    nothing
                end
                if man0 isa AbstractString && isfile(man0)
                    man = String(man0)
                    man_sha = __env_sha256(man)
                end
                proj_sha = __env_sha256(pf)
            end
            d = Dict{String, String}(
                "version" => string(VERSION),
                "commit" => string(Base.GIT_VERSION_INFO.commit),
                "julia" => joinpath(Sys.BINDIR, "julia"),
                "manifest" => man,
                "manifest.sha256" => man_sha,
                "project" => pf,
                "project.sha256" => proj_sha,
            )
            if !isempty(man) && isfile(man)
                raw = try
                    Base.require(Base.PkgId($(_WORKER_PKG_UUID_TOML), "TOML"))
                    toml = Base.loaded_modules[Base.PkgId($(_WORKER_PKG_UUID_TOML), "TOML")]
                    toml.parsefile(man)
                catch
                    nothing
                end
                if raw isa AbstractDict
                    deps = get(raw, "deps", nothing)
                    if deps isa AbstractDict
                        for name in ("DistSSHRun", "DistSSHKit", "DistSSHQueue", "DistSSHBase")
                            entry = get(deps, name, nothing)
                            tab = if entry isa AbstractDict
                                entry
                            elseif entry isa AbstractVector && !isempty(entry) &&
                                    first(entry) isa AbstractDict
                                first(entry)
                            else
                                nothing
                            end
                            tab === nothing && continue
                            v = get(tab, "version", nothing)
                            v isa AbstractString && (d["pkg." * name] = String(v))
                        end
                    end
                end
            end
            d
        end
    end
end

"""Base-only snapshot on a worker (no DistSSHRun module on the worker)."""
function _worker_identity_expr()
    production = _worker_production_identity_expr()
    return quote
        if strip(get(ENV, "DISTSSH_TEST", "")) == "1"
            let kind = strip(get(ENV, "DISTSSH_TEST_WORKER_SNAP", ""))
                if kind == "non_dict"
                    42
                else
                    raw = strip(get(ENV, "DISTSSH_TEST_WORKER_IDENTITY_TOML", ""))
                    if isempty(raw)
                        $production
                    else
                        let parsed = try
                                toml = Base.require(
                                    Base.PkgId($(_WORKER_PKG_UUID_TOML), "TOML"),
                                )
                                toml.parse(raw)
                            catch
                                raw
                            end
                            if !(parsed isa AbstractDict)
                                parsed
                            else
                                let d = Dict{String, String}()
                                    for (k, v) in parsed
                                        d[String(k)] = string(v)
                                    end
                                    d
                                end
                            end
                        end
                    end
                end
            end
        else
            $production
        end
    end
end

"""
    identity_mismatches(parent, other; unsafe_heterogeneous=false) -> Vector{String}

Same lines as [`go!`](@ref), [`ride!`](@ref), and [`drive!`](@ref). An empty
vector matches. This does not throw, print, or read `DISTSSH_QUIET`.

When `unsafe_heterogeneous` is false, compares Julia version and commit,
DistSSH* Manifest version strings, and **byte-exact** SHA-256 digests of the
resolved Manifest and Project files (`manifest.sha256`, `project.sha256`).
CRLF and other byte differences count.

A `pkg.*` key is compared only when `parent` has it and `other` has a
non-empty value. Keys that exist only on `other` are ignored. When the parent
has a non-empty `manifest.sha256`, the worker must supply the same digest or
the check fails; an empty worker snapshot is a mismatch. `"julia"` binary path
is not compared.
"""
function identity_mismatches(
        parent::AbstractDict,
        other::AbstractDict;
        unsafe_heterogeneous::Bool = false,
    )::Vector{String}
    unsafe_heterogeneous && return String[]
    lines = String[]
    pv = get(parent, "version", "")
    wv = get(other, "version", "")
    pv == wv || push!(lines, "julia version parent=$(pv) worker=$(wv)")
    pc = get(parent, "commit", "")
    wc = get(other, "commit", "")
    pc == wc || push!(lines, "julia commit parent=$(pc) worker=$(wc)")
    for (k, pval) in parent
        startswith(k, "pkg.") || continue
        wv = get(other, k, "")
        isempty(wv) && continue
        pval == wv || push!(lines, "$(k) parent=$(pval) worker=$(wv)")
    end
    want_man = get(parent, "manifest.sha256", "")
    want_proj = get(parent, "project.sha256", "")
    if !isempty(want_man)
        got_man = get(other, "manifest.sha256", "")
        if isempty(got_man)
            push!(
                lines,
                "manifest.sha256 missing on worker (parent=$(want_man[1:min(end, 12)])…)",
            )
        elseif want_man != got_man
            push!(
                lines,
                "manifest.sha256 parent=$(want_man) worker=$(got_man)",
            )
        end
    end
    if !isempty(want_proj)
        got_proj = get(other, "project.sha256", "")
        if isempty(got_proj)
            push!(
                lines,
                "project.sha256 missing on worker (parent=$(want_proj[1:min(end, 12)])…)",
            )
        elseif want_proj != got_proj
            push!(
                lines,
                "project.sha256 parent=$(want_proj) worker=$(got_proj)",
            )
        end
    end
    return lines
end
public identity_mismatches

function _worker_placement(pid::Integer)::Tuple{String, Int}
    for (host, ids) in DistSSHRun.DRIVE_HOST_WORKER_IDS
        for (i, p) in enumerate(ids)
            Int(p) == Int(pid) && return (String(host), i)
        end
    end
    return (DistSSHRun._leftover_worker_host(pid), 0)
end

function _format_worker_mismatch_line(pid::Integer, detail::AbstractString)::String
    host, rank = _worker_placement(pid)
    rank_s = rank > 0 ? string(rank) : "?"
    return "host=$(host) rank=$(rank_s) pid=$(pid): $(String(detail))"
end

function _environment_mismatch_throw(lines::Vector{String})
    isempty(lines) && return nothing
    throw(
        ErrorException(
            "environment mismatch between controller (master) and worker(s):\n  " *
                join(lines, "\n  ") *
                "\nwhy: every worker must resolve the same Project and Manifest file bytes as the controller (master) before work runs (CRLF and other byte differences count).\n" *
                "fix: run setup so each host deploys the same tree as the controller (master), or pass --unsafe-heterogeneous to allow a mixed cluster.",
        ),
    )
end

"""Worker snapshot for environment verification (`Core.eval` on the worker)."""
function _fetch_worker_environment_snapshot(pid::Integer)
    return remotecall_fetch(Core.eval, pid, Main, _worker_identity_expr())
end

function verify_workers_match_job!(
        project::AbstractString;
        host_manifests = nothing,
    )
    unsafe_heterogeneous_active() && return nothing
    parent = run_identity(project)
    want_man = get(parent, "manifest.sha256", "")
    isempty(want_man) && return nothing
    owned_live = Set(_live_owned_worker_ids())
    worker_ids = if host_manifests isa AbstractDict && !isempty(host_manifests)
        # Per-worker manifest paths from drive (local vs remote); comparison uses SHA digests only.
        sort!(Int[w for w in keys(host_manifests) if Int(w) ∈ owned_live])
    else
        _live_owned_worker_ids()
    end
    mismatches = String[]
    mismatch_lock = ReentrantLock()
    @sync for w in worker_ids
        @async begin
            snap = _fetch_worker_environment_snapshot(w)
            local lines = String[]
            if !(snap isa AbstractDict)
                push!(
                    lines,
                    _format_worker_mismatch_line(
                        w,
                        "worker environment snapshot was not available",
                    ),
                )
            else
                worker = Dict{String, String}(String(k) => string(v) for (k, v) in snap)
                for line in identity_mismatches(parent, worker)
                    push!(lines, _format_worker_mismatch_line(w, line))
                end
            end
            isempty(lines) ||
                lock(mismatch_lock) do
                append!(mismatches, lines)
            end
        end
    end
    return _environment_mismatch_throw(mismatches)
end

function _julia_version_commit_from_output(out::AbstractString)::Tuple{String, String}
    lines = split(strip(out), '\n'; keepempty = false)
    v = isempty(lines) ? "" : String(lines[1])
    c = length(lines) >= 2 ? String(lines[2]) : ""
    return v, c
end

function _parse_identity_kv_lines(out::AbstractString)::Dict{String, String}
    d = Dict{String, String}()
    for line in split(strip(out), '\n'; keepempty = false)
        s = strip(String(line))
        isempty(s) && continue
        startswith(s, "#") && continue
        eq = findfirst('=', s)
        eq === nothing && continue
        k = strip(s[1:(eq - 1)])
        v = strip(s[(eq + 1):end])
        isempty(k) || (d[k] = v)
    end
    return d
end

const _PROJECT_IDENTITY_EVAL = raw"""
using SHA
function env_sha256(path)
    isfile(path) || return ""
    return lowercase(bytes2hex(sha256(read(path))))
end
proj = Base.active_project()
man = ""
man_sha = ""
pf = ""
proj_sha = ""
if proj !== nothing
    pf = String(proj)
    man0 = try
        Base.project_file_manifest_path(pf)
    catch
        nothing
    end
    if man0 isa AbstractString && isfile(man0)
        man = String(man0)
        man_sha = env_sha256(man)
    end
    proj_sha = env_sha256(pf)
end
print("version=", string(VERSION), '\n')
print("commit=", string(Base.GIT_VERSION_INFO.commit), '\n')
print("manifest=", man, '\n')
print("manifest.sha256=", man_sha, '\n')
print("project=", pf, '\n')
print("project.sha256=", proj_sha, '\n')
if !isempty(man) && isfile(man)
    pkg = Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
    toml = Base.loaded_modules[Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML")]
    raw = toml.parsefile(man)
    if raw isa AbstractDict
        deps = get(raw, "deps", nothing)
        if deps isa AbstractDict
            for name in ("DistSSHRun", "DistSSHKit", "DistSSHQueue", "DistSSHBase")
                entry = get(deps, name, nothing)
                tab = if entry isa AbstractDict
                    entry
                elseif entry isa AbstractVector && !isempty(entry) && first(entry) isa AbstractDict
                    first(entry)
                else
                    nothing
                end
                tab === nothing && continue
                v = get(tab, "version", nothing)
                v isa AbstractString && print("pkg.", name, '=', String(v), '\n')
            end
        end
    end
end
"""

function _go_local_slot_identity(project::AbstractString, julia)::Dict{String, String}
    parent = run_identity(project)
    spec = julia isa AbstractString ? String(julia) : nothing
    bin = pin_local_julia(spec)
    v, c = try
        _local_julia_version_commit(bin)
    catch
        ("", "")
    end
    local_id = Dict{String, String}(
        "version" => v,
        "commit" => c,
        "julia" => bin,
        "manifest" => get(parent, "manifest", ""),
        "manifest.sha256" => get(parent, "manifest.sha256", ""),
        "project" => get(parent, "project", ""),
        "project.sha256" => get(parent, "project.sha256", ""),
    )
    for (k, val) in parent
        startswith(k, "pkg.") || continue
        local_id[k] = val
    end
    return local_id
end

function _local_julia_version_commit(bin::AbstractString)::Tuple{String, String}
    out = strip(
        read(
            Cmd(String[String(bin), "--startup-file=no", "-e", _JULIA_VERSION_COMMIT_EVAL]),
            String,
        ),
    )
    return _julia_version_commit_from_output(out)
end

const _JULIA_VERSION_COMMIT_EVAL =
    "print(string(VERSION), '\\n', string(Base.GIT_VERSION_INFO.commit))"

function _go_remote_run_identity(
        host::AbstractString,
        remote_project::AbstractString,
        julia,
    )::Dict{String, String}
    h = String(host)
    # Remote `--project=` must expand on the worker host (`~`, relative paths).
    rp = String(strip(remote_project))
    spec = julia isa AbstractString ? String(julia) : nothing
    pinned = pin_remote_julia(h, spec)
    pinned === nothing && throw(ArgumentError("Julia not found on remote host $(h)"))
    pq = _remote_julia_path_sh(pinned)
    pr = _remote_shell_path_word(rp)
    inner = string(
        "JULIA_LOAD_PATH=",
        posix_quote(_LAUNCH_LOAD_PATH),
        " ",
        pq,
        " --startup-file=no --project=",
        pr,
        " -e ",
        posix_quote(_PROJECT_IDENTITY_EVAL),
    )
    code, out = _remote_shell_status(h, inner)
    ident = Dict{String, String}(
        "julia" => pinned,
        "version" => "",
        "commit" => "",
        "manifest" => "",
        "manifest.sha256" => "",
        "project" => "",
        "project.sha256" => "",
    )
    code == 0 || return ident
    parsed = _parse_identity_kv_lines(out)
    for (k, v) in parsed
        ident[k] = v
    end
    return ident
end

function _remote_project_for_go(host::AbstractString, remote_root::AbstractString, project::AbstractString)::String
    rr = String(strip(remote_root))
    # `go!` passes the remote work root (`runs/<id>/src`); use it for `--project=`.
    !isempty(rr) && return rr
    proj = canonical_local_path(project)
    resolved = resolve_host_path_abs(String(host), proj, proj)
    resolved isa AbstractString && !isempty(resolved) && return String(resolved)
    return rr
end

"""Compare go slot Julia / environment to the job tree (not Distributed workers)."""
function verify_go_slots_match_job!(
        project::AbstractString,
        slots;
        remote_root::AbstractString = "",
        julia = nothing,
    )
    unsafe_heterogeneous_active() && return nothing
    parent = run_identity(project)
    want_man = get(parent, "manifest.sha256", "")
    isempty(want_man) && return nothing
    mismatches = String[]
    if any(s -> s.kind === :parent, slots)
        local_id = _go_local_slot_identity(project, julia)
        for line in identity_mismatches(parent, local_id)
            push!(mismatches, "parent slot: $(line)")
        end
    end
    seen = Set{String}()
    for s in slots
        s.kind === :child || continue
        h = s.host
        h isa AbstractString || continue
        hs = String(h)
        hs in seen && continue
        push!(seen, hs)
        remote_proj = _remote_project_for_go(hs, remote_root, project)
        worker = _go_remote_run_identity(hs, remote_proj, julia)
        for line in identity_mismatches(parent, worker)
            push!(mismatches, "host $(hs): $(line)")
        end
    end
    return _environment_mismatch_throw(mismatches)
end
