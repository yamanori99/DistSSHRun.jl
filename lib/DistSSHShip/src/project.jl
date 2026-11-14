# Project root the way Julia 1.13 resolves `--project` / `JULIA_PROJECT`.
# Upward search happens only for bare `--project`, `@.`, and `@script`,
# and it stops at the home directory, matching `Base.current_project`.
# A search that finds nothing is a named-environment fallback and is refused.
# `@temp`, `@stdlib`, `@v#.#`, and other `@name` environments are refused.
# `JuliaProject.toml` wins over `Project.toml`, matching `Base.project_names`.

"""Resolved project file Julia would activate for a shippable environment."""
struct ShipProject
    project_file::String
    project_dir::String
    manifest::Union{Nothing, String}
    # Directory of `Base.base_project` when this file is a workspace member.
    workspace_root::Union{Nothing, String}
end

function _posix(path::AbstractString)::String
    return replace(String(path), '\\' => '/')
end

function _under_home(dir::AbstractString, home::AbstractString)::Bool
    d = _posix(abspath(dir))
    h = _posix(abspath(home))
    d == h && return true
    return startswith(d, h * "/")
end

"""`Base.current_project(dir)`, including the stop at `homedir()`."""
function _current_project_file(dir::AbstractString)::Union{Nothing, String}
    return DistSSHBase.current_project_file(dir)
end

function _named_env_dir(dir::AbstractString)::Bool
    d = rstrip(_posix(abspath(dir)), '/')
    for depot in Base.DEPOT_PATH
        env = rstrip(_posix(joinpath(abspath(String(depot)), "environments")), '/')
        d == env && return true
        startswith(d, env * "/") && return true
    end
    std = rstrip(_posix(abspath(Sys.STDLIB)), '/')
    d == std && return true
    return startswith(d, std * "/")
end

function _reject_named_env(project_file::AbstractString)
    dir = dirname(abspath(project_file))
    if _named_env_dir(dir)
        throw(
            ArgumentError(
                "refusing named or default environment $(repr(project_file)). " *
                    "Pass an explicit project directory, `@.`, or `@script`.",
            )
        )
    end
    return nothing
end

function _project_from_file(project_file::AbstractString)::ShipProject
    file = abspath(String(project_file))
    isfile(file) || throw(
        ArgumentError(
            "no project file at $(repr(file)). " *
                "Julia would still report that path; ship refuses it.",
        )
    )
    basename(file) in Base.project_names || throw(
        ArgumentError(
            "not a project file: $(repr(file))",
        )
    )
    _reject_named_env(file)
    dir = abspath(dirname(file))
    manifest = DistSSHBase.manifest_path(file)
    base = Base.base_project(file)
    workspace = nothing
    if base isa AbstractString
        root = abspath(dirname(String(base)))
        if root != dir
            workspace = root
        end
    end
    return ShipProject(file, dir, manifest isa String ? abspath(manifest) : nothing, workspace)
end

function _explicit_project_file(spec::AbstractString, cwd::AbstractString)::String
    raw = abspath(cwd, expanduser(String(spec)))
    if isfile(raw) && basename(raw) in Base.project_names
        return raw
    end
    if isdir(raw)
        located = Base.locate_project_file(raw)
        if located isa AbstractString && isfile(located)
            return abspath(String(located))
        end
        throw(
            ArgumentError(
                "no project file in $(repr(raw)). " *
                    "`JuliaProject.toml` is checked before `Project.toml`.",
            )
        )
    end
    throw(
        ArgumentError(
            "project path does not exist: $(repr(raw))",
        )
    )
end

function _expand_at_spec(
        spec::AbstractString;
        script::Union{Nothing, AbstractString},
        cwd::AbstractString,
    )::String
    if spec == "@temp"
        throw(
            ArgumentError(
                "refusing `@temp`. A temporary environment is not a shippable project.",
            )
        )
    end
    if spec == "@stdlib"
        throw(ArgumentError("refusing `@stdlib`."))
    end
    if spec == "@." || spec == "@"
        found = _current_project_file(cwd)
        found === nothing && throw(
            ArgumentError(
                "project search from $(repr(cwd)) found nothing and would fall back to a named environment.",
            )
        )
        return found
    end
    if startswith(spec, "@script")
        if script === nothing || isempty(strip(String(script)))
            throw(
                ArgumentError(
                    "`@script` needs a script path. Without one, Julia falls back to a named environment.",
                )
            )
        end
        script_path = abspath(cwd, expanduser(String(script)))
        isfile(script_path) || throw(
            ArgumentError(
                "`@script` script does not exist: $(repr(script_path))",
            )
        )
        dir = dirname(script_path)
        if spec != "@script"
            dir = dir * spec[(length("@script") + 1):end]
        end
        found = _current_project_file(dir)
        found === nothing && throw(
            ArgumentError(
                "project search from script $(repr(script_path)) found nothing and would fall back to a named environment.",
            )
        )
        return found
    end
    if startswith(spec, "@")
        throw(
            ArgumentError(
                "refusing named environment $(repr(spec)). " *
                    "Pass an explicit project directory, `@.`, or `@script`.",
            )
        )
    end
    return _explicit_project_file(spec, cwd)
end

"""
    resolve_ship_project(spec; script=nothing, cwd=pwd()) -> ShipProject

`spec` is a `--project` / `JULIA_PROJECT` value.

* A directory or a `Project.toml` / `JuliaProject.toml` path is used as given.
  There is no upward search. A missing path or a directory with no project
  file is an error.
* `""` and `"@."` search parents from `cwd` and stop at the home directory.
* `"@script"` and `"@script/<rel>"` search from the script, using Julia's
  string suffix (`dirname(script) * suffix`), then parents.
* `"@temp"`, `"@stdlib"`, `"@v#.#"`, `"@name"`, and a search that would fall
  back to a named environment are errors.
* A resolved file that lives in a depot `environments/` directory or in
  `Sys.STDLIB` is an error.

`manifest` is `manifest_path` (workspace manifest, versioned manifest, then
`Manifest.toml`). `workspace_root` is set when `Base.base_project` names a
parent project.
"""
function resolve_ship_project(
        spec::AbstractString;
        script::Union{Nothing, AbstractString} = nothing,
        cwd::AbstractString = pwd(),
    )::ShipProject
    shown = String(spec)
    file = if shown == ""
        _expand_at_spec("@."; script = script, cwd = cwd)
    elseif startswith(shown, "@")
        _expand_at_spec(shown; script = script, cwd = cwd)
    else
        _explicit_project_file(shown, cwd)
    end
    return _project_from_file(file)
end

"""
    resolve_ship_project(; script=nothing, cwd=pwd()) -> ShipProject

The active spec of this process: `Base.JLOptions().project` when it was
passed, otherwise `JULIA_PROJECT`. An unset spec is the default named
environment and is refused. `--project` on the command line wins over
`JULIA_PROJECT`, matching Julia.
"""
function resolve_ship_project(;
        script::Union{Nothing, AbstractString} = nothing,
        cwd::AbstractString = pwd(),
    )::ShipProject
    opt = Base.JLOptions().project
    spec = if opt != C_NULL
        unsafe_string(opt)
    else
        get(ENV, "JULIA_PROJECT", nothing)
    end
    spec === nothing && throw(
        ArgumentError(
            "no --project or JULIA_PROJECT. The default load path is a named environment and is not shipped.",
        )
    )
    return resolve_ship_project(String(spec); script = script, cwd = cwd)
end
