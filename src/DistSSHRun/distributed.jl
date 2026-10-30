using Distributed

"""
    resolve_distributed_output_dir!(script_args, default_dir)

Set `ENV["DISTRIBUTED_OUTPUT_DIR"]` for a driver run and return the canonical path.

Priority (first match wins):

1. `ENV["DISTRIBUTED_OUTPUT_DIR"]` if already set (drive `--output-dir`, operator `export`, …)
2. `--output-dir PATH` in `script_args`
3. `default_dir` (e.g. `joinpath(@__DIR__, "output")`)

Creates the directory when missing. Drivers should call this from `init_output_dir!`.
"""
function resolve_distributed_output_dir!(
        script_args::Vector{String},
        default_dir::AbstractString,
    )::String
    existing = strip(get(ENV, "DISTRIBUTED_OUTPUT_DIR", ""))
    if !isempty(existing)
        dir = canonical_local_path(existing)
        mkpath(dir)
        ENV["DISTRIBUTED_OUTPUT_DIR"] = dir
        return dir
    end
    for j in 1:(length(script_args) - 1)
        if script_args[j] == "--output-dir"
            dir = canonical_local_path(script_args[j + 1])
            mkpath(dir)
            ENV["DISTRIBUTED_OUTPUT_DIR"] = dir
            return dir
        end
    end
    dir = canonical_local_path(default_dir)
    mkpath(dir)
    ENV["DISTRIBUTED_OUTPUT_DIR"] = dir
    return dir
end

const _OUTPUT_DIR_COMMANDS = (:go, :ride, :drive)

function _output_dir_command!(command::Symbol)::Symbol
    command in _OUTPUT_DIR_COMMANDS || throw(
        ArgumentError(
            "output directory command must be :go, :ride, or :drive, got $(repr(command))",
        ),
    )
    return command
end

function _output_dir_hint(command::Symbol, surface::Symbol)::String
    surface = _normalize_hint_surface(surface)
    if surface === :cli
        return "Run `$(cli_m()) help $(command)` for flags."
    end
    return "Omit output_dir or pass an empty directory."
end

function _output_dir_refusal(
        path::AbstractString,
        command::Symbol,
        surface::Symbol;
        kind::Symbol,
        names::Vector{String} = String[],
    )::String
    head = if kind === :symlink
        "refusing output directory symlink: $path"
    elseif kind === :file
        "output path is not a directory: $path"
    else
        lines = String["refusing non-empty output directory: $path"]
        for name in names
            push!(lines, "  " * joinpath(path, name))
        end
        join(lines, '\n')
    end
    return join_explained_message(head, _output_dir_hint(command, surface))
end

# Parent `execute!(detached=true)` writes these into the output directory after
# spawn, once that directory was already empty. A child that inherited
# `DISTSSHKIT_RUN_DIR` may see them and nothing else.
const _OUTPUT_DIR_PARENT_SIDECARS = ("kit.job", "kit.pid", "kit.run_dir")

"""
    _prepare_output_dir!(dir; command, surface=:api, allow_parent_sidecars=false) -> String

Make `dir` an empty output directory.

A missing path is created. An existing empty directory is kept. A non-empty
directory, a file, or a symlink is refused. Call this before a lock or
`kit.pid` write.

`allow_parent_sidecars` is for a child that already inherited
`DISTSSHKIT_RUN_DIR`. `kit.pid`, `kit.job`, and `kit.run_dir` alone do not
refuse that directory. Any other name still does, and the error lists every name.
"""
function _prepare_output_dir!(
        dir::AbstractString;
        command::Symbol,
        surface::Symbol = :api,
        allow_parent_sidecars::Bool = false,
    )::String
    command = _output_dir_command!(command)
    path = canonical_local_path(dir)
    if islink(path)
        throw(ArgumentError(_output_dir_refusal(path, command, surface; kind = :symlink)))
    end
    if ispath(path) && !isdir(path)
        throw(ArgumentError(_output_dir_refusal(path, command, surface; kind = :file)))
    end
    if isdir(path)
        names = sort!(String[String(name) for name in readdir(path)])
        blocking = if allow_parent_sidecars
            filter(n -> !(n in _OUTPUT_DIR_PARENT_SIDECARS), names)
        else
            names
        end
        isempty(blocking) || throw(
            ArgumentError(
                _output_dir_refusal(path, command, surface; kind = :nonempty, names = names),
            ),
        )
        return path
    end
    mkpath(path)
    return canonical_local_path(path)
end

"""`{script_dir}/.distsshkit/{kind}` (parent of go / ride / drive batch dirs)."""
function kit_dir_beside_script(script_dir::AbstractString, kind::Symbol)::String
    return canonical_local_path(joinpath(String(script_dir), ".distsshkit", String(kind)))
end

"""
    resolve_drive_output_dir(script_dir) -> String

Best-effort result root for a `drive` run: `ENV["DISTRIBUTED_OUTPUT_DIR"]` if
set (explicit `--output-dir` / `output_dir=`, kit's unique batch dir, or a
driver's own `init_output_dir!`), else `{script_dir}/.distsshkit/drive`
(the kind root, not a per-run leaf). Live runs set ENV before lock / collect
so this fallback is only for callers that never entered `drive`. Same
priority `collect_drive_results!` uses to report `Results:`.
"""
function resolve_drive_output_dir(script_dir::AbstractString)::String
    results_dir = get(ENV, "DISTRIBUTED_OUTPUT_DIR", nothing)
    if results_dir === nothing
        results_dir = kit_dir_beside_script(script_dir, :drive)
    end
    return canonical_local_path(results_dir)
end

"""
    resolve_drive_log_dir(log_dir, script_dir) -> String

Log directory a `drive` run actually uses (single source of truth for
`init_log_file`'s priority): explicit `log_dir` (`--log-dir` / `log_dir=`),
else `ENV["DISTRIBUTED_OUTPUT_DIR"]`, else `{script_dir}/.distsshkit/drive`
(kind root; live runs set ENV first).
"""
function resolve_drive_log_dir(
        log_dir::Union{Nothing, AbstractString},
        script_dir::AbstractString,
    )::String
    resolved = log_dir
    if resolved === nothing
        rd = kit_run_dir()
        rd !== nothing && return rd
        resolved = get(ENV, "DISTRIBUTED_OUTPUT_DIR", nothing)
    end
    if resolved === nothing
        resolved = kit_dir_beside_script(script_dir, :drive)
    end
    return String(resolved)
end

"""
    worker_pmap(f, collection)

Like `Distributed.pmap`, but evaluates `f` with `Base.invokelatest` on each element.

After `drive` syncs your driver to workers and loads the project package, plain
`pmap` is usually enough. Use `worker_pmap` when a callback still hits Julia 1.12+
world-age errors (for example, a function reference or closure captured before
package load).
"""
worker_pmap(f, collection) = pmap(x -> Base.invokelatest(f, x), collection)
