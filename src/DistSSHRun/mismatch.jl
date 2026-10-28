# Worker identity vs the job tree. Default is error; `--allow-mismatch` waives fields.

const ALLOW_MISMATCH_FIELDS = (:julia, :distssh, :manifest)
const _ALLOW_MISMATCH = Ref{Vector{Symbol}}(Symbol[])

function with_allow_mismatch(f::Function, syms)
    old = copy(_ALLOW_MISMATCH[])
    _ALLOW_MISMATCH[] = Symbol[Symbol(s) for s in syms]
    try
        return f()
    finally
        _ALLOW_MISMATCH[] = old
    end
end

function parse_allow_mismatch(raw::AbstractString)::Vector{Symbol}
    out = Symbol[]
    for part in split(String(raw), ',')
        s = strip(part)
        isempty(s) && continue
        tok = Symbol(s)
        tok in ALLOW_MISMATCH_FIELDS || throw(
            ArgumentError(
                "unknown --allow-mismatch field $(repr(s)); expected julia, distssh, or manifest",
            ),
        )
        tok in out || push!(out, tok)
    end
    return out
end

function merge_allow_mismatch!(
        dest::Vector{Symbol},
        raw::AbstractString,
    )::Vector{Symbol}
    for tok in parse_allow_mismatch(raw)
        tok in dest || push!(dest, tok)
    end
    return dest
end

function allow_mismatch_argv(syms)::Vector{String}
    isempty(syms) && return String[]
    return String["--allow-mismatch", join((String(s) for s in syms), ",")]
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

function _active_manifest_path()::String
    proj = Base.active_project()
    proj === nothing && return ""
    d = dirname(String(proj))
    for name in ("Manifest.toml", "JuliaManifest.toml")
        p = joinpath(d, name)
        isfile(p) && return p
    end
    return joinpath(d, "Manifest.toml")
end

function _existing_project_manifest(project::AbstractString)::String
    d = canonical_local_path(project)
    pf = joinpath(d, "Project.toml")
    isfile(pf) || return ""
    man = try
        Base.project_file_manifest_path(String(pf))
    catch
        nothing
    end
    man isa AbstractString && isfile(man) && return String(man)
    return ""
end

function parent_run_identity(project::AbstractString)::Dict{String, String}
    proj = canonical_local_path(project)
    man = _existing_project_manifest(proj)
    ident = Dict{String, String}(
        "version" => string(VERSION),
        "commit" => string(Base.GIT_VERSION_INFO.commit),
        "julia" => joinpath(Sys.BINDIR, "julia"),
        "manifest" => man,
    )
    for (k, v) in _distssh_versions_from_manifest(man)
        ident["pkg." * k] = v
    end
    return ident
end

"""Base-only snapshot on a worker (no DistSSHRun)."""
function _worker_identity_expr()
    return quote
        let man = ""
            proj = Base.active_project()
            if proj !== nothing
                man0 = try
                    Base.project_file_manifest_path(String(proj))
                catch
                    nothing
                end
                if man0 isa AbstractString && isfile(man0)
                    man = String(man0)
                end
            end
            d = Dict{String, String}(
                "version" => string(VERSION),
                "commit" => string(Base.GIT_VERSION_INFO.commit),
                "julia" => joinpath(Sys.BINDIR, "julia"),
                "manifest" => man,
            )
            if !isempty(man) && isfile(man)
                raw = try
                    Base.require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
                    toml = Base.loaded_modules[
                        Base.PkgId(
                            Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"),
                            "TOML",
                        ),
                    ]
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

function _identity_mismatch_lines(
        parent::AbstractDict,
        worker::AbstractDict;
        allow::AbstractVector{Symbol} = Symbol[],
        shipped_manifest::AbstractString = "",
    )::Vector{String}
    lines = String[]
    if !(:julia in allow)
        pv = get(parent, "version", "")
        wv = get(worker, "version", "")
        pv == wv || push!(lines, "julia version parent=$(pv) worker=$(wv)")
        pc = get(parent, "commit", "")
        wc = get(worker, "commit", "")
        pc == wc || push!(lines, "julia commit parent=$(pc) worker=$(wc)")
    end
    if !(:distssh in allow)
        for (k, pv) in parent
            startswith(k, "pkg.") || continue
            wv = get(worker, k, "")
            isempty(wv) && continue
            pv == wv || push!(lines, "$(k) parent=$(pv) worker=$(wv)")
        end
    end
    if !(:manifest in allow)
        want = isempty(shipped_manifest) ? get(parent, "manifest", "") : String(shipped_manifest)
        got = get(worker, "manifest", "")
        if !isempty(want)
            if isempty(got)
                push!(lines, "manifest missing (expected $(want))")
            elseif want != got
                push!(lines, "manifest path parent=$(want) worker=$(got)")
            end
        end
    end
    return lines
