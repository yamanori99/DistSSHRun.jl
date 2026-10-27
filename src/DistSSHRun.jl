"""
DistSSHRun — the DistSSHKit execution layer moved into this package.

One SSH run (`setup`, `go`, `ride`, `drive`, `plan`, `size`, `pool`, `demo`, `progress`) and the bang API (`go!`, `plan`, `ride!`, `pool!`, `drive!`, `pipeline!`).

DistSSHKit depends on DistSSHRun and DistSSHQueue and reexports their public names. Users add DistSSHKit and run `julia -m DistSSHKit`. This package can still be added on its own. The command is then `julia -m DistSSHRun`.

Package entry: exports, version, `include`s, `main` (`@main` on Julia 1.13+).
CLI entries live under `src/cli/`; argv parsers under `src/DistSSHRun/argv/`.
"""
module DistSSHRun

using Dates
using Distributed
using Pkg
import SHA
using TOML

# Public surface. Prefer `julia -m DistSSHKit …` for day-to-day CLI.
#   user — go! / ride! / drive! / plan / pool! / size! / setup! / pipeline!
#   occupancy — size! (RSS WorkerPlan; CLI size / pool; not implied by omit :N)
#   queue — execute!(; detached=true), parsers, paths, help chrome
#   argv wrappers `go` / `drive` stay unexported (`main` / tests)
export worker_pmap
export KitSession
export HostResult
export SyncResult
export WorkerPlan
export host_tokens
export is_parent_host_name
export DriveResult
export HostRunResult
export DriveHostStatus
export CollectResult
export KitRunResult
export KitProcess
export kit_run_result
export PipelineConfig
export PipelineResult
export sync!
export instantiate!
export setup!
export size!
export pool!
export ResourcePool
export HostInventory
export print_pool
export plan
export KitPlan
export PlanFinding
export print_plan
export stored_path
export file_sha256
export cache_file
export cache_path
export cache_relpath
export push_cache!
export cache_remote_dir
export drive!
export collect!
export pipeline!
export pipeline_config_from_env
export report_pipeline_errors
export report_run_errors
export go!
export GoResult
export report_go_errors
export ride!
export RideResult
export print_ride
export execute!
export allocate_output_dir
export allocate_run_dir
export kit_run_dir
export read_kit_run_toml
export execute_detached_accepts
export execute_kwargs_from_parsed
export kit_pid_file_running
export terminate!
export terminate_run!
export kit_result_from_dir
export drive_host_status
export parse_go_args
export parse_drive_args
export show_go_usage
export show_drive_usage
export println_kit_version
export ssh_opts
export run_on_host
export resolve_controller_julia
export canonical_local_path
export short_path
export resolve_pkg_project_dir
export resolve_pkg_env
export explain_script_not_found
export print_cli_error
export print_help_chrome
export print_help_section
export print_help_lines
export print_help_blank
export print_colored
export SPINNER_FRAMES
# `_print_colored` remains an alias of `print_colored`.


# Implementation

# Host talking lives in DistSSHBase, and the juliaup verbs in DistSSHUp.
# Confirm text and progress stay in setup/juliaup.jl.
# `lib/` sits beside `src/`. A copy of `src/` alone cannot load.
let _base_src = joinpath(@__DIR__, "..", "lib", "DistSSHBase", "src", "DistSSHBase.jl")
    isfile(_base_src) || error(
        "DistSSHRun: $_base_src is missing. Copy the whole DistSSHRun package directory, including lib/, not only src/.",
    )
