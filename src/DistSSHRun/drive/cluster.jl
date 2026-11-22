# Scoped worker launch without a drive script (issue #464).

"""
    Cluster

Workers DistSSH launched for one [`cluster`](@ref) call, plus the [`LaunchReport`](@ref).
Field names are API: `report`, `workers`.
"""
struct Cluster
    report::LaunchReport
    workers::Vector{Int}
end

function _cluster_placement(
        session::DistSSHSession,
        plan::Union{Nothing, WorkerPlan},
    )::Tuple{Int, Vector{Tuple{String, Union{Int, Nothing}}}}
    resolved = plan
    if resolved === nothing
        if !isempty(session.tokens)
            resolved = worker_plan_from_tokens(
                session.tokens;
                head_workers = session.cli_session.head_workers,
            )
        elseif (head = session.cli_session.head_workers) isa Int
            resolved = WorkerPlan(head, Dict{String, Int}())
        else
            throw(ArgumentError("cluster requires plan=, session.tokens, or head_workers on the session"))
        end
    end
    head_workers = resolved.head_workers
    hosts = Tuple{String, Union{Int, Nothing}}[]
    for (host, n) in resolved.child_workers
        n > 0 && push!(hosts, (String(host), n))
    end
    return head_workers, hosts
end

"""
    cluster(f, session::DistSSHSession; plan=nothing, best_effort=false)

Launch workers from `session` (or `plan`), run `f(c)` with a [`Cluster`](@ref) handle, then
tear down every worker DistSSH started on every exit path (normal return, error, Ctrl-C).

User-added workers (for example `addprocs` inside `f`) stay connected; DistSSH logs a
one-line `@warn` when teardown skips them. The launch [`LaunchReport`](@ref) is recorded
under provenance `launch`.

Does not run a driver script, collect, heartbeat, or host-status monitoring.
Cannot nest inside an active [`drive!`](@ref) frame.
"""
function cluster(
        f::Function,
        session::DistSSHSession;
        plan::Union{Nothing, WorkerPlan} = nothing,
        best_effort::Bool = false,
    )
    _DRIVE_FRAME_DEPTH[] > 0 &&
        throw(ArgumentError("cluster cannot run inside an active drive frame"))
    pe = session.cli_session.process_env
    return with_kit_invocation_env!(pe) do
        cfg = resolve_run_job_config(; command = :drive, env = pe)
        return with_run_unsafe_options!(cfg) do
            return _drive_frame(; cli = false) do
                return _with_kit_inproc_run!(:drive) do
                    return _with_drive_process!(session.project) do
                        return _with_session_env!(session) do
                            return _with_session_remote_env!(session) do
                                apply_shared_cli_flags!(session.cli_session)
                                head_workers, hosts = _cluster_placement(session, plan)
                                proj_dir = resolve_pkg_project_dir(canonical_local_path(session.project))
                                project_root = canonical_local_path(session.project)
                                DistSSHRun._reset_run_provenance!(project_root)
                                planned_ssh = String[h[1] for h in hosts]
                                bind_map = hosts_file_bind_overrides(
                                    session.cli_session;
                                    planned_hosts = planned_ssh,
                                    command = :drive,
                                )
                                drive_atexit_cleanup = nothing
                                try
                                    successful_hosts, report = add_drive_workers!(
                                        hosts,
                                        head_workers,
                                        nothing,
                                        nothing,
                                        proj_dir,
                                        nothing,
                                        project_root;
                                        bind_overrides = bind_map,
                                    )
                                    drive_atexit_cleanup = register_worker_cleanup!(successful_hosts)
                                    DistSSHRun.capture_worker_provenance!()
                                    enforce_launch_contract!(report; best_effort)
                                    wait_for_worker_connections!(; ssh = !isempty(hosts))
                                    launched = sort!(collect(_drive_owned_worker_ids()))
                                    handle = Cluster(report, launched)
                                    return _drive_cancellable() do
                                        return f(handle)
                                    end
                                finally
                                    _teardown_drive_workers_after_run!(drive_atexit_cleanup)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
