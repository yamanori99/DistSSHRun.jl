# Worker environment vs the job tree. `--unsafe-heterogeneous` waives package-environment checks only.

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
        _record_environment_unverified!("unsafe-heterogeneous")
        @warn "unsafe: heterogeneous package environment (Manifest/Project byte digests may differ; Julia build and DistSSH* versions must still match)"
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

const _ALLOW_MISMATCH_REMOVED =
    "removed; use --unsafe-heterogeneous (Julia/DistSSH* can no longer be waived)"

function _reject_removed_allow_mismatch!(allow_mismatch)
    allow_mismatch === nothing && return nothing
    throw(ArgumentError("allow_mismatch= was $(_ALLOW_MISMATCH_REMOVED)"))
end

function reject_removed_allow_mismatch_flag!(arg::AbstractString)
    arg == "--allow-mismatch" || return nothing
    throw(ArgumentError("--allow-mismatch was $(_ALLOW_MISMATCH_REMOVED)"))
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
                    # `require` may load SHA in this world age; call the new methods later.
                    digest = Base.invokelatest(sha_mod.sha256, read(path))
                    return lowercase(Base.invokelatest(sha_mod.bytes2hex, digest))
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
                    # Same world age as `require`: `parsefile` is not callable yet.
                    Base.invokelatest(toml.parsefile, man)
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
    return _worker_production_identity_expr()
end

const _WORKER_ENV_SNAPSHOT_OVERRIDE = Ref{Any}(nothing)

function _identity_julia_build_mismatches(
        parent::AbstractDict,
        other::AbstractDict,
    )::Vector{String}
    lines = String[]
    pv = get(parent, "version", "")
    wv = get(other, "version", "")
    pv == wv || push!(lines, "julia version parent=$(pv) worker=$(wv)")
    pc = strip(get(parent, "commit", ""))
    wc = strip(get(other, "commit", ""))
    commit_ok = !isempty(pc) && !isempty(wc) && pc == wc
    if !commit_ok
        if isempty(pc)
            push!(
                lines,
                "julia build: cannot determine the Julia build on the controller (commit missing)",
            )
        elseif isempty(wc)
            push!(
                lines,
                "julia build: cannot determine the Julia build on the worker (commit missing)",
            )
        else
            push!(lines, "julia commit parent=$(pc) worker=$(wc)")
        end
    end
    return lines
end

function _identity_pkg_mismatches(parent::AbstractDict, other::AbstractDict)::Vector{String}
    lines = String[]
    for (k, pval) in parent
        startswith(k, "pkg.") || continue
        wv = get(other, k, "")
        pval == wv || push!(lines, "$(k) parent=$(pval) worker=$(wv)")
    end
    return lines
end

function _identity_env_file_mismatches(parent::AbstractDict, other::AbstractDict)::Vector{String}
    lines = String[]
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

"""
    identity_mismatches(parent, other; unsafe_heterogeneous=false) -> Vector{String}

Same lines as [`go!`](@ref), [`ride!`](@ref), and [`drive!`](@ref). An empty
vector matches. This does not throw, print, or read `DISTSSH_QUIET`.

Julia version and commit (Julia build) and DistSSH* `pkg.*` versions from the
Manifest are always compared. An empty or missing commit on either side is a
mismatch. When `unsafe_heterogeneous` is true, only **byte-exact** SHA-256
digests of the resolved Manifest and Project files (`manifest.sha256`,
`project.sha256`) are waived; Julia build and `pkg.*` mismatches are still
reported. CRLF and other byte differences count for digests.

When the parent has a non-empty `manifest.sha256`, the worker must supply the
same digest or the check fails (unless `unsafe_heterogeneous`); an empty worker
snapshot is a mismatch. `"julia"` binary path is not compared.
"""
function identity_mismatches(
        parent::AbstractDict,
        other::AbstractDict;
        unsafe_heterogeneous::Bool = false,
    )::Vector{String}
    lines = String[]
    append!(lines, _identity_julia_build_mismatches(parent, other))
    append!(lines, _identity_pkg_mismatches(parent, other))
    unsafe_heterogeneous || append!(lines, _identity_env_file_mismatches(parent, other))
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

