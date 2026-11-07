using Test

# Pseudo-TTY (`script`) versus a pipe. The TTY default is `:progress`.
# A pipe is `:verbose`. `NO_COLOR` forces the non-TTY default, so this
# runner unsets it before `julia` starts.
#
# CI / `script` typescripts look like they stack many `check` spinner rows.
# That is the byte stream: each redraw is `\r` + line + `\e[K` with no
# newline. Turning `\r` into `\n` (see `_tty_lines`) makes each frame its own
# log line. A live terminal overwrites the same row; `_tty_live_spinner_bar_peak`
# applies `\r` / `\e[K` and asserts at most one spinner bar is visible.
#
# One `script` child covers the happy path, multi-host SSH fail, preflight,
# hostinfo/pool, go success/exit 3, and a `:quiet` summary check.

@testset "TTY progress keeps up status and setup --check lines" begin
    status_cmd = _kit_cli_cmd(["up", "status", "parent", "child:host1"])
    update_cmd = _kit_cli_cmd(["up", "update", "parent", "child:host1"])
    check_cmd = _kit_cli_cmd(["setup", "--check", "child:host1"])
    check2_cmd = _kit_cli_cmd(["setup", "--check", "child:host1", "child:host2"])
    preflight_cmd = _kit_cli_cmd(["up", "status", "child:host1"])
    size_cmd = _kit_cli_cmd(["hostinfo", "parent"])
    pool_cmd = _kit_cli_cmd(["pool", "parent"])
    mktempdir() do dir
        ju = joinpath(dir, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              --version) echo 'Juliaup 1.22.7'; exit 0 ;;
              status)
                printf '%s\\n' '     *  1.13     1.13.0+0.aarch64.apple.darwin14  1.13.3'
                exit 0
                ;;
              update) exit 0 ;;
              *) exit 1 ;;
            esac
            """,
        )
        chmod(ju, 0o755)
        ssh = joinpath(dir, "ssh.jl")
        write(
            ssh,
            """
            script = length(ARGS) < 2 ? "" : ARGS[2]
            if occursin("case x in x)", script)
                m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
                m === nothing || println(m.match)
            elseif strip(script) == "echo \\\$SHELL"
                println("/bin/sh")
            elseif strip(script) == "echo ok"
                println("ok")
            elseif occursin("update", script)
                println("ok")
            else
                println("     *  1.13     1.13.0+0.aarch64.apple.darwin14  1.13.3")
            end
            """,
        )
        fail_ssh = joinpath(dir, "fail_ssh.jl")
        write(
            fail_ssh,
            """
            println(stderr, "Permission denied (publickey).")
            exit(255)
            """,
        )
        stub_bin = joinpath(dir, "stub-bin")
        mkpath(stub_bin)
        write(joinpath(stub_bin, "ssh"), "#!/bin/sh\nexit 1\n")
        write(joinpath(stub_bin, "git"), "#!/bin/sh\nexit 1\n")
        chmod(joinpath(stub_bin, "ssh"), 0o755)
        chmod(joinpath(stub_bin, "git"), 0o755)

        go_proj = joinpath(dir, "go-proj")
        mkpath(go_proj)
        write(joinpath(go_proj, "Project.toml"), "name = \"TtyGo\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"\n")
        write(joinpath(go_proj, "Manifest.toml"), "# lock\n")
        go_ok = joinpath(go_proj, "ok.jl")
        write(go_ok, "println(\"go-ok-marker\")\n")
        go_fail = joinpath(go_proj, "fail.jl")
        write(go_fail, "println(\"go-fail-marker\")\nexit(3)\n")
        go_ok_cmd = _kit_cli_cmd(["go", "-y", "parent:1", go_ok])
        go_fail_cmd = _kit_cli_cmd(["go", "-y", "parent:1", go_fail])

        empty_path = mktempdir()
        runner = joinpath(dir, "runner.sh")
        function sh_quote(s::AbstractString)
            return "'" * replace(String(s), "'" => "'\\''") * "'"
        end
        function argv_line(cmd::Cmd)
            return join(sh_quote.(String.(cmd.exec)), " ")
        end
        write(
            runner,
            """
            #!/bin/sh
            unset NO_COLOR
            unset DISTSSHKIT_QUIET
            unset DISTSSHKIT_PROGRESS
            unset DISTSSHKIT_VERBOSE
            unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
            unset DIST_SSH_KIT_CLI_INCLUDE
            export DISTSSHKIT_TEST=1
            export DISTSSHKIT_TEST_LOCAL_JULIAUP=$(sh_quote(ju))
            export DISTSSHKIT_TEST_SSH=$(sh_quote(ssh))
            export PATH=$(sh_quote(empty_path))
            export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
            unset JULIA_PROJECT
            $(argv_line(status_cmd))
            echo '___SPLIT___'
            $(argv_line(update_cmd))
            echo '___SPLIT___'
            $(argv_line(check_cmd))
            echo '___SPLIT___'
            # Local ssh/git stubs so --check reaches remote probes; fail-fast SSH double.
            export PATH=$(sh_quote(stub_bin))
            export DISTSSHKIT_TEST_SSH=$(sh_quote(fail_ssh))
            $(argv_line(check2_cmd))
            echo '___SPLIT___'
            $(argv_line(preflight_cmd))
            echo '___SPLIT___'
            export DISTSSHKIT_TEST_SSH=$(sh_quote(ssh))
            export DISTRIBUTED_PROJECT_ROOT=$(sh_quote(go_proj))
            export DISTSSHKIT_YES=1
            $(argv_line(size_cmd))
            echo '___SPLIT___'
            $(argv_line(pool_cmd))
            echo '___SPLIT___'
            $(argv_line(go_ok_cmd))
            echo '___SPLIT___'
            $(argv_line(go_fail_cmd))
            echo '___SPLIT___'
            unset DISTSSHKIT_YES
            export DISTSSHKIT_QUIET=1
            export PATH=$(sh_quote(empty_path))
            export DISTSSHKIT_TEST_SSH=$(sh_quote(ssh))
            $(argv_line(check_cmd))
            """,
        )
        chmod(runner, 0o755)

        # Hang bound only (not a performance gate). Slow CI runners can exceed
        # a minute; a stuck `script` child must still be reaped.
        hang_s = 300.0

        function capture_pty(script_path::AbstractString)
            dest = joinpath(dir, "typescript.txt")
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
            )
            env = Dict{String, String}(
                String(k) => String(v) for (k, v) in ENV if !(String(k) in skip) && !isempty(v)
            )
            proc = run(ignorestatus(setenv(cmd, env)); wait = false)
            done = timedwait(() -> !process_running(proc), hang_s; pollint = 0.5)
            if done !== :ok
                process_running(proc) && kill(proc, Base.SIGTERM)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                process_running(proc) && kill(proc, Base.SIGKILL)
                timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
                error("progress_tty script exceeded $(hang_s)s")
            end
            wait(proc)
            return isfile(dest) ? read(dest, String) : ""
        end

        t0 = time()
        pty = capture_pty(runner)
        elapsed = time() - t0
        @info "progress_tty script child wall" elapsed

        parts = split(pty, "___SPLIT___")
        @test length(parts) == 10
        status_tty = length(parts) == 10 ? parts[1] : ""
        update_tty = length(parts) == 10 ? parts[2] : ""
        check_tty = length(parts) == 10 ? parts[3] : ""
        check2_tty = length(parts) == 10 ? parts[4] : ""
        preflight_tty = length(parts) == 10 ? parts[5] : ""
        size_tty = length(parts) == 10 ? parts[6] : ""
        pool_tty = length(parts) == 10 ? parts[7] : ""
        go_ok_tty = length(parts) == 10 ? parts[8] : ""
        go_fail_tty = length(parts) == 10 ? parts[9] : ""
        quiet_tty = length(parts) == 10 ? parts[10] : ""

        status_lines = _tty_lines(status_tty)
        parent_rows = filter(l -> occursin("parent:", l) && occursin("installed", l), status_lines)
        child_rows = filter(l -> occursin("host1:", l) && occursin("installed", l), status_lines)
        @test !isempty(parent_rows)
        @test !isempty(child_rows)
        @test all(l -> !occursin("same as parent", l), parent_rows)
        @test any(l -> occursin("installed 1.13.0", l), child_rows)
        @test occursin("parent: ✓ juliaup update", _tty_strip_ansi(update_tty))
        @test occursin("host1: ✓ juliaup update", _tty_strip_ansi(update_tty))
        check_lines = _tty_lines(check_tty)
        @test !any(l -> _tty_bar_line(l) && (occursin("not found in PATH", l) || occursin("Prerequisites not met", l)), check_lines)
        @test any(l -> strip(l) == "✗ ssh not found in PATH" || strip(l) == "  ✗ ssh not found in PATH", check_lines)
        finals = filter(l -> occursin("Prerequisites not met", l), check_lines)
        @test length(finals) == 1
        @test finals[1] == "  Prerequisites not met. Fix issues above and retry."
        @test !_tty_bar_line(finals[1])
        @test !occursin("[K", finals[1])
        # Flattened log may list many `check` frames; the live screen never stacks them.
        @test count(_tty_spinner_bar_line, check_lines) >= 1
        @test _tty_live_spinner_bar_peak(check_tty) <= 1
        ssh_at = findfirst("ssh not found in PATH", check_tty)
        pre_at = findfirst("Prerequisites not met", check_tty)
        @test ssh_at !== nothing && pre_at !== nothing && first(ssh_at) < first(pre_at)
        @test !occursin("Checking prerequisites", check_tty)
        _assert_tty_progress_payload(check_tty)

        # Two-host SSH fail: each fail line names its host; reason stays on TTY.
        check2_lines = _tty_lines(check2_tty)
        @test any(l -> occursin("host1", l) && occursin("✗", l) && occursin("SSH connection failed", l), check2_lines)
        @test any(l -> occursin("host2", l) && occursin("✗", l) && occursin("SSH connection failed", l), check2_lines)
        @test any(
            l -> occursin("SSH auth/host-key failed", l) || occursin("Permission denied", l) ||
                occursin("publickey", l),
            check2_lines,
        )
        @test any(l -> occursin("Prerequisites not met", l), check2_lines)
        _assert_tty_progress_payload(check2_tty; hosts = ["host1", "host2"])

        # Preflight failure names the host and keeps a one-line reason.
        # Raw stream (before ANSI strip): a missing CLI newline glues the
        # harness marker onto the summary (`retry.___SPLIT___`). A TTY may
        # emit `\r\n` and place the color reset before that newline, so assert
        # on the stripped text with an optional CR.
        @test !occursin("retry.___SPLIT___", pty)
        preflight_plain = _tty_strip_ansi(preflight_tty)
        @test occursin(r"SSH preflight failed\. Fix connectivity, then retry\.\r?\n", preflight_plain)
        @test occursin("host1", preflight_plain)
        @test occursin("SSH preflight failed", preflight_plain)
        @test occursin("SSH auth/host-key failed", preflight_plain) ||
            occursin("Permission denied", preflight_plain) || occursin("✗", preflight_plain)
        _assert_tty_progress_payload(preflight_tty; hosts = ["host1"])

        # hostinfo / pool: tables remain (headings may be hidden at :progress).
        @test occursin("parent", _tty_strip_ansi(size_tty)) || occursin("GB", _tty_strip_ansi(size_tty)) ||
            occursin("hostinfo", lowercase(_tty_strip_ansi(size_tty)))
        @test occursin("parent", _tty_strip_ansi(pool_tty)) || occursin("pool", lowercase(_tty_strip_ansi(pool_tty))) ||
            !isempty(strip(_tty_strip_ansi(pool_tty)))

        # go success: item names parent; stdout after the final bar.
        go_ok_plain = _tty_strip_ansi(go_ok_tty)
        @test occursin("parent", go_ok_plain)
        @test occursin("go-ok-marker", go_ok_plain)
        go_ok_lines = _tty_lines(go_ok_tty)
        @test any(l -> occursin("go-ok-marker", l) && !_tty_bar_line(l), go_ok_lines)
        _assert_tty_progress_payload(go_ok_tty)

        # go exit 3: failure line names parent; no cursor-up redraw after it.
        go_fail_plain = _tty_strip_ansi(go_fail_tty)
        @test occursin("parent", go_fail_plain)
        @test occursin("exit 3", go_fail_plain) || occursin("(exit 3)", go_fail_plain)
        go_fail_lines = _tty_lines(go_fail_tty)
        @test any(l -> occursin("✗", l) && occursin("parent", l) && occursin("exit", l), go_fail_lines)
        _assert_tty_progress_payload(go_fail_tty)

        # :quiet setup --check: only the summary line on the terminal.
        quiet_lines = filter(l -> !isempty(strip(l)), _tty_lines(quiet_tty))
        # script(1) may emit a status line; ignore blank / typescript chrome.
        payload = filter(
            l -> occursin("Prerequisites", l) || occursin("✗", l) || occursin("Checking", l),
            quiet_lines,
        )
        @test length(payload) == 1
        @test occursin("Prerequisites not met", payload[1])
        @test startswith(payload[1], "  ")

        pipe_env = _child_julia_env(
            Dict(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju,
                "DISTSSHKIT_TEST_SSH" => ssh,
                "PATH" => empty_path,
            ),
        )
        delete!(pipe_env, "NO_COLOR")
        delete!(pipe_env, "DISTSSHKIT_QUIET")
        delete!(pipe_env, "DISTSSHKIT_PROGRESS")
        delete!(pipe_env, "DISTSSHKIT_VERBOSE")
        status_pipe = read(setenv(status_cmd, pipe_env), String)
        update_pipe = read(setenv(update_cmd, pipe_env), String)
        check_pipe = read(ignorestatus(setenv(check_cmd, pipe_env)), String)
        @test occursin("1.13.0", status_pipe)
        @test occursin("aarch64", status_pipe)
        @test occursin("parent:", status_pipe)
        @test occursin("host1:", status_pipe)
        @test any(l -> occursin("parent:", l) && occursin("installed", l) && !occursin("same as parent", l), _tty_lines(status_pipe))
        @test any(l -> occursin("host1:", l) && occursin("installed 1.13.0", l), _tty_lines(status_pipe))
        @test occursin("✓ juliaup update", update_pipe)
        @test !occursin("parent: ✓ juliaup", update_pipe)
        @test !occursin("host1: ✓ juliaup", update_pipe)
        @test occursin("Checking prerequisites", check_pipe)
        pipe_ssh = findfirst("ssh not found in PATH", check_pipe)
        pipe_pre = findfirst("Prerequisites not met", check_pipe)
        @test pipe_ssh !== nothing && pipe_pre !== nothing && first(pipe_ssh) < first(pipe_pre)
        pipe_finals = filter(l -> occursin("Prerequisites not met", l), _tty_lines(check_pipe))
        @test length(pipe_finals) == 1
        @test pipe_finals[1] == "  Prerequisites not met. Fix issues above and retry."

        # :verbose / pipe: host heading form for multi-host SSH fail (unchanged).
        pipe2_env = copy(pipe_env)
        pipe2_env["PATH"] = stub_bin
        pipe2_env["DISTSSHKIT_TEST_SSH"] = fail_ssh
        check2_pipe = read(ignorestatus(setenv(check2_cmd, pipe2_env)), String)
        @test occursin("host1:", check2_pipe)
        @test occursin("host2:", check2_pipe)
        @test occursin("SSH connection failed", check2_pipe)
        @test !occursin("host1: SSH connection failed", check2_pipe)
        @test !occursin("host2: SSH connection failed", check2_pipe)
    end
end
