# Loaded DistSSH* runtime identity (`loaded.*` keys). Not public API.

const _DISTSSH_RUNTIME_SPECS = (
    ("DistSSHBase", Base.UUID("f0a69307-14e5-4272-8c28-20680d05bac8")),
    ("DistSSHRun", Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000")),
    ("DistSSHKit", Base.UUID("ceec0504-c968-4be5-b215-667cae0e8f81")),
    ("DistSSHQueue", Base.UUID("24254401-70d8-4a51-8ea4-cfab19f5bc73")),
)
const _DISTSSH_RUNTIME_NAME_SET = Set(String[n for (n, _) in _DISTSSH_RUNTIME_SPECS])

const _WORKER_EVAL_PKG_UUID_TAR = Base.UUID("a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e")

function _distssh_queue_runtime_host()::Bool
    for (pkg, _) in Base.loaded_modules
        pkg.name == "DistSSHQueue" && return true
    end
    return false
end

function _runtime_has_loaded_name(d::AbstractDict, name::AbstractString)::Bool
    prefix = "loaded." * String(name) * "."
    for k in keys(d)
        startswith(String(k), prefix) && return true
    end
    return false
end

function _runtime_required_distssh_names(
        parent::AbstractDict,
        other::AbstractDict,
    )::Vector{String}
    req = String["DistSSHBase", "DistSSHRun"]
    if _distssh_queue_runtime_host() ||
            _runtime_has_loaded_name(parent, "DistSSHQueue") ||
            _runtime_has_loaded_name(other, "DistSSHQueue")
        push!(req, "DistSSHQueue")
    end
    return req
end

function _runtime_distssh_uuid(name::AbstractString)::Base.UUID
    n = String(name)
    for (spec_name, uuid) in _DISTSSH_RUNTIME_SPECS
        spec_name == n && return uuid
    end
    throw(ArgumentError("unknown DistSSH runtime package name: $n"))
end

function _runtime_module_tree!(mod::Module)::String
    root = pkgdir(mod)
    root === nothing && throw(
        ErrorException("cannot compute package tree hash: pkgdir($(Base.PkgId(mod)))"),
    )
    tar_mod = DistSSHBase.tool_require(
        Base.PkgId(_WORKER_EVAL_PKG_UUID_TAR, "Tar"),
    )
    tar_create = Base.invokelatest(getproperty, tar_mod, :create)
    tar_tree_hash = Base.invokelatest(getproperty, tar_mod, :tree_hash)
    tar_path = tempname() * ".tar"
    try
        Base.invokelatest(tar_create, String(root), tar_path)
        h = Base.invokelatest(
            tar_tree_hash,
            tar_path;
            algorithm = "git-sha1",
            skip_empty = true,
        )
        s = lowercase(string(h))
        length(s) == 40 || throw(
            ErrorException(
                "package tree hash for $(Base.PkgId(mod)) is not a 40-digit git-sha1 value",
            ),
        )
        return s
    finally
        isfile(tar_path) && rm(tar_path)
    end
end

function _runtime_distssh_loaded_fields(mod::Module, name::AbstractString)::Dict{String, String}
    tree = _runtime_module_tree!(mod)
    return Dict{String, String}(
        "loaded.$name.version" => string(pkgversion(mod)),
        "loaded.$name.uuid" => string(Base.PkgId(mod).uuid),
        "loaded.$name.tree" => tree,
    )
end

function _runtime_module_for_distssh(name::AbstractString)::Module
    pkgid = Base.PkgId(_runtime_distssh_uuid(name), String(name))
    haskey(Base.loaded_modules, pkgid) && return Base.loaded_modules[pkgid]
    return DistSSHBase.tool_require(pkgid)
end

"""Controller snapshot of loaded DistSSH* packages (this Julia process)."""
function _runtime_distssh_snapshot()::Dict{String, String}
    out = Dict{String, String}()
    empty_parent = Dict{String, String}()
    req = _runtime_required_distssh_names(empty_parent, empty_parent)
    req_set = Set(req)
    for (name, _) in _DISTSSH_RUNTIME_SPECS
        name in req_set && continue
        pkgid = Base.PkgId(_runtime_distssh_uuid(name), name)
        haskey(Base.loaded_modules, pkgid) || continue
        merge!(out, _runtime_distssh_loaded_fields(Base.loaded_modules[pkgid], name))
    end
    for name in req
        merge!(out, _runtime_distssh_loaded_fields(_runtime_module_for_distssh(name), name))
    end
    return out
end

function _identity_loaded_distssh_mismatches(
        parent::AbstractDict,
        other::AbstractDict,
    )::Vector{String}
    names = Set{String}()
    for d in (parent, other)
        for k in keys(d)
            ks = String(k)
            startswith(ks, "loaded.") || continue
            parts = split(ks, '.')
            length(parts) >= 3 || continue
            push!(names, parts[2])
        end
    end
    for n in _runtime_required_distssh_names(parent, other)
        push!(names, n)
    end
    lines = String[]
    for name in sort!(collect(names))
        name in _DISTSSH_RUNTIME_NAME_SET || continue
        for field in ("version", "uuid", "tree")
            key = "loaded.$name.$field"
            pv = strip(get(parent, key, ""))
            wv = strip(get(other, key, ""))
            if isempty(pv)
                push!(lines, "$(key) missing on the controller")
            elseif isempty(wv)
                push!(lines, "$(key) missing on the worker")
            elseif pv != wv
                push!(lines, "$(key) parent=$(pv) worker=$(wv)")
            end
        end
    end
    return lines
end

function _controller_runtime_loaded_error(missing_key::AbstractString)::String
    return join(
        [
            "what: loaded DistSSH runtime identity is incomplete on the controller",
            "where: host=$(gethostname()); missing=$(missing_key)",
            "why: worker environment verification requires DistSSHBase and DistSSHRun (and DistSSHQueue on a queue host) with version, uuid, and tree hash",
            "fix: run DistSSH from a single Kit/Run install and align depots on every host",
            "note: --unsafe-heterogeneous does not waive loaded DistSSH* checks",
        ],
        "\n",
    )
end

function assert_controller_runtime_distssh_loaded!()
    snap = _runtime_distssh_snapshot()
    req = _runtime_required_distssh_names(snap, snap)
    for name in req
        for field in ("version", "uuid", "tree")
            key = "loaded.$name.$field"
            isempty(strip(get(snap, key, ""))) &&
                throw(ErrorException(_controller_runtime_loaded_error(key)))
        end
    end
    return nothing
end

function _tool_require_eval_preamble()::String
    return raw"""
    function tool_require(pkg)
        for (loaded, _) in Base.loaded_modules
            if loaded.name == pkg.name && loaded.uuid != pkg.uuid
                error("tool_require: package name collision for ", pkg.name)
            end
        end
        if haskey(Base.loaded_modules, pkg)
            return Base.loaded_modules[pkg]
        end
        return Base.require(pkg)
    end
    function __distssh_pkg_tree(mod)
        root = pkgdir(mod)
        root === nothing && error("pkgdir unavailable")
    tar_mod = tool_require(Base.PkgId(Base.UUID("a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"), "Tar"))
    tar_create = Base.invokelatest(getproperty, tar_mod, :create)
    tar_tree_hash = Base.invokelatest(getproperty, tar_mod, :tree_hash)
    tar_path = tempname() * ".tar"
    try
        Base.invokelatest(tar_create, String(root), tar_path)
        h = Base.invokelatest(
            tar_tree_hash,
            tar_path;
            algorithm = "git-sha1",
            skip_empty = true,
        )
            s = lowercase(string(h))
            length(s) == 40 || error("package tree hash is not 40 hex chars")
            return s
        finally
            isfile(tar_path) && rm(tar_path)
        end
    end
    function __merge_loaded_distssh!(d, require_queue)
        specs = [
            ("DistSSHBase", Base.UUID("f0a69307-14e5-4272-8c28-20680d05bac8")),
            ("DistSSHRun", Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000")),
            ("DistSSHKit", Base.UUID("ceec0504-c968-4be5-b215-667cae0e8f81")),
            ("DistSSHQueue", Base.UUID("24254401-70d8-4a51-8ea4-cfab19f5bc73")),
        ]
        required = ["DistSSHBase", "DistSSHRun"]
        if require_queue
            push!(required, "DistSSHQueue")
        end
        req_set = Set(required)
        function record!(mod, name)
            pkg = Base.PkgId(mod)
            d["loaded." * name * ".version"] = string(pkgversion(mod))
            d["loaded." * name * ".uuid"] = string(pkg.uuid)
            d["loaded." * name * ".tree"] = __distssh_pkg_tree(mod)
        end
        for (name, uuid) in specs
            name in req_set && continue
            pkgid = Base.PkgId(uuid, name)
            haskey(Base.loaded_modules, pkgid) || continue
            record!(Base.loaded_modules[pkgid], name)
        end
        for name in required
            uuid = nothing
            for (n, u) in specs
                n == name && (uuid = u)
            end
            uuid === nothing && error("unknown required DistSSH name")
            mod = tool_require(Base.PkgId(uuid, name))
            record!(mod, name)
        end
        return d
    end
    """
end

"""One-shot Julia identity probes: avoid job-triggered precompile in the subprocess."""
function _identity_probe_exeflag_strings(
        project::AbstractString;
        local_cpu::Bool,
    )::Vector{String}
    return vcat(
        worker_exeflag_strings(project; local_cpu = local_cpu),
        String["--compiled-modules=no"],
    )
end

function _identity_probe_env_pairs(
        project::AbstractString;
        ssh::Bool,
    )::Dict{String, String}
    env = Dict{String, String}(
        String(k) => String(v) for (k, v) in worker_env_pairs(project; ssh = ssh)
    )
    env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    return env
end

function _worker_shell_env_prefix(project::AbstractString; ssh::Bool)::String
    parts = String[]
    for k in _LAUNCH_UNSET_ENV
        push!(parts, "-u", String(k))
    end
    push!(parts, "-u", "JULIA_LOAD_PATH")
    for p in worker_env_pairs(project; ssh = ssh)
        push!(parts, "$(first(p))=$(posix_quote(last(p)))")
    end
    return "env " * join(parts, " ")
end

function _identity_probe_shell_env_prefix(project::AbstractString; ssh::Bool)::String
    parts = String[]
    for k in _LAUNCH_UNSET_ENV
        push!(parts, "-u", String(k))
    end
    push!(parts, "-u", "JULIA_LOAD_PATH")
    for (k, v) in _identity_probe_env_pairs(project; ssh = ssh)
        push!(parts, "$(k)=$(posix_quote(v))")
    end
    return "env " * join(parts, " ")
end

function _identity_eval_dict_source(require_queue::Bool)::String
    return string(
        _tool_require_eval_preamble(),
        """
        function __env_sha256_bytes(path, sha_mod)
            isfile(path) || return ""
            digest = Base.invokelatest(sha_mod.sha256, read(path))
            return lowercase(Base.invokelatest(sha_mod.bytes2hex, digest))
        end
        d = let require_queue = $(require_queue)
            sha_mod = tool_require(Base.PkgId(Base.UUID("ea8e919c-243c-51af-8825-aaa63cd721ce"), "SHA"))
            toml_mod = tool_require(Base.PkgId(Base.UUID("fa267f1f-6049-4f14-aa54-33bafae1ed76"), "TOML"))
            man = ""
            man_sha = ""
            pf = ""
            proj_sha = ""
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
                    man_sha = __env_sha256_bytes(man, sha_mod)
                end
                proj_sha = __env_sha256_bytes(pf, sha_mod)
            end
            function __env_sysimage_path()
                img = unsafe_string(Base.JLOptions().image_file)
                try
                    return String(realpath(img))
                catch
                    return String(img)
                end
            end
            function __env_sysimage_is_default()
                ext = Sys.isapple() ? ".dylib" : Sys.iswindows() ? ".dll" : ".so"
                def = joinpath(Sys.BINDIR, "..", "lib", "julia", "sys" * ext)
                img = unsafe_string(Base.JLOptions().image_file)
                try
                    return realpath(img) == realpath(def)
                catch
                    return false
                end
            end
            d = Dict{String, String}(
                "version" => string(VERSION),
                "commit" => string(Base.GIT_VERSION_INFO.commit),
                "julia" => joinpath(Sys.BINDIR, "julia"),
                "sysimage" => __env_sysimage_path(),
                "sysimage.default" => string(__env_sysimage_is_default()),
                "manifest" => man,
                "manifest.sha256" => man_sha,
                "project" => pf,
                "project.sha256" => proj_sha,
            )
            if !isempty(man) && isfile(man)
                raw = try
                    Base.invokelatest(toml_mod.parsefile, man)
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
            __merge_loaded_distssh!(d, require_queue)
            d
        end
        """,
    )
end

function _identity_eval_print_source(require_queue::Bool)::String
    body = _identity_eval_dict_source(require_queue)
    return string(
        body,
        """
        for (k, v) in pairs(d)
            print(k, '=', v, '\\n')
        end
        """,
    )
end

function _worker_identity_expr(; require_queue::Bool = _distssh_queue_runtime_host())
    src = _identity_eval_dict_source(require_queue)
    return Meta.parseall(src; filename = "distssh-worker-identity")
end

function _probe_identity_dict(
        bin::AbstractString,
        project::AbstractString;
        ssh::Bool,
        require_queue::Bool,
    )::Dict{String, String}
    src = _identity_eval_print_source(require_queue)
    pf = canonical_local_path(project)
    env = _identity_probe_env_pairs(pf; ssh = ssh)
    flags = _identity_probe_exeflag_strings(pf; local_cpu = !ssh)
    cmd = setenv(Cmd(vcat([String(bin)], flags, ["-e", src])), env)
    out = read(cmd, String)
    return _parse_identity_kv_lines(out)
end
