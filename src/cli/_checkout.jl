# Load this checkout when `--project` is the user's app, not DistSSHRun.
# A registry install takes the `import` in the caller and never gets here.
#
# `include` of `src/DistSSHRun.jl` does not resolve non-stdlib deps.
# A tree with no Manifest is developed into the depot, then loaded as a package.
# The active project stays what the process was given.

import Pkg
import TOML

if !isdefined(@__MODULE__, :_checkout_load_env)
    # BSD and Linux `flock`: exclusive lock, then unlock.
    function _checkout_flock(io::IOStream, op::Cint)
        rc = ccall(:flock, Cint, (RawFD, Cint), Base.fd(io), op)
        systemerror("flock", rc != 0)
        return nothing
    end

    function _checkout_with_flock(f::Function, lock_path::AbstractString)
        Sys.isunix() || (f(); return nothing)
        open(lock_path, "w+") do io
            _checkout_flock(io, Cint(2))
            try
                f()
            finally
                _checkout_flock(io, Cint(8))
            end
        end
        return nothing
    end

    function _checkout_project_name(toml::AbstractString)::String
        parsed = TOML.parse(String(toml))
        name = get(parsed, "name", "")
        return name isa AbstractString ? String(name) : ""
    end

    function _checkout_develop!(env::AbstractString, root::AbstractString)
        Pkg.activate(env) do
            Pkg.develop(Pkg.PackageSpec(; path = root); io = devnull)
            Pkg.instantiate(; io = devnull)
        end
        return nothing
    end

    function _checkout_fill_env!(env::AbstractString, root::AbstractString)
        isfile(joinpath(env, "Manifest.toml")) && return nothing
        rm(env; force = true, recursive = true)
        mkpath(env)
        _checkout_develop!(env, root)
        return nothing
    end

    function _checkout_ensure_env!(env::AbstractString, root::AbstractString)
        mkpath(dirname(env))
        _checkout_with_flock(env * ".lock") do
            _checkout_fill_env!(env, root)
        end
        return nothing
    end

    # A tree that already has `Manifest.toml` is that directory.
    # A DistSSHRun tree without one is developed into the first depot.
    function _checkout_load_env(root::AbstractString)::String
        root = normpath(abspath(String(root)))
        isfile(joinpath(root, "Manifest.toml")) && return root
        toml_path = joinpath(root, "Project.toml")
        isfile(toml_path) || return root
        toml = read(toml_path, String)
        _checkout_project_name(toml) == "DistSSHRun" || return root
        depot = Base.DEPOT_PATH[1]
        isempty(depot) && (depot = joinpath(homedir(), ".julia"))
        slug = string(hash(root * "\n" * toml); base = 16)
        env = joinpath(depot, "environments", "distsshrun-cli", slug)
        _checkout_ensure_env!(env, root)
        return env
    end

    # Puts this checkout on `LOAD_PATH`. The caller then `import DistSSHRun`
    # at top level (`import` is not legal inside this function).
    function _include_checkout_run()
        root = normpath(abspath(joinpath(@__DIR__, "..", "..")))
        env = _checkout_load_env(root)
        env in LOAD_PATH || pushfirst!(LOAD_PATH, env)
        return nothing
    end
end