end

function verify_workers_match_job!(
        project::AbstractString;
        allow::AbstractVector{Symbol} = Symbol[],
        host_manifests = nothing,
    )
    parent = parent_run_identity(project)
    mismatches = String[]
    for w in workers()
        snap = remotecall_fetch(Core.eval, w, Main, _worker_identity_expr())
        snap isa AbstractDict || continue
        worker = Dict{String, String}(String(k) => string(v) for (k, v) in snap)
        shipped = if host_manifests isa AbstractDict
            String(get(host_manifests, w, get(parent, "manifest", "")))
        else
            get(parent, "manifest", "")
        end
        for line in _identity_mismatch_lines(
                parent, worker;
                allow = allow, shipped_manifest = shipped,
            )
            push!(mismatches, "worker $(w): $(line)")
        end
    end
    isempty(mismatches) && return nothing
    throw(
        ErrorException(
            "worker mismatch (pass --allow-mismatch julia,distssh,manifest to waive):\n  " *
                join(mismatches, "\n  "),
        ),
    )
end

function _julia_version_commit_from_output(out::AbstractString)::Tuple{String, String}
    lines = split(strip(out), '\n'; keepempty = false)
    v = isempty(lines) ? "" : String(lines[1])
    c = length(lines) >= 2 ? String(lines[2]) : ""
    return v, c
end

const _JULIA_VERSION_COMMIT_EVAL =
    "print(string(VERSION), '\\n', string(Base.GIT_VERSION_INFO.commit))"

function _local_julia_version_commit(bin::AbstractString)::Tuple{String, String}
    out = strip(
        read(
            Cmd(String[String(bin), "--startup-file=no", "-e", _JULIA_VERSION_COMMIT_EVAL]),
            String,
        ),
    )
    return _julia_version_commit_from_output(out)
end

function _go_remote_run_identity(
        host::AbstractString,
        remote_root::AbstractString,
        julia,
    )::Dict{String, String}
    h = String(host)
    spec = julia isa AbstractString ? String(julia) : nothing
    pinned = pin_remote_julia(h, spec)
    pinned === nothing && throw(ArgumentError("Julia not found on remote host $(h)"))
    pq = _remote_julia_path_sh(pinned)
    inner = string(pq, " --startup-file=no -e ", posix_quote(_JULIA_VERSION_COMMIT_EVAL))
    code, out = _remote_shell_status(h, inner)
    ident = Dict{String, String}(
        "julia" => pinned,
        "version" => "",
        "commit" => "",
        "manifest" => "",
    )
    if code == 0
        v, c = _julia_version_commit_from_output(out)
        ident["version"] = v
        ident["commit"] = c
    end
    rr = String(remote_root)
    for name in Base.manifest_names
        p = joinpath(rr, name)
        c2, body = _remote_shell_status(h, string("cat ", _remote_shell_path_word(p)))
        c2 == 0 || continue
        isempty(strip(body)) && continue
        ident["manifest"] = p
        raw = try
            TOML.parse(body)
        catch
            nothing
        end
        for (k, v) in _distssh_versions_from_parsed(raw)
            ident["pkg." * k] = v
        end
        break
    end
    return ident
end

"""Compare go slot Julia / DistSSH* / Manifest to the job tree (not Distributed workers)."""
function verify_go_slots_match_job!(
        project::AbstractString,
        slots;
        remote_root::AbstractString = "",
        julia = nothing,
        allow::AbstractVector{Symbol} = Symbol[],
    )
    parent = parent_run_identity(project)
    mismatches = String[]
    if any(s -> s.kind === :parent, slots)
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
        )
        for (k, val) in parent
            startswith(k, "pkg.") || continue
            local_id[k] = val
        end
        shipped = get(parent, "manifest", "")
        for line in _identity_mismatch_lines(
                parent, local_id;
                allow = allow, shipped_manifest = shipped,
            )
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
        worker = _go_remote_run_identity(hs, remote_root, julia)
        local_man = get(parent, "manifest", "")
        shipped = if isempty(local_man) || isempty(String(remote_root))
            local_man
        else
            joinpath(String(remote_root), basename(local_man))
        end
        for line in _identity_mismatch_lines(
                parent, worker;
                allow = allow, shipped_manifest = shipped,
            )
            push!(mismatches, "host $(hs): $(line)")
        end
    end
    isempty(mismatches) && return nothing
    throw(
        ErrorException(
            "worker mismatch (pass --allow-mismatch julia,distssh,manifest to waive):\n  " *
                join(mismatches, "\n  "),
        ),
    )
end
