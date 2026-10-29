# drive! — API entry for driver execution (same core as CLI `drive`).

"""
    drive!(session::KitSession, script; plan=nothing, args=[], ...)
    drive!(script, workers...; kwargs...)
    drive!(script, workers::AbstractVector; kwargs...)

Run a driver script on workers. Tokens match the CLI (`parent:2`, `child:user@host:1`).
A file with no Distributed vocabulary warns (this-file scan only) and still runs.
Load is the master `include`. Publish sends definitions to workers (not top-level
work). Run is `main()` when defined. Use [`plan`](@ref) / [`go!`](@ref) / [`ride!`](@ref)
when that matches the script.

```julia
drive!("job.jl", "parent:2"; args=["8"])
drive!(session, "job.jl")  # uses `session.tokens`
```

With `sync` omitted or `false`, prepare remotes with [`setup!`](@ref) or CLI
`setup` first; remotes are checked before execution. Optional
`sync=:sync` / `sync=:ship_tree` copies, then checks. After `:ship_tree`, hosts that
still lack Manifest deps get [`instantiate!`](@ref) (same as CLI
`drive --ship-tree`).
Git parity is off by default (`skip_hash_check=true`). With `sync=:ship_tree`, parity
stays off even if `skip_hash_check=false` (no remote `.git/`).
`require_all_hosts=true` (the default; CLI `--require-all-hosts`) fails unless
every explicit `parent:N` / `child:NAME:N` joined, stayed through the run,
and collect succeeded. Pass `require_all_hosts=false` or CLI `--best-effort`
for a partial run.

A collect root that is the project or a parent of it stops the run before
`main` and before collect, with exit code 1. That includes
`DISTRIBUTED_COLLECT_DIRS` and a default root from `DISTRIBUTED_OUTPUT_DIR`.

`mem_headroom` / `parent_gb` are the RAM budget for drive preflight (same as
[`size!`](@ref) / CLI `--mem-headroom` / `--parent-gb`). [`pipeline!`](@ref)
passes `config.mem_headroom` and `config.parent_gb`.

`julia` sets the remote Julia binary (`nothing` / `"auto"` → detect; same as
CLI `--julia`). `plan` is an optional explicit [`WorkerPlan`](@ref).
[`pipeline!`](@ref) syncs separately and does not pass `sync=` into `drive!`,
so it does not instantiate after rsync.

`sync_script=true` (CLI `--sync-script`) re-`include`s the full driver on
workers. The default publishes definitions / `using` / `import` / `include`
only, so top-level work on Load is not repeated on workers.

Ctrl-C restores the active project and the `DISTRIBUTED_*` entries this call
changed, then rethrows `InterruptException` or, when Julia has it,
`Base.CancellationRequest`. `drive!` does not `exit` and does not throw the
private CLI exception. On Julia 1.14 the caller's task stays cancelled after
that exception.
"""
function drive!(
        session::KitSession,
        script::AbstractString;
        plan::Union{Nothing, WorkerPlan} = nothing,
        args::AbstractVector{<:AbstractString} = String[],
        skip_hash_check::Bool = true,
        output_dir::Union{Nothing, AbstractString} = nothing,
        enable_log::Bool = true,
        log_dir::Union{Nothing, AbstractString} = nothing,
        package::Union{Nothing, AbstractString} = nothing,
        sync::Union{Nothing, Symbol, Bool} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
        require_all_hosts::Bool = true,
        mem_headroom::Real = DEFAULT_MEM_HEADROOM,
        parent_gb::Real = DEFAULT_PARENT_GB,
        sync_script::Bool = false,
        allow_mismatch = Symbol[],
        allow_external_symlinks::Bool = false,
    )::DriveResult
    return _drive_frame(; cli = false) do
        return _with_kit_inproc_run!(:drive) do
            # Outside `run_drive_parsed!`: `apply_session_env!` runs first, and
            # this frame restores it after the inner drive frame returns.
            return _with_drive_process!(session.project) do
                apply_session_env!(session)
                resolved = plan
                if resolved === nothing && !isempty(session.tokens)
                    resolved = worker_plan_from_tokens(session.tokens)
                end
                parsed = drive_parsed_from_session(
                    session,
                    script;
                    workers = resolved,
                    script_args = args,
                    skip_hash_check = skip_hash_check,
                    output_dir = output_dir,
                    enable_log = enable_log,
                    log_dir = log_dir,
                    package = package,
                    sync = sync,
                    julia = julia,
                    require_all_hosts = require_all_hosts,
                    mem_headroom = mem_headroom,
                    parent_gb = parent_gb,
                    sync_script = sync_script,
                    allow_mismatch = allow_mismatch,
                    allow_external_symlinks = allow_external_symlinks,
                )
                apply_kit_cli_session!(parsed.cli_session)
                original_args = copy(ARGS)
                resolved_output_dir = Ref{Union{Nothing, String}}(nothing)
                resolved_log_dir = Ref{Union{Nothing, String}}(nothing)
                resolved_hosts = Ref{Vector{HostRunResult}}(HostRunResult[])
                try
                    code = run_drive_parsed!(
                        parsed;
                        original_args = original_args,
                        resolved_output_dir = resolved_output_dir,
                        resolved_log_dir = resolved_log_dir,
                        resolved_hosts = resolved_hosts,
                        project_root = session.project,
                    )
                    return DriveResult(
                        code == 0, Int(code);
                        output_dir = resolved_output_dir[],
                        log_dir = resolved_log_dir[],
                        failed_step = code == 0 ? nothing : "drive",
                        hosts = resolved_hosts[],
                    )
                finally
                    empty!(ARGS)
                    append!(ARGS, original_args)
                end
            end
        end
    end
end

function drive!(
        script::AbstractString,
        workers::AbstractVector{<:AbstractString};
        project::AbstractString = pwd(),
        remote::Union{Nothing, AbstractString} = nothing,
        hosts_file::Union{Nothing, AbstractString} = nothing,
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
        yes::Bool = true,
        kwargs...,
    )::DriveResult
    session = KitSession(
        project = project,
        workers = workers,
        remote = remote,
        hosts_file = hosts_file,
        quiet = quiet,
        verbosity = verbosity,
        yes = yes,
    )
    return drive!(session, script; kwargs...)
end

function drive!(script::AbstractString; kwargs...)::DriveResult
    return drive!(script, String[]; kwargs...)
end

function drive!(
        script::AbstractString,
        w1::AbstractString,
        rest::AbstractString...;
        kwargs...,
    )::DriveResult
    return drive!(script, String[w1, rest...]; kwargs...)
end
