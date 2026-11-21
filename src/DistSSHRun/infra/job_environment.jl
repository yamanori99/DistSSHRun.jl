# Restrict LOAD_PATH to the job project, detect package collisions, gate instantiate.

const _JOB_LOAD_PATH = ("@", "@stdlib")

function restrict_job_load_path!()
    empty!(LOAD_PATH)
    for entry in _JOB_LOAD_PATH
        push!(LOAD_PATH, entry)
    end
    return nothing
end

function _manifest_dep_entry(raw_deps::AbstractDict, name::AbstractString)
    entry = get(raw_deps, name, nothing)
    entry isa AbstractDict && return entry
    if entry isa AbstractVector && !isempty(entry)
        first_entry = first(entry)
        first_entry isa AbstractDict && return first_entry
    end
    return nothing
end

function _parsed_manifest_deps(project::AbstractString)::Dict{String, Any}
    mp = DistSSHBase.manifest_path(project)
    man = mp isa String && isfile(mp) ? String(mp) : ""
    isempty(man) && return Dict{String, Any}()
    raw = try
        TOML.parsefile(man)
    catch
        return Dict{String, Any}()
    end
    raw isa AbstractDict || return Dict{String, Any}()
    deps = get(raw, "deps", nothing)
    deps isa AbstractDict || return Dict{String, Any}()
    return Dict{String, Any}(deps)
end

function _loaded_pkgid_by_name(name::AbstractString)::Union{Nothing, Base.PkgId}
    want = String(name)
    for (pkg, _) in Base.loaded_modules
        pkg.name == want && return pkg
    end
    return nothing
end

function _loaded_pkg_version(pkg::Base.PkgId)::String
    mod = get(Base.loaded_modules, pkg, nothing)
    mod === nothing && return ""
    v = try
        Base.pkgversion(mod)
    catch
        nothing
    end
    v === nothing && return ""
    return string(v)
end

function _uuid_string_from_manifest(tab::AbstractDict)::String
    u = get(tab, "uuid", nothing)
    u isa AbstractString && return lowercase(strip(String(u)))
    return ""
end

function _version_string_from_manifest(tab::AbstractDict)::String
    v = get(tab, "version", nothing)
    v isa AbstractString && return strip(String(v))
    return ""
end

function job_package_collision_details(project::AbstractString)::Vector{NTuple{5, String}}
    deps = _parsed_manifest_deps(project)
    isempty(deps) && return NTuple{5, String}[]
    out = NTuple{5, String}[]
    for name in sort!(collect(String, keys(deps)))
        tab = _manifest_dep_entry(deps, name)
        tab === nothing && continue
        loaded = _loaded_pkgid_by_name(name)
        loaded === nothing && continue
        man_uuid = _uuid_string_from_manifest(tab)
        man_ver = _version_string_from_manifest(tab)
        loaded_uuid = loaded.uuid === nothing ? "" : lowercase(string(loaded.uuid))
        loaded_ver = _loaded_pkg_version(loaded)
        if !isempty(man_uuid) && loaded.uuid !== nothing && loaded_uuid != man_uuid
            push!(out, (name, loaded_uuid, loaded_ver, man_uuid, man_ver))
            continue
        end
        if !isempty(man_ver) && !isempty(loaded_ver)
            lv = try
                VersionNumber(loaded_ver)
            catch
                nothing
            end
            mv = try
                VersionNumber(man_ver)
            catch
                nothing
            end
            if lv isa VersionNumber && mv isa VersionNumber && lv != mv
                push!(out, (name, loaded_uuid, loaded_ver, man_uuid, man_ver))
            end
        end
    end
    return out
end

"""Fail when a package already loaded in this process disagrees with the job Manifest."""
function assert_job_package_collisions!(
        project::AbstractString;
        site::AbstractString = "controller",
    )
    for (name, lu, lv, mu, mv) in job_package_collision_details(project; site = site)
        throw(
            ErrorException(
                job_package_collision_error(name, lu, lv, mu, mv, site),
            ),
        )
    end
    return nothing
end
public assert_job_package_collisions!

