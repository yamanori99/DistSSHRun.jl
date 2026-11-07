# Shared TTY (`script`) capture helpers for `:progress` assertions.
# Guard: JETLS may analyze this file both via support.jl and as an include leaf.

if !isdefined(Main, :_tty_strip_ansi)
    function _tty_strip_ansi(s::AbstractString)
        return replace(String(s), r"\e\[[0-9;?]*[A-Za-z]" => "")
    end

    function _tty_lines(s::AbstractString)
        # Log-style view: each `\r` redraw becomes its own line (CI look).
        return split(_tty_strip_ansi(replace(String(s), "\r" => "\n")), '\n')
    end

    function _tty_bar_line(line::AbstractString)
        return occursin("[K", line) ||
            occursin("━", line) ||
            occursin("╺", line) ||
            any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    end

    function _tty_spinner_bar_line(line::AbstractString)
        return any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏") &&
            (occursin("━", line) || occursin("╺", line))
    end

    function _tty_payload_line(line::AbstractString)
        return occursin("✗", line) ||
            occursin("!", line) ||
            occursin("Prerequisites", line) ||
            occursin("complete", line) ||
            occursin("SSH preflight failed", line) ||
            occursin("exit", line) ||
            occursin("ERROR:", line) ||
            occursin("DISTSSHKIT_RUNNER_BOOM", line) ||
            occursin("DISTSSHKIT_RIDE_BOOM", line) ||
            occursin("DISTSSHKIT_E2E_REMOTE_FAIL", line) ||
            occursin("DISTSSHKIT_RUNNER_SMOKE_OK", line)
    end

    function _tty_fail_or_warn_line(line::AbstractString)
        s = String(line)
        return startswith(s, "  ✗") || startswith(s, "  !") ||
            startswith(s, "  Prerequisites")
    end

    # Live TTY: `\r` returns to column 0; CSI K after that clears the row.
    # Snapshot after each erase / newline and track how many spinner bars
    # would be on screen at once (must stay ≤ 1).
    function _tty_live_spinner_bar_peak(raw::AbstractString)
        finished = String[]
        cur = Ref("")
        at_home = false
        peak = Ref(0)
        function note!()
            rows = _tty_strip_ansi.(
                isempty(cur[]) ? finished : vcat(finished, String[cur[]]),
            )
            peak[] = max(peak[], count(_tty_spinner_bar_line, rows))
            return nothing
        end
        i = firstindex(raw)
        while i <= lastindex(raw)
            ch = raw[i]
            if ch == '\r'
                at_home = true
                i = nextind(raw, i)
            elseif ch == '\n'
                push!(finished, cur[])
                cur[] = ""
                at_home = false
                note!()
                i = nextind(raw, i)
            elseif ch == '\e'
                j = nextind(raw, i)
                if j <= lastindex(raw) && raw[j] == '['
                    k = nextind(raw, j)
                    while k <= lastindex(raw) && !isletter(raw[k])
                        k = nextind(raw, k)
                    end
                    k <= lastindex(raw) || break
                    if raw[k] == 'K'
                        if at_home
                            cur[] = ""
                            at_home = false
                        end
                        note!()
                    end
                    i = nextind(raw, k)
                else
                    i = j
                end
            else
                if at_home
                    cur[] = ""
                    at_home = false
                end
                cur[] *= string(ch)
                i = nextind(raw, i)
            end
        end
        note!()
        return peak[]
    end

    # Assert payload lines are not glued to the bar and have no post-payload redraw.
    function _assert_tty_progress_payload(raw::AbstractString; hosts::Vector{String} = String[])
        lines = _tty_lines(raw)
        for line in lines
            if _tty_payload_line(line)
                @test !_tty_bar_line(line)
                @test !occursin("[K", line)
                @test !any(c -> occursin(c, line), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
                @test !occursin("━", line)
            end
            if _tty_fail_or_warn_line(line)
                @test startswith(line, "  ")
            end
        end
        # No cursor-up bar redraw after the last payload line in the byte stream.
        payload_keys = (
            "✗",
            "!",
            "Prerequisites",
            "complete",
            "SSH preflight failed",
            "exit",
            "ERROR:",
            "DISTSSHKIT_RUNNER_BOOM",
            "DISTSSHKIT_RIDE_BOOM",
            "DISTSSHKIT_E2E_REMOTE_FAIL",
            "DISTSSHKIT_RUNNER_SMOKE_OK",
        )
        last_payload = nothing
        for key in payload_keys
            at = findlast(key, raw)
            at === nothing && continue
            if last_payload === nothing || first(at) > first(last_payload)
                last_payload = at
            end
        end
        if last_payload !== nothing
            after = SubString(raw, nextind(raw, last(last_payload)))
            @test !occursin(r"\e\[[0-9]*A", after)
        end
        if length(hosts) > 1
            fail_lines = filter(l -> occursin("✗", l) && !_tty_bar_line(l), lines)
            for host in hosts
                @test any(l -> occursin(host, l), fail_lines)
            end
            # Host name only in the Time table is a failure (already covered by
            # requiring each host on a fail line above).
        end
        return nothing
    end

    # Signal the detached capture process group (script + nested sh/julia).
    # `detach=true` puts the child in its own group; `-pid` stays inside that
    # group and must not be used on a non-detached process.
    function _tty_kill_capture_tree!(proc::Base.Process)
        process_running(proc) || return nothing
        pid = Int(getpid(proc))
        if Sys.isunix()
            ccall(:kill, Cint, (Cint, Cint), Cint(-pid), Base.SIGTERM)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            if process_running(proc)
                ccall(:kill, Cint, (Cint, Cint), Cint(-pid), Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            end
        else
            kill(proc, Base.SIGTERM)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            process_running(proc) && kill(proc, Base.SIGKILL)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
        end
        process_running(proc) || try
            wait(proc)
        catch
        end
        return nothing
    end

    # Run `script_path` under `script(1)` and return the raw typescript.
    # Hang bound only (not a performance gate). The child is detached into its
    # own process group so timeout cleanup can reap nested sh/julia too.
    function _tty_capture_script(
            script_path::AbstractString;
            typescript::AbstractString,
            hang_s::Real = 300.0,
            columns::Integer = 120,
            lines::Integer = 40,
            extra_env::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
        )::String
        dest = String(typescript)
        rm(dest; force = true)
        cmd = if Sys.isapple()
            `script -q $dest /bin/sh $script_path`
        else
            `script -q -c $script_path $dest`
        end
        skip = (
            "NO_COLOR",
            "JULIA_LOAD_PATH",
            "JULIA_PROJECT",
            "DISTSSHKIT_CLI_SUBCOMMAND_DONE",
            "DIST_SSH_KIT_CLI_INCLUDE",
            "DISTSSHKIT_QUIET",
            "DISTSSHKIT_PROGRESS",
            "DISTSSHKIT_VERBOSE",
            "COLUMNS",
            "LINES",
        )
        env = Dict{String, String}(
            String(k) => String(v) for (k, v) in ENV if !(String(k) in skip) && !isempty(v)
        )
        env["COLUMNS"] = string(Int(columns))
        env["LINES"] = string(Int(lines))
        for (k, v) in extra_env
            env[String(k)] = String(v)
        end
        # New process group: timeout uses `kill(-pid, …)` scoped to this tree.
        # Bind `proc` once (no later reassignment) so the try/finally close does
        # not box it; `run` on a plain Cmd returns `Base.Process`.
        launched = Cmd(setenv(cmd, env); detach = true)
        proc = run(ignorestatus(launched); wait = false)::Base.Process
        timed_out = false
        try
            done = timedwait(() -> !process_running(proc), Float64(hang_s); pollint = 0.5)
            if done !== :ok
                timed_out = true
                _tty_kill_capture_tree!(proc)
                error("progress_tty script exceeded $(hang_s)s")
            end
            wait(proc)
            return isfile(dest) ? read(dest, String) : ""
        finally
            if process_running(proc)
                _tty_kill_capture_tree!(proc)
            elseif timed_out
                # Ensure the Process is reaped after a group kill.
                try
                    wait(proc)
                catch
                end
            end
        end
    end

    # Run under `script(1)` with a writable stdin pipe (not detached: detach
    # closes stdin). Poll the typescript until `expect` appears, then write
    # `reply`. Input is never supplied before the prompt is observed.
    function _tty_expect_script(
            script_path::AbstractString;
            typescript::AbstractString,
            expect::AbstractString,
            reply::AbstractString,
            hang_s::Real = 300.0,
            columns::Integer = 120,
            lines::Integer = 40,
            extra_env::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
        )::String
        dest = String(typescript)
        rm(dest; force = true)
        cmd = if Sys.isapple()
            `script -q $dest /bin/sh $script_path`
        else
            `script -q -c $script_path $dest`
        end
        skip = (
            "NO_COLOR",
            "JULIA_LOAD_PATH",
            "JULIA_PROJECT",
            "DISTSSHKIT_CLI_SUBCOMMAND_DONE",
            "DIST_SSH_KIT_CLI_INCLUDE",
            "DISTSSHKIT_QUIET",
            "DISTSSHKIT_PROGRESS",
            "DISTSSHKIT_VERBOSE",
            "COLUMNS",
            "LINES",
        )
        env = Dict{String, String}(
            String(k) => String(v) for (k, v) in ENV if !(String(k) in skip) && !isempty(v)
        )
        env["COLUMNS"] = string(Int(columns))
        env["LINES"] = string(Int(lines))
        for (k, v) in extra_env
            env[String(k)] = String(v)
        end
        pin = Pipe()
        Base.link_pipe!(pin)
        # `run(cmd, stdin, stdout, stderr)` — same shape as `_start_subprocess`.
        # Typescript is polled from disk; child stdio need not be inherited.
        proc = run(
            ignorestatus(setenv(cmd, env)),
            pin,
            Base.DevNull(),
            Base.DevNull();
            wait = false,
        )::Base.Process
        close(pin.out)
        replied = Ref(false)
        timed_out = false
        try
            t0 = time()
            while true
                if isfile(dest) && occursin(expect, read(dest, String))
                    write(pin.in, reply)
                    flush(pin.in)
                    close(pin.in)
                    replied[] = true
                    break
                end
                if !process_running(proc)
                    close(pin.in)
                    error("progress_tty expect: process exited before $(repr(expect))")
                end
                if (time() - t0) > Float64(hang_s)
                    timed_out = true
                    try
                        close(pin.in)
                    catch
                    end
                    process_running(proc) && kill(proc, Base.SIGTERM)
                    timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                    process_running(proc) && kill(proc, Base.SIGKILL)
                    timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                    error("progress_tty expect exceeded $(hang_s)s waiting for $(repr(expect))")
                end
                sleep(0.05)
            end
            done = timedwait(() -> !process_running(proc), Float64(hang_s); pollint = 0.5)
            if done !== :ok
                timed_out = true
                process_running(proc) && kill(proc, Base.SIGTERM)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                process_running(proc) && kill(proc, Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                error("progress_tty expect exceeded $(hang_s)s after reply")
            end
            wait(proc)
            replied[] || error("progress_tty expect: reply was not sent")
            return isfile(dest) ? read(dest, String) : ""
        finally
            try
                isopen(pin.in) && close(pin.in)
            catch
            end
            if process_running(proc)
                kill(proc, Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            elseif timed_out
                try
                    wait(proc)
                catch
                end
            end
        end
    end
end
