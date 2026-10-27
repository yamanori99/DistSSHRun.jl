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

function _distssh_versions_from_manifest(path::AbstractString)::Dict{String, String}
    out = Dict{String, String}()
    isfile(path) || return out
    raw = try
        TOML.parsefile(String(path))
    catch
        return out
    end
    raw isa AbstractDict || return out
    deps = get(raw, "deps", nothing)
    deps isa AbstractDict || return out
    for name in ("DistSSHRun", "DistSSHKit", "DistSSHQueue", "DistSSHBase")
        entry = get(deps, name, nothing)
        entry isa AbstractDict || continue
        v = get(entry, "version", nothing)
        v isa AbstractString && (out[name] = String(v))
    end
    return out
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

function parent_run_identity(project::AbstractString)::Dict{String, String}
    proj = canonical_local_path(project)
    man = ""
    for name in ("Manifest.toml", "JuliaManifest.toml")
        p = joinpath(proj, name)
        if isfile(p)
            man = p
            break
        end
    end
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
                d = dirname(String(proj))
                for name in ("Manifest.toml", "JuliaManifest.toml")
                    p = joinpath(d, name)
                    if isfile(p)
                        man = p
                        break
                    end
                end
                isempty(man) && (man = joinpath(d, "Manifest.toml"))
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
                    toml = Base.loaded_modules[Base.PkgId(
                        Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"),
                        "TOML",
                    )]
                    toml.parsefile(man)
                catch
                    nothing
                end
                if raw isa AbstractDict
                    deps = get(raw, "deps", nothing)
                    if deps isa AbstractDict
                        for name in ("DistSSHRun", "DistSSHKit", "DistSSHQueue", "DistSSHBase")
                            entry = get(deps, name, nothing)
                            entry isa AbstractDict || continue
                            v = get(entry, "version", nothing)
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
        if !isempty(want) && !isempty(got)
            dirname(want) == dirname(got) ||
                push!(lines, "manifest path parent=$(want) worker=$(got)")
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
