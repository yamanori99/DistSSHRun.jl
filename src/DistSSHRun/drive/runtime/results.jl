"""
Sentinel file name for `host`.

ASCII letters, digits, `.`, and `-` are kept. Every other byte (including `_`
and `:`) becomes `+` plus two lowercase hex digits, so `a:b` and `a_b` never
collide when hosts share a collect directory.
"""
function drive_sentinel_for_host(base::AbstractString, host::AbstractString)::String
    buf = IOBuffer()
    for b in codeunits(String(host))
        if (UInt8('A') <= b <= UInt8('Z')) ||
                (UInt8('a') <= b <= UInt8('z')) ||
                (UInt8('0') <= b <= UInt8('9')) ||
                b == UInt8('.') ||
                b == UInt8('-')
            write(buf, Char(b))
        else
            print(buf, '+', string(b; base = 16, pad = 2))
        end
    end
    return string(base, "_", String(take!(buf)))
end

function place_drive_sentinels!(
        successful_hosts::Vector{String},
        script_dir::String,
        skip_collect::Bool,
        project_root::AbstractString,
    )::String
    (skip_collect || isempty(successful_hosts)) && return ""
    sentinel_name = ".drive_sentinel_$(getpid())_$(Dates.format(now(), "yyyymmddTHHMMSS"))"
    repo_ra = canonical_local_path(project_root)
    collect_roots_sentinel = distributed_collect_root_dirs(script_dir, repo_ra)
    for local_rd in collect_roots_sentinel
        _early_local = DistSSHRun.canonical_local_path(local_rd)
        _warn_collect_root_overlap(_early_local, repo_ra)
        for host in unique(successful_hosts)
            try
                remote_early = remote_layout_path(_early_local, repo_ra)
                remote_early_abs = ensure_remote_abs_path(host, remote_early)
                if remote_early_abs === nothing
                    print_warn("sentinel: cannot resolve collect root on $host")
                    continue
                end
                remote_early_abs = remote_early_abs::String
                pq = DistSSHRun._remote_shell_path_word(remote_early_abs)
                host_sentinel = drive_sentinel_for_host(sentinel_name, host)
                sn = DistSSHRun._remote_shell_path_word(joinpath(remote_early_abs, host_sentinel))
                run(
                    pipeline(
                        DistSSHRun._host_sync_remote_shell_cmd(host, "mkdir -p $pq"),
                        stdout = devnull, stderr = devnull
                    )
                )
                run(
                    pipeline(
                        DistSSHRun._host_sync_remote_shell_cmd(host, "touch $sn"),
                        stdout = devnull, stderr = devnull
                    )
                )
            catch e
                DistSSHRun._rethrow_missing_host_tool(e)
                print_warn("sentinel on $host: $(sprint(showerror, e))")
            end
        end
    end
    return sentinel_name
end

"""Turn SIGINT into `InterruptException` for the duration of `f`.

CLI `julia -m` defaults to exit-on-sigint, so Ctrl-C never reaches the
`catch InterruptException` path. Restore the script default afterward
unless this is an interactive session (`drive!` from the REPL).
"""
function _with_driver_sigint_exceptions(f)
    Base.exit_on_sigint(false)
    try
        return f()
    finally
        isinteractive() || Base.exit_on_sigint(true)
    end
end