function _controller_project_display(project::AbstractString)::String
    proj = canonical_local_path(project)
    pf = _located_project_file_for_identity(project)
    if isempty(pf)
        return proj
    end
    return pf
end

function _controller_expected_manifest_line(project::AbstractString)::String
    mp = DistSSHBase.manifest_path(project)
    mp === nothing && return ""
    return String(mp)
end

function _controller_missing_manifest_issue(project::AbstractString)::String
    host = string(gethostname())
    proj_disp = _controller_project_display(project)
    pf = _located_project_file_for_identity(project)
    expected = _controller_expected_manifest_line(project)
    if isempty(pf)
        return "controller: active project has no Project.toml (host=$(host) project=$(proj_disp))"
    end
    exp_s = isempty(expected) ? "(none resolved by Base)" : expected
    return "controller: active project has no Manifest (host=$(host) project=$(proj_disp) expected=$(exp_s))"
end

function _controller_missing_manifest_error(project::AbstractString)::String
    host = string(gethostname())
    proj_disp = _controller_project_display(project)
    pf = _located_project_file_for_identity(project)
    q = _quoted_hint_path(dirname(isempty(pf) ? proj_disp : pf))
    expected = _controller_expected_manifest_line(project)
    exp_line = if isempty(pf)
        "where: controller host=$(host); active project path=$(proj_disp) (no Project.toml or JuliaProject.toml here)"
    else
        exp_s = isempty(expected) ? "(none resolved by Base)" : expected
        "where: controller host=$(host); active project=$(pf); expected manifest=$(exp_s)"
    end
    fix_line = if isempty(pf)
        "fix: (1) pass a directory or file that contains Project.toml (or JuliaProject.toml), (2) add a Manifest with `julia --project=$(q) -e 'using Pkg; Pkg.instantiate()'` and ship the same tree to every worker"
    else
        "fix: (1) `julia --project=$(q) -e 'using Pkg; Pkg.instantiate()'`, (2) deploy the same Manifest bytes to every worker with setup"
    end
    return join(
        [
            "what: active project has no Manifest digest for environment verification",
            exp_line,
            "why: workers may load different package versions when the controller Manifest is absent",
            fix_line,
            "override: pass --unsafe-heterogeneous to skip Manifest/Project digest verification (recorded as unverified; Julia build and DistSSH* versions must still match)",
        ],
        "\n",
    )
end

"""Fail before worker / remote launch when the controller has no Manifest (unless unsafe)."""
function assert_controller_manifest_for_environment_verify!(project::AbstractString)
    unsafe_heterogeneous_active() && return nothing
    parent = run_identity(project)
    want_man = get(parent, "manifest.sha256", "")
    !isempty(want_man) && return nothing
    throw(ErrorException(_controller_missing_manifest_error(project)))
end
public assert_controller_manifest_for_environment_verify!

function _environment_mismatch_throw(lines::Vector{String})
    isempty(lines) && return nothing
    throw(
        ErrorException(
            "environment mismatch between controller (master) and worker(s):\n  " *
                join(lines, "\n  ") *
                "\nwhy: every worker must match the controller (master) Julia build and DistSSH* versions; Manifest/Project byte digests must match unless you opt out.\n" *
                "fix: align Julia and DistSSH* versions on every host, deploy matching Manifest/Project bytes with setup, or pass --unsafe-heterogeneous to waive only Manifest/Project digest checks (unverified; Julia build and DistSSH* versions must still match).",
        ),
    )
end

function _collect_environment_mismatches(
        project::AbstractString,
        parent::AbstractDict,
        worker_lines::Vector{String};
        waive_env_issues::Bool = false,
    )::Vector{String}
    lines = String[]
    if !waive_env_issues
        want_man = get(parent, "manifest.sha256", "")
        isempty(want_man) && push!(lines, _controller_missing_manifest_issue(project))
    end
    append!(lines, worker_lines)
    return lines