end
include(joinpath(@__DIR__, "..", "lib", "DistSSHBase", "src", "DistSSHBase.jl"))
include("DistSSHRun/up_module.jl")
using .DistSSHBase
import .DistSSHBase: manifest_path
public manifest_path
using .DistSSHBase: CliCursor, OUTPUT_WIDTH, PARENT_HOST_NAME, _HOST_TOOL_NAMES,
    _NS_CACHE_DIR, _checked_remote_dest, _git_cmd, _host_sync_remote_shell_cmd,
    _host_tool_exe, _host_tool_present, _julia_spec_is_auto, _located_project_file,
    _normalize_hint_surface,
    _path_is_under, _path_under_resolved, _print_colored, _remote_shell_path_word,
    _rethrow_missing_host_tool, _scp_cmd, _ssh_cmd, _ssh_exe,
    _ssh_host_args, _test_double_julia_argv, _test_doubles_on, _truncate_ssh_message,
    cli_at_end, cli_consume!, cli_current, cli_entry, cli_heading, cli_m, cli_m_project,
    cli_match, cli_take_value!, clone_url_from_local_origin, detect_julia_path,
    display_path, ensure_remote_abs_path, explain_bare_placement_tokens,
    explain_clone_origin_missing, explain_clone_repo_required, explain_host_tool_hint,
    explain_host_tool_missing, explain_no_hosts, explain_pipeline_driver_missing,
    explain_size_probe_not_found, format_placement_token, get_remote_git_hash,
    get_remote_julia_version_full, get_remote_nproc, get_remote_total_gb,
    git_work_tree,
    is_sigint, join_explained_message, looks_like_path_host, normalize_git_clone_url,
    parse_placement_token, posix_quote, project_package_name, read_hosts_file, read_hosts_file_lines,
    remote_delete_root, remote_deploy_root, remote_env_project_root, remote_git_clone_dest,
    remote_layout_path, resolve_host_path_abs, resolve_host_project_abs,
    resolve_remote_julia, resolve_remote_project_root, rule_line, shield_sigint,
    split_hosts_csv, split_worker_token, ssh_addprocs_machine, summarize_ssh_error,
    throw_legacy_placement_token, throw_removed_local_flag, use_colors, validate_ssh_host,
    with_cli_entry,
    without_cancel
using .DistSSHUp: julia_version_mismatch_kind, juliaup_add_host!, juliaup_align_host!,
    juliaup_channel, juliaup_default_host!, juliaup_parent_behind_channel,
    juliaup_status_lines, juliaup_update_host!

include("DistSSHRun/display.jl")
include("DistSSHRun/argv/session.jl")
include("DistSSHRun/remote.jl")
include("DistSSHRun/launch.jl")
include("DistSSHRun/mismatch.jl")
include("DistSSHRun/demos.jl")
include("DistSSHRun/distributed.jl")
include("DistSSHRun/drive/types.jl")
include("DistSSHRun/run_manifest.jl")
include("DistSSHRun/size/measure.jl")
include("DistSSHRun/setup.jl")
include("DistSSHRun/argv/drive_args.jl")
include("DistSSHRun/argv/go_args.jl")
include("DistSSHRun/argv/plan_args.jl")
include("DistSSHRun/argv/setup_args.jl")
include("DistSSHRun/argv/up_args.jl")
include("DistSSHRun/argv/size_args.jl")
include("DistSSHRun/argv/pool_args.jl")
include("DistSSHRun/argv/ride_args.jl")
include("DistSSHRun/drive.jl")
include("DistSSHRun/namespace_sync.jl")
include("DistSSHRun/pool.jl")
include("DistSSHRun/drive/runtime/heartbeat.jl")
include("DistSSHRun/drive/runtime/_common.jl")
include("DistSSHRun/drive/runtime/cancel_frame.jl")
include("DistSSHRun/drive/runtime/checks.jl")
include("DistSSHRun/drive/runtime/collect_tree.jl")
include("DistSSHRun/drive/runtime/workers.jl")
include("DistSSHRun/drive/runtime/init.jl")
include("DistSSHRun/drive/runtime/results.jl")
include("DistSSHRun/drive/runtime/run.jl")
include("DistSSHRun/argv/size_report.jl")
include("DistSSHRun/plan.jl")
include("DistSSHRun/go.jl")
include("DistSSHRun/ride.jl")
include("DistSSHRun/execute.jl")
include("DistSSHRun/provenance.jl")

const _KIT_ROOT = dirname(@__DIR__)

# Kit version (from Project.toml).
# `@__DIR__` is `src/` — keep path resolution here, not in included files.

