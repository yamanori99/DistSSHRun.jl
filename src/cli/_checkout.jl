# Load this checkout when `--project` is the user's app, not DistSSHRun.
# A registry install takes the `import` in the caller and never gets here.
#
# `include` of `src/DistSSHRun.jl` does not resolve non-stdlib deps.
# A tree with no Manifest is developed into the depot, then loaded as a package.
# The active project stays what the process was given.
#
# Do not `import Pkg` here. `setup.jl` includes this file on every run, and
# `import` only sees direct deps of `LOAD_PATH`. `Pkg.test` sets that to the
# test project, which does not depend on Pkg. Load the stdlib by its id.

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

    # `Base.require` of a stdlib id finds `Sys.STDLIB` when the name is not a
    # direct dependency. An already loaded module is reused.
    function _checkout_stdlib(name::AbstractString, uuid::AbstractString)
        id = Base.PkgId(Base.UUID(uuid), String(name))
        loaded = get(Base.loaded_modules, id, nothing)
        if loaded isa Module
            return loaded
        end
        return Base.require(id)
    end

    function _checkout_name_of(toml_mod::Module, toml::String)::String
        parse = getfield(toml_mod, :parse)
        parsed = parse(toml)
        name = get(parsed, "name", "")
        return name isa AbstractString ? String(name) : ""
    end

    function _checkout_project_name(toml::AbstractString)::String
        toml_mod = _checkout_stdlib("TOML", "fa267f1f-6049-4f14-aa54-33bafae1ed76")
        return Base.invokelatest(_checkout_name_of, toml_mod, String(toml))::String
    end

    function _checkout_develop_now!(pkg::Module, env::AbstractString, root::AbstractString)
        activate = getfield(pkg, :activate)
        develop = getfield(pkg, :develop)
        instantiate = getfield(pkg, :instantiate)
        spec = getfield(pkg, :PackageSpec)
        activate(env) do
            develop(spec(; path = root); io = devnull)
            instantiate(; io = devnull)
        end
        return nothing
    end

    function _checkout_develop!(env::AbstractString, root::AbstractString)
        pkg = _checkout_stdlib("Pkg", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
        Base.invokelatest(_checkout_develop_now!, pkg, env, root)
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
