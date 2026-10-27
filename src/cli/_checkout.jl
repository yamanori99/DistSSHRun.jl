# Load this checkout when the active environment does not provide DistSSHRun.
# A registry install and `julia -m` take the caller's `import` and never get here.
#
# Do not `import Pkg` or `import TOML` here. `setup.jl` includes this file on
# every run, and `import` only sees direct dependencies of `LOAD_PATH`.
# `Pkg.test` sets that to the test project. Manifest and project names are
# Base's (`Project.toml`, `JuliaProject.toml`, `Manifest.toml`,
# `JuliaManifest.toml`, and `Manifest-v<major>.<minor>.toml`).

if !isdefined(@__MODULE__, :_include_checkout_run)
    function _checkout_root()::String
        return normpath(abspath(joinpath(@__DIR__, "..", "..")))
    end

    function _checkout_quote(path::AbstractString)::String
        return "\"" * replace(String(path), "\"" => "\\\"") * "\""
    end

    function _checkout_project_file(root::AbstractString)::Union{Nothing, String}
        located = Base.locate_project_file(String(root))
        return located isa String ? located : nothing
    end

    function _checkout_manifest_file(root::AbstractString)::Union{Nothing, String}
        proj = _checkout_project_file(root)
        proj === nothing && return nothing
        return Base.project_file_manifest_path(proj)
    end

    function _checkout_is_run(root::AbstractString)::Bool
        proj = _checkout_project_file(root)
        proj === nothing && return false
        name = get(Base.parsed_toml(proj), "name", "")
        return name == "DistSSHRun"
    end

    # An installed tree (`…/packages/DistSSHRun/<slug>`), not a clone.
    function _checkout_in_depot(root::AbstractString)::Bool
        root = normpath(abspath(String(root)))
        sep = Base.Filesystem.path_separator
        for depot in DEPOT_PATH
            isempty(depot) && continue
            packages = normpath(abspath(joinpath(String(depot), "packages")))
            root == packages && return true
            startswith(root, packages * sep) && return true
        end
        return false
    end

    function _checkout_no_manifest_line(root::AbstractString)::String
        shown = _checkout_quote(root)
        return "No Manifest in $(shown). Run: julia --project=$(shown) -e 'using Pkg; Pkg.instantiate()'"
    end

    function _checkout_deps_line(root::AbstractString)::String
        shown = _checkout_quote(root)
        return "Dependencies of $(shown) are not instantiated. Run: julia --project=$(shown) -e 'using Pkg; Pkg.instantiate()' or Pkg.resolve()"
    end

    # `nothing` means `err` is not one of the two hints.
    function _checkout_hint_message(err)::Union{Nothing, String}
        seen = 0
        while err isa LoadError && seen < 8
            err = err.error
            seen += 1
        end
        if err isa ErrorException
            msg = err.msg
            if startswith(msg, "No Manifest in ") || startswith(msg, "Dependencies of ")
                return msg
            end
        end
        if err isa ArgumentError
            msg = err.msg
            # Not in the environment at all. The caller reports Julia's error.
            occursin("Package DistSSHRun not found in current path", msg) && return nothing
            if occursin("not found in current path", msg) ||
                    occursin("does not seem to be installed", msg)
                return _checkout_deps_line(_checkout_root())
            end
        end
        return nothing
    end

    # One stderr line when this file is the program. Otherwise throw.
    function _checkout_report(err, script::AbstractString)
        hint = _checkout_hint_message(err)
        hint === nothing && rethrow()
        if !isempty(PROGRAM_FILE) && abspath(PROGRAM_FILE) == abspath(String(script))
            println(stderr, hint)
            exit(1)
        end
        if err isa ErrorException && err.msg == hint
            rethrow()
        end
        error(hint)
    end

    # Puts a checkout that already has a manifest on `LOAD_PATH`.
    # The caller then `import`s at top level.
    function _include_checkout_run()
        root = _checkout_root()
        _checkout_is_run(root) || return nothing
        if _checkout_manifest_file(root) !== nothing
            # `pushfirst!` puts this tree ahead of the active project, so a
            # name defined here wins for DistSSHRun and for any other package
            # this tree also provides.
            root in LOAD_PATH || pushfirst!(LOAD_PATH, root)
            return nothing
        end
        _checkout_in_depot(root) && return nothing
        error(_checkout_no_manifest_line(root))
    end
end
