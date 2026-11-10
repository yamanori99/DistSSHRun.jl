# drive! — API entry for driver execution (same core as CLI `drive`).

"""
    drive!(session::KitSession, script; plan=nothing, args=[], ...)
    drive!(script, workers...; kwargs...)
    drive!(script, workers::AbstractVector; kwargs...)

Run a driver script on workers. Tokens match the CLI (`parent:2`, `child:user@host:1`).
Load is the master `include`. Publish sends definitions to workers (not top-level
work). Run is `main()` when defined. Use [`go!`](@ref) / [`ride!`](@ref)
when that matches the script.

```julia
drive!("job.jl", "parent:2"; args=["8"])
drive!(session, "job.jl")  # uses `session.tokens`
```

With `sync` omitted or `false` (the default), prepare remotes with
[`setup!`](@ref) or CLI `setup` first; remotes are checked before execution.
The `drive` CLI does not take `--ship-tree` or `--git-sync`; prepare with
`setup ship-tree` or `setup git-sync`, then `setup instantiate` when needed,
then `drive --run-id ID`. Passing `sync=:git_sync` or `sync=:ship_tree` on
[`drive!`](@ref) is an `ArgumentError` (transfer on run was removed).
Git parity is off by default (`skip_hash_check=true`).
`require_all_hosts=true` (the default; CLI `--require-all-hosts`) fails unless
every explicit `parent:N` / `child:NAME:N` joined, stayed through the run,
and collect succeeded. Pass `require_all_hosts=false` or CLI `--best-effort`
for a partial run.

A collect root that is the project or a parent of it stops the run before
`main` and before collect, with exit code 1. That includes
`DISTRIBUTED_COLLECT_DIRS` and a default root from `DISTRIBUTED_OUTPUT_DIR`.

`julia` sets the remote Julia binary (`nothing` / `"auto"` → detect; same as
CLI `--julia`). `snapshot` (CLI `--run-id`) selects `runs/<ID>/src` under the
deploy root when `sync` is omitted or `false`. `plan` is an optional explicit
[`WorkerPlan`](@ref). [`pipeline!`](@ref) runs [`drive!`](@ref) and optional collect only; call
[`setup!`](@ref) first. It does not pass run-time `sync=` into `drive!`.

`worker_include=true` (CLI `--worker-include`) re-`include`s the full driver on
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
        worker_include::Bool = false,
        sync_script::Union{Nothing, Bool} = nothing,
        allow_mismatch = Symbol[],
        allow_external_symlinks::Bool = false,
        run_id::Union{Nothing, AbstractString} = nothing,
    )::DriveResult
    _reject_removed_drive_worker_include_kw!(sync_script)
    _reject_run_transfer_kw!("drive!", sync; surface = hint_surface(session))
    allow_external_symlinks &&
        _reject_run_transfer_cli!("drive!", "--allow-external-symlinks")
    return _drive_frame(; cli = false) do
        return _with_kit_inproc_run!(:drive) do
            # Outside `run_drive_parsed!`: `apply_session_env!` runs first, and
            # this frame restores DISTRIBUTED_* after the inner drive returns.
            return _with_drive_process!(session.project) do
                apply_session_env!(session)
                # Scoped for `remote_layout_path` / worker path mapping only.
                # Restored here and again by `_with_drive_process!`.
                return _with_session_remote_env!(session) do
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
                        julia = julia,
                        require_all_hosts = require_all_hosts,
                        worker_include = worker_include,
                        allow_mismatch = allow_mismatch,
                        run_id = run_id,
                    )
                    apply_kit_cli_session!(parsed.cli_session)
                    original_args = copy(ARGS)
                    resolved_output_dir = Ref{Union{Nothing, String}}(nothing)
                    resolved_log_dir = Ref{Union{Nothing, String}}(nothing)
                    resolved_hosts = Ref{Vector{HostRunResult}}(HostRunResult[])
                    resolved_run_dir = Ref{Union{Nothing, String}}(nothing)
                    try
                        code = run_drive_parsed!(
                            parsed;
                            original_args = original_args,
                            resolved_output_dir = resolved_output_dir,
                            resolved_log_dir = resolved_log_dir,
                            resolved_hosts = resolved_hosts,
                            resolved_run_dir = resolved_run_dir,
                            project_root = session.project,
                        )
                        return DriveResult(
                            code == 0, Int(code);
                            output_dir = resolved_output_dir[],
                            log_dir = resolved_log_dir[],
                            failed_step = code == 0 ? nothing : "drive",
                            hosts = resolved_hosts[],
                            run_dir = resolved_run_dir[],
                        )
                    finally
                        empty!(ARGS)
                        append!(ARGS, original_args)
                    end
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