function find_deploy_record_file(project_dir::AbstractString)::Union{Nothing, String}
    walk = String(canonical_local_path(project_dir))
    while !isempty(walk)
        cand = joinpath(walk, ".distssh", "deploy.toml")
        isfile(cand) && return cand
        parent = dirname(walk)
        parent == walk && break
        walk = parent
    end
    return nothing
end

function assert_manifest_digest_matches_deploy_record!(project_dir::AbstractString)
    deploy_path = find_deploy_record_file(project_dir)
    deploy_path === nothing && return nothing
    rec = try
        TOML.parsefile(deploy_path)
    catch
        return nothing
    end
    want = get(rec, "manifest_hash", nothing)
    !(want isa AbstractString) || isempty(strip(want)) && return nothing
    want = lowercase(strip(String(want)))
    manifest = Base.active_manifest()
    if !(manifest isa AbstractString) || !isfile(manifest)
        throw(
            ErrorException(
                deploy_manifest_digest_mismatch_error("", want, deploy_path),
            ),
        )
    end
    got = lowercase(file_sha256(String(manifest)))
    got == want && return nothing
    throw(ErrorException(deploy_manifest_digest_mismatch_error(got, want, deploy_path)))
end
public assert_manifest_digest_matches_deploy_record!

function instantiate_job_manifest!(
        project_dir::AbstractString;
        instantiate::Function = project_dir -> begin
            pf = DistSSHBase._located_project_file(project_dir)
            pf isa String || throw(ArgumentError("no project file under $(project_dir)"))
            ctx = canonical_local_path(dirname(String(pf)))
            withenv() do
                Pkg.activate(ctx; io = devnull)
                Pkg.instantiate(;
                    manifest = true,
                    update_registry = false,
                    julia_version_strict = true,
                )
            end
            return nothing
        end,
    )
    assert_manifest_digest_matches_deploy_record!(project_dir)
    return instantiate(project_dir)
end
public instantiate_job_manifest!

"""
Julia source spliced into worker Main (no DistSSHRun bindings).
"""
function worker_package_collision_check_source()::String
    return """
    function _drive_worker_assert_no_package_collisions!()
        using TOML
        proj = Base.active_project()
        proj === nothing && return nothing
        man = try
            Base.project_file_manifest_path(String(proj))
        catch
            nothing
        end
        man isa AbstractString && isfile(man) || return nothing
        raw = try
            TOML.parsefile(man)
        catch
            return nothing
        end
        deps = get(raw, "deps", nothing)
        deps isa AbstractDict || return nothing
        function __dep_tab(entry)
            entry isa AbstractDict && return entry
            if entry isa AbstractVector && !isempty(entry)
                first_entry = first(entry)
                first_entry isa AbstractDict && return first_entry
            end
            return nothing
        end
        for (name, entry) in deps
            tab = __dep_tab(entry)
            tab === nothing && continue
            loaded = nothing
            for (pkg, _) in Base.loaded_modules
                pkg.name == String(name) || continue
                loaded = pkg
                break
            end
            loaded === nothing && continue
            man_uuid = get(tab, "uuid", nothing)
            man_uuid_s = man_uuid isa String ? lowercase(strip(man_uuid)) : ""
            loaded_uuid = loaded.uuid === nothing ? "" : lowercase(string(loaded.uuid))
            man_ver_s = get(tab, "version", nothing)
            man_ver_s = man_ver_s isa String ? strip(man_ver_s) : ""
            mod = get(Base.loaded_modules, loaded, nothing)
            loaded_ver = mod === nothing ? "" : try
                string(Base.pkgversion(mod))
            catch
                ""
            end
            if !isempty(man_uuid_s) && loaded.uuid !== nothing && loaded_uuid != man_uuid_s
                error(
                    "what: package " * String(name) *
                        " is already loaded with a different identity than the job Manifest\\n" *
                        "where: worker\\n" *
                        "why: packages loaded before the job environment can skew resolution\\n" *
                        "fix: start a fresh worker process for this job",
                )
            end
            if !isempty(man_ver_s) && !isempty(loaded_ver)
                lv = try
                    VersionNumber(loaded_ver)
                catch
                    nothing
                end
                mv = try
                    VersionNumber(man_ver_s)
                catch
                    nothing
                end
                if lv isa VersionNumber && mv isa VersionNumber && lv != mv
                    error(
                        "what: package " * String(name) *
                            " is already loaded with a different identity than the job Manifest\\n" *
                            "where: worker\\n" *
                            "why: packages loaded before the job environment can skew resolution\\n" *
                            "fix: start a fresh worker process for this job",
                    )
                end
            end
        end
        return nothing
    end
    """