"""Read `version` from `path` (`Project.toml`); return `nothing` if missing or invalid."""
function _project_toml_version(path::AbstractString)::Union{Nothing, VersionNumber}
    p = String(path)
    isfile(p) || return nothing
    try
        raw = get(TOML.parsefile(p), "version", nothing)
        raw isa AbstractString || return nothing
        return VersionNumber(String(raw))
    catch
        return nothing
    end
end

const _DIST_SSH_KIT_PROJECT_TOML = joinpath(@__DIR__, "..", "Project.toml")

"""Semantic version of this vendored kit (from kit `Project.toml`)."""
const DIST_SSH_KIT_VERSION = something(
    _project_toml_version(_DIST_SSH_KIT_PROJECT_TOML),
    v"0.0.0",
)

dist_ssh_kit_version()::VersionNumber = DIST_SSH_KIT_VERSION

# CLI: load `src/cli/*.jl` into Main and run `*_main`.
#   julia --project=. -m DistSSHKit drive parent:2 script.jl

const _KIT_CLI_LOADED = Set{String}()
const _KIT_CLI_SCRIPTS = ("drive.jl", "go.jl", "plan.jl", "pool.jl", "ride.jl", "setup.jl", "size.jl", "up.jl")

const _KIT_CLI_MAIN = Dict(
    "drive.jl" => :drive_main,
    "go.jl" => :go_main,
    "plan.jl" => :plan_main,
    "pool.jl" => :pool_main,
    "ride.jl" => :ride_main,
    "setup.jl" => :setup_main,
    "size.jl" => :size_main,
    "up.jl" => :up_main,
)

function _kit_cli_run_entry(script_base::String)::Cint
    sym = get(_KIT_CLI_MAIN, script_base, nothing)
    sym === nothing && return 0
    return Base.invokelatest() do
        result = getfield(Main, sym)()
        return result isa Cint ? result : 0
    end
end

function _append_script_arg_prelude!(args::Vector{String})
    raw = get(ENV, "DISTSSHKIT_SCRIPT_ARG_PRELUDE", "")
    isempty(raw) && return
    delete!(ENV, "DISTSSHKIT_SCRIPT_ARG_PRELUDE")
    for line in split(raw, '\n')
        s = strip(String(line))
        !isempty(s) && push!(args, s)
    end
    return
end

function _merge_script_arg_prelude(rest::Vector{String})::Vector{String}
    merged = collect(String, rest)
    _append_script_arg_prelude!(merged)
    return merged
end

function _mark_kit_cli_subcommand_done!()
    return ENV["DISTSSHKIT_CLI_SUBCOMMAND_DONE"] = "1"
end