end

"""Worker snapshot for environment verification (`Core.eval` on the worker)."""
function _fetch_worker_environment_snapshot(pid::Integer)
    override = _WORKER_ENV_SNAPSHOT_OVERRIDE[]
    if override isa Function
        return override(Int(pid))
    end
    return remotecall_fetch(Core.eval, pid, Main, _worker_identity_expr())
end

function _record_environment_verify_outcome!(waive_env::Bool)
    if waive_env
        _record_environment_unverified!("unsafe-heterogeneous")
    else
        _record_environment_verified!()
    end
    return nothing
end

function verify_workers_match_job!(project::AbstractString)
    waive_env = unsafe_heterogeneous_active()
    parent = run_identity(project)
    worker_ids = _live_owned_worker_ids()
    worker_lines = String[]
    mismatch_lock = ReentrantLock()
    @sync for w in worker_ids
        @async begin
            local lines = String[]
            try
                snap = _fetch_worker_environment_snapshot(w)
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
                    for line in identity_mismatches(parent, worker; unsafe_heterogeneous = waive_env)
                        push!(lines, _format_worker_mismatch_line(w, line))
                    end
                end
            catch e
                detail = first(split(sprint(showerror, e), '\n'))
                push!(
                    lines,
                    _format_worker_mismatch_line(w, "snapshot failed: $(detail)"),
                )
            end
            isempty(lines) ||
                lock(mismatch_lock) do
                append!(worker_lines, lines)
            end
        end
    end
    mismatches = _collect_environment_mismatches(
        project, parent, worker_lines; waive_env_issues = waive_env,
    )
    _environment_mismatch_throw(mismatches)
    _record_environment_verify_outcome!(waive_env)
    return nothing
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
using SHA, TOML
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
    raw = TOML.parsefile(man)
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

function _identity_probe_failure_message(
        host::AbstractString,
        code::Integer,
        err::AbstractString,
    )::String
    err_s = strip(String(err))
    detail = isempty(err_s) ? "" : "\n$(err_s)"
    return "identity probe failed on host $(host) (exit $(code))$(detail)"
end

function _described_identity_lines(
        parent::AbstractDict,
        other::AbstractDict,
        prefix::AbstractString;
        unsafe_heterogeneous::Bool,
    )::Vector{String}
    probe = strip(get(other, "probe_error", ""))
    if !isempty(probe)
        return String["$(prefix): $(probe)"]
    end
    return String[
        "$(prefix): $(line)"
            for line in identity_mismatches(parent, other; unsafe_heterogeneous)
    ]
end

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
    code, out, err = _remote_shell_status_parts(h, inner)
    ident = Dict{String, String}(
        "julia" => pinned,
        "version" => "",
        "commit" => "",
        "manifest" => "",
        "manifest.sha256" => "",
        "project" => "",
        "project.sha256" => "",
    )
    if code != 0
        ident["probe_error"] = _identity_probe_failure_message(h, code, err)
        return ident
    end
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
    waive_env = unsafe_heterogeneous_active()
    parent = run_identity(project)
    slot_lines = String[]
    if any(s -> s.kind === :parent, slots)
        local_id = _go_local_slot_identity(project, julia)
        for line in identity_mismatches(parent, local_id; unsafe_heterogeneous = waive_env)
            push!(slot_lines, "parent slot: $(line)")
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
        append!(
            slot_lines,
            _described_identity_lines(
                parent, worker, "host $(hs)"; unsafe_heterogeneous = waive_env,
            ),
        )
    end
    mismatches = _collect_environment_mismatches(
        project, parent, slot_lines; waive_env_issues = waive_env,
    )
    _environment_mismatch_throw(mismatches)
    _record_environment_verify_outcome!(waive_env)
    return nothing
end