function run_driver_script!(enable_log::Bool, drive_atexit_cleanup)
    writeln_both("Running script..."; color = :light_black)
    writeln_both("")
    call_main = () -> begin
        Base.invokelatest() do
            if isdefined(Main, :main)
                main_fn = getfield(Main, :main)
                if main_fn isa Function
                    Base.invokelatest(Base.inferencebarrier(main_fn))
                end
            end
        end
    end
    return _with_driver_sigint_exceptions() do
        try
            if enable_log && LOG_FILE_HANDLE[] !== nothing
                orig_stdout = stdout
                log_io = LOG_FILE_HANDLE[]
                linebuf = UInt8[]
                rd, wr = redirect_stdout()
                reader = @async begin
                    disable_sigint() do
                        try
                            while true
                                data = _ignore_interrupt() do
                                    return readavailable(rd)
                                end
                                data isa AbstractVector{UInt8} || continue
                                if !isempty(data)
                                    # `:verbose`: live on the terminal. `:progress`: capture
                                    # and replay after the bar so the TTY stays a single line.
                                    # `:quiet`: kit log only.
                                    if DistSSHRun.kit_output_detail()
                                        write(orig_stdout, data)
                                    elseif DistSSHRun.kit_output_progress()
                                        DistSSHRun._append_job_stdout_capture!(data)
                                    end
                                    for b in data
                                        if b == 0x0d
                                            empty!(linebuf)
                                        elseif b == 0x0a
                                            write(log_io, linebuf)
                                            write(log_io, b)
                                            flush(log_io)
                                            empty!(linebuf)
                                        else
                                            push!(linebuf, b)
                                        end
                                    end
                                end
                                # NOTE: no `yield()` here on an empty read — `readavailable` already
                                # blocks until data or close, so spin-yielding instead of letting it
                                # block starves libuv's notice of `wr` closing (observed ~30s stalls).
                                isempty(data) && (eof(rd) || !isopen(wr)) && break
                            end
                            if !isempty(linebuf)
                                write(log_io, linebuf)
                                flush(log_io)
                            end
                        catch e
                            isa(e, InterruptException) && return
                            isa(e, Base.IOError) || rethrow()
                        end
                    end
                end
                try
                    call_main()
                finally
                    flush(stdout)
                    close(wr)
                    # `rd` normally reaches EOF once `wr` closes, but local worker processes
                    # (spawned via `addprocs`) inherit our stdout fd and keep the underlying
                    # pipe open until they exit, so EOF may never arrive here. All real script
                    # output is already flushed to `rd` by this point (readavailable drains it
                    # as it's written), so a short grace period is enough before we force-close.
                    wait_ok = @async wait(reader)
                    for _ in 1:20
                        istaskdone(wait_ok) && break
                        sleep(0.05)
                    end
                    if !istaskdone(wait_ok)
                        close(rd)
                        wait(reader)
                    end
                    redirect_stdout(orig_stdout)
                end
            else
                call_main()
            end
        catch e
            if e isa InterruptException
                writeln_both("\nInterrupted. Cleaning up workers...")
                _interrupt_drive_workers!()
                drive_atexit_cleanup()
                exit(130)
            end
            rethrow()
        end
    end
end