function _consume_kit_cli_subcommand_done!()::Bool
    if get(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE", "") == "1"
        delete!(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
        return true
    end
    return false
end

"""Run a kit CLI script under `src/cli/` (`drive.jl`, `setup.jl`, …) with `ARGS` set."""
function _run_kit_cli_script(script_name::AbstractString, args::Vector{String})::Cint
    prev_proj = get(ENV, "DISTRIBUTED_PROJECT_ROOT", nothing)
    prev_proj === nothing && (ENV["DISTRIBUTED_PROJECT_ROOT"] = pwd())
    # `args` may alias `ARGS` (the app launcher can pass `ARGS` directly).
    args_snapshot = collect(String, args)
    orig_args = copy(ARGS)
    empty!(ARGS)
    append!(ARGS, args_snapshot)
    script_path::String = if isabspath(script_name)
        String(script_name)
    else
        joinpath(@__DIR__, "cli", String(script_name))
    end
    script_base = basename(script_path)
    prev_include = get(ENV, "DIST_SSH_KIT_CLI_INCLUDE", nothing)
    ENV["DIST_SSH_KIT_CLI_INCLUDE"] = "1"
    try
        if script_base in _KIT_CLI_SCRIPTS
            if !(script_base in _KIT_CLI_LOADED)
                Core.include(Main, script_path)
                push!(_KIT_CLI_LOADED, script_base)
            end
            return _kit_cli_run_entry(script_base)
        end
        Core.include(Main, script_path)
        return 0
    finally
        empty!(ARGS)
        append!(ARGS, orig_args)
        if prev_proj === nothing
            delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
        else
            ENV["DISTRIBUTED_PROJECT_ROOT"] = prev_proj
        end
        if prev_include === nothing
            delete!(ENV, "DIST_SSH_KIT_CLI_INCLUDE")
        else
            ENV["DIST_SSH_KIT_CLI_INCLUDE"] = prev_include
        end
        _mark_kit_cli_subcommand_done!()
    end
end

"""
    drive(args::Vector{String}=copy(ARGS))

Run `drive.jl` with `args` (same as `julia -m DistSSHKit drive …`).
"""
drive(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("drive.jl", args)

"""
    go(args::Vector{String}=copy(ARGS))

Run `go.jl` with `args` (same as `julia -m DistSSHKit go …`).
"""
go(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("go.jl", args)

"""
    setup(args::Vector{String}=copy(ARGS))

Run `setup.jl` (clone / sync / cleanup) with `args` (same as `julia -m DistSSHKit setup …`).
"""
setup(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("setup.jl", args)

"""
    up(args::Vector{String}=copy(ARGS))

Run `up.jl` (juliaup align / update) with `args` (same as `julia -m DistSSHKit up …`).
"""
up(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("up.jl", args)

"""
    run_size(args::Vector{String}=copy(ARGS))

Run the `size` CLI (`size.jl`) with `args`. Named `run_size` so it does not
shadow `Base.size`. Prefer `julia -m DistSSHKit size …` day-to-day.
"""
run_size(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("size.jl", args)

"""
    run_pool(args::Vector{String}=copy(ARGS))

Run the `pool` CLI (`pool.jl`) with `args`. Prefer `julia -m DistSSHKit pool …`.
"""
run_pool(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("pool.jl", args)

"""
    run_ride(args::Vector{String}=copy(ARGS))

Run the `ride` CLI (`ride.jl`) with `args`. Prefer `julia -m DistSSHKit ride …`.
"""
run_ride(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("ride.jl", args)

"""
    run_plan(args::Vector{String}=copy(ARGS))

Run the `plan` CLI (`plan.jl`) with `args`. Prefer `julia -m DistSSHKit plan …`.
"""
run_plan(args::Vector{String} = copy(ARGS))::Cint = _run_kit_cli_script("plan.jl", args)

"""
    main(args::Vector{String}=copy(ARGS))

CLI entry. Prefer Julia 1.13+ and `julia -m DistSSHKit SUBCOMMAND …`:

    julia --project=. -m DistSSHKit setup --clone child:host1 child:host2
    julia --project=. -m DistSSHKit go SCRIPT.jl
    julia --project=. -m DistSSHKit ride parent:2 SCRIPT.jl
    julia --project=. -m DistSSHKit drive parent:2 script.jl
    julia --project=. -m DistSSHKit plan SCRIPT.jl
    julia --project=. -m DistSSHKit size parent child:host1
    julia --project=. -m DistSSHKit pool parent child:host1
    julia --project=. -m DistSSHKit progress DIR

`main` remains for wrappers and tests; prefer `-m` day-to-day.
A `.jl` path with no command is not implicit `go`.
"""
function main(args::Vector{String} = copy(ARGS))::Cint
    try
        return with_cli_entry(:DistSSHRun) do
            return _main(args)
        end
    catch e
        # After the drive frame's `finally` blocks. Translation only.
        _cli_finish_interrupt(e)
        rethrow()
    end
end

public main

# The callable stays in a `Dict{String,Function}` so `_main` infers one call.
# `demo` and `progress` are ordinary functions. The script commands stop in
# `include`, but a static call from `_main` still pulls `demo` and `progress` in.
const _RUN_CALLS = Dict{String, Function}(
    "drive" => (rest -> drive(_merge_script_arg_prelude(rest))::Cint),
    "go" => (rest -> go(_merge_script_arg_prelude(rest))::Cint),
    "demo" => (rest -> demo(rest)::Cint),
    "setup" => (rest -> setup(rest)::Cint),
    "up" => (rest -> up(rest)::Cint),
    "plan" => (rest -> run_plan(rest)::Cint),
    "ride" => (rest -> run_ride(rest)::Cint),
    "size" => (rest -> run_size(rest)::Cint),
    "pool" => (rest -> run_pool(rest)::Cint),
    "progress" => (rest -> progress(rest)::Cint),
)

"""`Unknown subcommand: ` plus `name`. DistSSHKit prints this sentence too."""
function unknown_subcommand_message(name::AbstractString)::String
    return "Unknown subcommand: $(name)"
end

"""The `.jl` rejection sentence. `name` is the word the caller reports."""
function no_command_message(name::AbstractString)::String
    return "No command (got $(repr(String(name)))). Kit does not infer go / ride / drive."
end

# Lines under `no_command_message`. DistSSHKit prints the same four lines.
const NO_COMMAND_HINT_LINES = (
    "  go SCRIPT.jl      as-is complete job (timing without rewrite)",
    "  ride … SCRIPT.jl  experimental map / filter",
    "  drive … SCRIPT.jl Distributed",
    "  plan SCRIPT.jl    inspect; do not run",
)

# The run-command list under `unknown_subcommand_message`. Order is the sentence.
const RUN_SUBCOMMAND_EXPECTATION =
    "Expected: setup | up | go | ride | drive | plan | size | pool | demo | progress"

"""Print the shared rejection lines. The caller prints the usage page.

`script` is the `.jl` sentence and `NO_COMMAND_HINT_LINES`. Otherwise this
prints `unknown_subcommand_message` and `RUN_SUBCOMMAND_EXPECTATION`.
DistSSHKit prints its Queue line after that expectation, then its own page.
"""
function print_rejected_command(name::AbstractString; script::Bool, io::IO = stderr)
    if script
        print_cli_error(no_command_message(name); io = io)
        for line in NO_COMMAND_HINT_LINES
            println(io, line)
        end
    else
        print_cli_error(unknown_subcommand_message(name); io = io)
        println(io, RUN_SUBCOMMAND_EXPECTATION)
    end
    return nothing
end

public unknown_subcommand_message
public no_command_message
public NO_COMMAND_HINT_LINES
public RUN_SUBCOMMAND_EXPECTATION
public print_rejected_command

function _main(args::Vector{String})::Cint
    try
        return _main_dispatch(args)
    finally
        # A second `main` in this process must run. The handshake flag is
        # single-shot: consume clears it, and this deletes it again on every
        # return, including throw and drive interrupt.
        delete!(ENV, "DISTSSHKIT_CLI_SUBCOMMAND_DONE")
    end
end

function _main_dispatch(args::Vector{String})::Cint
    if _consume_kit_cli_subcommand_done!()
        return 0
    end
    if length(args) == 1 && args[1] in ("--version", "-v", "-V")
        println_kit_version()
        return 0
    end
    # `help`, `-h`, and `--help`, in any number and order, are the root page.
    # `help go --help` is not: `go` is a command, so the rewrite below still runs.
    if !isempty(args) && all(in(("help", "-h", "--help")), args)
        print_kit_root_usage()
        return 0
    end
    if isempty(args)
        print_kit_root_usage()
        return 1
    end
    # `help <verb> …` is `<verb> --help …`, once. A second word that is not a
    # command stays on the unknown-subcommand path, and that word is the name.
    # An argv of only help words already returned above.
    if length(args) >= 2 && args[1] == "help"
        verb = args[2]
        if haskey(_RUN_CALLS, verb)
            rewritten = String[verb, "--help"]
            append!(rewritten, args[3:end])
            return _main(rewritten)
        end
        args = args[2:end]
    end
    subcommand, rest = args[1], args[2:end]
    if subcommand in ("drive", "go") &&
            any(endswith(String(a), ".jl") for a in rest)
        _mark_kit_cli_subcommand_done!()
    end
    call = get(_RUN_CALLS, subcommand, nothing)
    if call !== nothing
        return call(rest)::Cint
    end
    print_rejected_command(
        subcommand;
        script = any(endswith(String(a), ".jl") for a in args),
    )
    println(stderr)
    print_kit_root_usage()
    return 1
end

include("DistSSHRun/precompile.jl")

Base.eval(@__MODULE__, :(@main))

end # module DistSSHRun