end

function _worker_assert_job_package_collisions_expr()
    return Meta.parse("(using TOML; include_string(Main, $(repr(worker_package_collision_check_source()))); _drive_worker_assert_no_package_collisions!())")
end

"""Run collision check on a worker via `Core.eval` (no DistSSHRun on the worker)."""
function assert_worker_job_package_collisions!(pid::Integer)
    remotecall_fetch(Core.eval, pid, Main, _worker_assert_job_package_collisions_expr())
    return nothing
end

function _with_controller_job_verify!(project::AbstractString, f::Function)
    prev_active = Base.ACTIVE_PROJECT[]
    prev_lp = copy(LOAD_PATH)
    try
        pf = DistSSHBase._located_project_file(project)
        if pf isa String && !isempty(pf)
            Base.set_active_project(String(pf))
        end
        restrict_job_load_path!()
        return f()
    finally
        empty!(LOAD_PATH)
        append!(LOAD_PATH, prev_lp)
        Base.ACTIVE_PROJECT[] = prev_active
    end
end

function assert_controller_job_package_collisions!(project::AbstractString)
    return _with_controller_job_verify!(project, () -> begin
        assert_job_package_collisions!(project; site = "controller")
        return nothing
    end)
end
public assert_controller_job_package_collisions!

"""`julia -e` lines that compare Manifest bytes to deploy.toml before instantiate."""
function instantiate_remote_digest_gate_lines()::Vector{String}
    return String[
        "begin",
        "    local deploy_path = \"\"",
        "    local walk = project_dir",
        "    while !isempty(walk)",
        "        cand = joinpath(walk, \".distssh\", \"deploy.toml\")",
        "        if isfile(cand)",
        "            deploy_path = cand",
        "            break",
        "        end",
        "        parent = dirname(walk)",
        "        parent == walk && break",
        "        walk = parent",
        "    end",
        "    if !isempty(deploy_path)",
        "        rec = TOML.parsefile(deploy_path)",
        "        want = get(rec, \"manifest_hash\", nothing)",
        "        if want isa String && !isempty(want) && manifest isa String && isfile(manifest)",
        "            using SHA",
        "            got = lowercase(bytes2hex(sha256(read(manifest))))",
        "            got == want || error(",
        "                \"Manifest bytes do not match deploy record before instantiate (got \" *",
        "                got[1:min(end, 12)] * \"… != \" * want[1:min(end, 12)] * \"…). See help setup.\",",
        "            )",
        "        end",
        "    end",
        "end",
        "Pkg.instantiate(; manifest=true, update_registry=false, julia_version_strict=true)",
    ]
end

function update_deploy_record_instantiated!(
        hosts::AbstractVector{<:AbstractString},
        deploy_root::AbstractString,
        project::AbstractString,
    )
    rec = active_deploy_record()
    rec isa AbstractDict || return nothing
    mh_now = _deploy_record_manifest_hash(project)
    mh_now === nothing && return nothing
    want = get(rec, "manifest_hash", nothing)
    want isa AbstractString || return nothing
    mh_now == lowercase(strip(want)) || return nothing
    get(rec, "instantiated", false) == true && return rec
    new_rec = Dict{String, Any}(rec)
    new_rec["instantiated"] = true
    new_rec["timestamp"] = _deploy_record_timestamp()
    for h in hosts
        host_s = String(h)
        try
            _write_deploy_record_via_scp!(host_s, deploy_root, new_rec)
        catch e
            e isa InterruptException && rethrow()
            print_warn(
                "Deploy record instantiate flag not updated on $(host_s): $(sprint(showerror, e))\n",
            )
        end
    end
    _set_active_deploy_record!(new_rec)
    return new_rec
end
public update_deploy_record_instantiated!