function collect_drive_results!(
        successful_hosts::Vector{String},
        script_dir::String,
        sentinel_name::String,
        skip_collect::Bool,
        path_anchor::String,
        project_root::AbstractString,
    )
    results_dir = DistSSHRun.resolve_drive_output_dir(script_dir)

    if isempty(successful_hosts)
        writeln_both("")
        writeln_field("Results", display_path(results_dir, path_anchor))
        return true, DistSSHRun.HostRunResult[]
    end

    writeln_both("")
    if skip_collect
        writeln_both("Results saved locally (no remote collection needed).")
        writeln_field("Results", display_path(results_dir, path_anchor))
        return true, [DistSSHRun.HostRunResult(h, true) for h in unique(successful_hosts)]
    end

    collect_roots = distributed_collect_root_dirs(script_dir, canonical_local_path(project_root))
    for local_rd in collect_roots
        mkpath(local_rd)
    end
    writeln_both("Collecting results from remote hosts..."; color = :light_black)
    repo_ra = canonical_local_path(project_root)
    hosts_u = unique(successful_hosts)
    n_hosts = length(hosts_u)
    totals = zeros(Int, n_hosts)
    errs = Vector{Any}(undef, n_hosts)
    fill!(errs, nothing)
    dup_lock = ReentrantLock()
    dup_hosts = Dict{Tuple{String, String}, Vector{String}}()

    DistSSHRun.map_host_jobs(hosts_u) do i, host
        DistSSHRun._drive_host_span!(host, "collect", :running)
        total_for_host = 0
        host_err = nothing
        try
            ssh_cmd = DistSSHRun._host_sync_rsync_transport()
            rsync_bin = DistSSHRun._host_sync_rsync_argv()
            for local_rd in collect_roots
                local_abs = DistSSHRun.canonical_local_path(local_rd)
                remote_rd_collect = remote_layout_path(local_abs, repo_ra)
                remote_rd_abs = ensure_remote_abs_path(host, remote_rd_collect)
                if remote_rd_abs === nothing
                    host_err === nothing && (
                        host_err = ErrorException(
                            "cannot resolve remote collect root on $host",
                        )
                    )
                    continue
                end
                remote_rd_abs = remote_rd_abs::String
                host_sentinel = drive_sentinel_for_host(sentinel_name, host)
                remote_sentinel = joinpath(remote_rd_abs, host_sentinel)
                try
                    remote_find_raw = try
                        pq = DistSSHRun._remote_shell_path_word(remote_rd_abs)
                        sq = DistSSHRun._remote_shell_path_word(remote_sentinel)
                        # Exclude every host sentinel for this run (`base_*`), not only
                        # this host's file (shared trees otherwise collect others).
                        nq = DistSSHRun._remote_shell_path_word(sentinel_name * "_*")
                        read(
                            pipeline(
                                DistSSHRun._host_sync_remote_shell_cmd(
                                    host,
                                    "find $pq -type f -newer $sq ! -name $nq -print0",
                                );
                                stderr = devnull,
                            ),
                            String,
                        )
                    catch e
                        DistSSHRun._rethrow_missing_host_tool(e)
                        throw(
                            ErrorException(
                                "collect find -newer on $host: $(sprint(showerror, e))",
                            )
                        )
                    end
                    rroot = String(rstrip(String(remote_rd_abs), '/'))
                    rel_lines = String[]
                    for lp in _find_print0_paths(remote_find_raw)
                        rel = if startswith(lp, rroot * "/")
                            lp[(length(rroot) + 2):end]
                        else
                            continue
                        end
                        isempty(rel) && continue
                        startswith(rel, "..") && continue
                        push!(rel_lines, rel)
                    end

                    if !isempty(rel_lines)
                        uniq = unique(rel_lines)
                        lock(dup_lock) do
                            for rel in uniq
                                push!(get!(() -> String[], dup_hosts, (local_abs, rel)), host)
                            end
                        end
                        DistSSHRun._run_rsync_files_from(
                            rsync_bin,
                            ["-az", "-e", ssh_cmd],
                            string(host, ":", remote_rd_abs, "/"),
                            local_abs * "/",
                            uniq,
                        )
                        total_for_host += length(uniq)
                    end
                catch e
                    host_err === nothing && (host_err = e)
                finally
                    try
                        rq = DistSSHRun._remote_shell_path_word(remote_sentinel)
                        run(
                            pipeline(
                                DistSSHRun._host_sync_remote_shell_cmd(host, "rm -f $rq"),
                                stdout = devnull, stderr = devnull,
                            )
                        )
                    catch e
                        DistSSHRun._rethrow_missing_host_tool(e)
                    end
                end
            end
        catch e
            host_err === nothing && (host_err = e)
        finally
            DistSSHRun._drive_host_span!(
                host, "collect", host_err === nothing ? :ok : :fail,
            )
        end
        totals[i] = total_for_host
        errs[i] = host_err
    end

    dups = Pair{String, Vector{String}}[]
    for ((_, rel), hs) in dup_hosts
        u = unique(hs)
        length(u) < 2 && continue
        push!(dups, rel => u)
    end
    sort!(dups; by = first)
    if !isempty(dups)
        print_warn(
            "$(length(dups)) result path(s) came from more than one host. The last transfer remains.\n",
        )
        if DistSSHRun.kit_host_jobs() > 1
            print_warn("With DISTSSHKIT_JOBS>1, which host's bytes remain is unspecified.\n")
        end
        for (rel, hs) in dups[1:min(end, 10)]
            print_warn("  $rel ($(join(hs, ", ")))\n")
        end
    end

    collect_ok = true
    host_results = Vector{DistSSHRun.HostRunResult}(undef, n_hosts)
    for i in 1:n_hosts
        host = hosts_u[i]
        total_for_host = totals[i]
        host_err = errs[i]
        write_both("  $host: ")
        if host_err !== nothing
            collect_ok = false
            print_progress_err("✗ ($host_err)")
        elseif total_for_host == 0
            print_progress_warn("(nothing to collect)")
        else
            print_ok("✓ ($total_for_host file$(total_for_host == 1 ? "" : "s"))")
        end
        writeln_both("")
        host_results[i] = DistSSHRun.HostRunResult(host, host_err === nothing, host_err)
    end
    coll_disp = join(
        (display_path(String(p), path_anchor) for p in collect_roots),
        ", ",
    )
    writeln_field("Results", coll_disp)
    return collect_ok, host_results
end
