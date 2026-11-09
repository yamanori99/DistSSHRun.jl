using Test

# Pseudo-TTY (`script`) coverage for `drive` and `ride` at the TTY default
# (`:progress`). Reuses `test/support/progress_tty.jl`. Setup/up/go TTY cases
# stay in `integration/setup/progress_tty.jl`.

@testset "TTY progress keeps drive and ride lines" begin
    function sh_quote(s::AbstractString)
        return "'" * replace(String(s), "'" => "'\\''") * "'"
    end
    function argv_line(cmd::Cmd)
        return join(sh_quote.(String.(cmd.exec)), " ")
    end
    function write_runner(path::AbstractString, body::AbstractString)
        write(path, "#!/bin/sh\n" * body)
        chmod(path, 0o755)
        return path
    end
    function pid_alive(pid::Integer)::Bool
        Sys.isunix() || return false
        return ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(0)) == 0
    end

    hang_s = 300.0

    @testset "expect observes prompt in typescript before reply" begin
        if _test_skip_unless_unix()
            mktempdir() do dir
                runner = joinpath(dir, "prompt.sh")
                write_runner(
                    runner,
                    """
                    printf 'DISTSSHKIT_PROMPT>'
                    read line
                    printf 'DISTSSHKIT_GOT:%s\\n' "\$line"
                    """,
                )
                t0 = time()
                pty = _tty_expect_script(
                    runner;
                    typescript = joinpath(dir, "prompt_typescript.txt"),
                    expect = "DISTSSHKIT_PROMPT>",
                    reply = "pong\n",
                    hang_s = 30.0,
                )
                @info "harness expect flush wall" elapsed = (time() - t0)
                @test occursin("DISTSSHKIT_PROMPT>", pty)
                @test occursin("DISTSSHKIT_GOT:pong", pty)
                prompt_at = findfirst("DISTSSHKIT_PROMPT>", pty)
                got_at = findfirst("DISTSSHKIT_GOT:pong", pty)
                @test prompt_at !== nothing && got_at !== nothing
                @test first(prompt_at) < first(got_at)
            end
        end
    end

    @testset "capture timeout reaps descendants" begin
        if _test_skip_unless_unix()
            mktempdir() do dir
                alive = joinpath(dir, "DSR_TTY_HANG_ALIVE")
                gpid_file = joinpath(dir, "grandchild.pid")
                ready = joinpath(dir, "ready")
                hang = joinpath(dir, "hang.sh")
                write_runner(
                    hang,
                    """
                    alive=$(sh_quote(alive))
                    gpidf=$(sh_quote(gpid_file))
                    ready=$(sh_quote(ready))
                    touch "\$alive"
                    # Nested sh grandchild in the same detached process group.
                    sh -c 'while [ -f "\$1" ]; do sleep 0.1; done' _ "\$alive" &
                    echo \$! > "\$gpidf"
                    touch "\$ready"
                    while [ -f "\$alive" ]; do sleep 0.1; done
                    """,
                )
                # Unrelated process: not in the capture group; must survive cleanup.
                unrelated = run(ignorestatus(`sleep 60`); wait = false)
                try
                    # Hang bound is generous relative to startup, not a perf gate.
                    # Grandchild must exist before the helper times out and kills.
                    err_box = Ref{Any}(nothing)
                    task = @async begin
                        try
                            _tty_capture_script(
                                hang;
                                typescript = joinpath(dir, "hang_typescript.txt"),
                                hang_s = 8.0,
                            )
                        catch e
                            err_box[] = e
                        end
                    end
                    for _ in 1:100
                        isfile(ready) && break
                        sleep(0.05)
                    end
                    @test isfile(ready)
                    @test isfile(gpid_file)
                    gpid = parse(Int, strip(read(gpid_file, String)))
                    @test pid_alive(gpid)
                    # Wait out the hang bound; cleanup runs in the helper (and finally).
                    wait(task)
                    err = err_box[]
                    @test err isa ErrorException
                    @test occursin("exceeded", sprint(showerror, err))
                    for _ in 1:60
                        pid_alive(gpid) || break
                        sleep(0.05)
                    end
                    @test !pid_alive(gpid)
                    @test process_running(unrelated)
                finally
                    rm(alive; force = true)
                    process_running(unrelated) && kill(unrelated, Base.SIGKILL)
                    try
                        wait(unrelated)
                    catch
                    end
                end
            end
        end
    end

    @testset "drive success failure quiet and verbose" begin
        mktempdir() do dir
            proj = joinpath(dir, "drive-proj")
            mkpath(proj)
            _write_host_project!(proj, "TtyDrive")
            ok_script = joinpath(proj, "ok.jl")
            cp(_fixture("drive_local_smoke.jl"), ok_script; force = true)
            fail_script = joinpath(proj, "fail.jl")
            write(fail_script, "error(\"DISTSSHKIT_RUNNER_BOOM\")\n")

            # `--no-log` + `:progress`: release the live bar, then print live.
            drive_ok = _kit_drive_cmd(;
                script = ok_script,
                host_root = proj,
                parent_workers = 2,
            )
            drive_fail = _kit_drive_cmd(;
                script = fail_script,
                host_root = proj,
                parent_workers = 2,
            )
            @test occursin("--no-log", join(String.(drive_ok.exec), " "))

            runner = joinpath(dir, "drive_runner.sh")
            write_runner(
                runner,
                """
                unset NO_COLOR
                unset DISTSSHKIT_QUIET
                unset DISTSSHKIT_PROGRESS
                unset DISTSSHKIT_VERBOSE
                unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
                unset DIST_SSH_KIT_CLI_INCLUDE
                export DISTSSHKIT_TEST=1
                export DISTSSHKIT_YES=1
                export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
                unset JULIA_PROJECT
                export DISTRIBUTED_PROJECT_ROOT=$(sh_quote(proj))
                export DISTRIBUTED_INIT_DELAY_SEC=0
                $(argv_line(drive_ok))
                echo '___SPLIT___'
                $(argv_line(drive_fail))
                echo '___SPLIT___'
                export DISTSSHKIT_QUIET=1
                $(argv_line(drive_fail))
                echo '___SPLIT___'
                unset DISTSSHKIT_QUIET
                export DISTSSHKIT_VERBOSE=1
                $(argv_line(drive_ok))
                """,
            )

            t0 = time()
            pty = _tty_capture_script(
                runner;
                typescript = joinpath(dir, "drive_typescript.txt"),
                hang_s = hang_s,
            )
            elapsed = time() - t0
            @info "drive progress_tty script child wall" elapsed

            parts = split(pty, "___SPLIT___")
            @test length(parts) == 4
            ok_tty = length(parts) == 4 ? parts[1] : ""
            fail_tty = length(parts) == 4 ? parts[2] : ""
            quiet_tty = length(parts) == 4 ? parts[3] : ""
            verbose_tty = length(parts) == 4 ? parts[4] : ""

            ok_plain = _tty_strip_ansi(ok_tty)
            @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK", ok_plain)
            @test occursin("parent", ok_plain) || occursin("nw=2", ok_plain)
            ok_lines = _tty_lines(ok_tty)
            smoke_lines = filter(
                l -> occursin("DISTSSHKIT_RUNNER_SMOKE_OK", l) && !_tty_bar_line(l),
                ok_lines,
            )
            @test !isempty(smoke_lines)
            # Live after release: smoke is not glued mid-bar. A finished bar
            # below the marker is allowed (not a cursor-up overwrite).
            smoke_at = findfirst("DISTSSHKIT_RUNNER_SMOKE_OK", ok_tty)
            @test smoke_at !== nothing
            before_smoke = SubString(ok_tty, 1, first(smoke_at) - 1)
            @test occursin('━', before_smoke) || occursin('╺', before_smoke) ||
                any(c -> occursin(c, before_smoke), "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            @test !occursin(r"[━╺⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][^\n]*DISTSSHKIT_RUNNER_SMOKE_OK", ok_tty)
            _assert_tty_progress_payload(ok_tty)

            fail_plain = _tty_strip_ansi(fail_tty)
            @test occursin("DISTSSHKIT_RUNNER_BOOM", fail_plain)
            fail_lines = _tty_lines(fail_tty)
            @test any(
                l -> occursin("DISTSSHKIT_RUNNER_BOOM", l) && !_tty_bar_line(l),
                fail_lines,
            )
            @test !occursin("retry.___SPLIT___", pty)
            _assert_tty_progress_payload(fail_tty)

            quiet_plain = _tty_strip_ansi(quiet_tty)
            @test occursin("DISTSSHKIT_RUNNER_BOOM", quiet_plain)
            quiet_lines = _tty_lines(quiet_tty)
            @test !any(_tty_spinner_bar_line, quiet_lines)
            @test length(filter(!isempty ∘ strip, quiet_lines)) <=
                length(filter(!isempty ∘ strip, fail_lines))

            # Explicit verbose: live detail path (unchanged by the --no-log fix).
            verbose_plain = _tty_strip_ansi(verbose_tty)
            @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK", verbose_plain)
            @test occursin("Running script", verbose_plain)
            verbose_lines = _tty_lines(verbose_tty)
            @test any(
                l -> occursin("DISTSSHKIT_RUNNER_SMOKE_OK", l) && !_tty_bar_line(l),
                verbose_lines,
            )
            # Verbose shows the running step before the smoke marker.
            run_at = findfirst("Running script", verbose_tty)
            vsmoke_at = findfirst("DISTSSHKIT_RUNNER_SMOKE_OK", verbose_tty)
            @test run_at !== nothing && vsmoke_at !== nothing
            @test first(run_at) < first(vsmoke_at)
        end
    end

    @testset "ride success and failure" begin
        mktempdir() do dir
            proj = joinpath(dir, "ride-proj")
            mkpath(proj)
            _write_host_project!(proj, "TtyRide")
            od_ok = joinpath(dir, "ride-out-ok")
            od_fail = joinpath(dir, "ride-out-fail")
            mkpath(od_ok)
            mkpath(od_fail)
            marker = joinpath(od_ok, "ride_ok_marker.txt")
            ok_script = joinpath(proj, "ok.jl")
            # Ride rewrites `map`; write a unique success marker from the body.
            write(
                ok_script,
                """
                map(1:2) do x
                    if x == 1
                        open($(repr(marker)), "w") do io
                            println(io, "DISTSSHKIT_RIDE_OK_MARKER")
                        end
                    end
                    x
                end
                """,
            )
            fail_script = joinpath(proj, "fail.jl")
            write(fail_script, "map(x -> error(\"DISTSSHKIT_RIDE_BOOM\"), 1:2)\n")

            ride_ok = _kit_cli_cmd(
                [
                    "ride", "-y", "--no-spi-check",
                    "--output-dir", od_ok, "parent:1", ok_script,
                ]
            )
            ride_fail = _kit_cli_cmd(
                [
                    "ride", "-y", "--no-spi-check",
                    "--output-dir", od_fail, "parent:1", fail_script,
                ]
            )

            runner = joinpath(dir, "ride_runner.sh")
            write_runner(
                runner,
                """
                unset NO_COLOR
                unset DISTSSHKIT_QUIET
                unset DISTSSHKIT_PROGRESS
                unset DISTSSHKIT_VERBOSE
                unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
                unset DIST_SSH_KIT_CLI_INCLUDE
                export DISTSSHKIT_TEST=1
                export DISTSSHKIT_YES=1
                export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
                unset JULIA_PROJECT
                export DISTRIBUTED_PROJECT_ROOT=$(sh_quote(proj))
                export DISTRIBUTED_INIT_DELAY_SEC=0
                $(argv_line(ride_ok))
                echo '___SPLIT___'
                $(argv_line(ride_fail))
                """,
            )

            t0 = time()
            pty = _tty_capture_script(
                runner;
                typescript = joinpath(dir, "ride_typescript.txt"),
                hang_s = hang_s,
            )
            elapsed = time() - t0
            @info "ride progress_tty script child wall" elapsed

            parts = split(pty, "___SPLIT___")
            @test length(parts) == 2
            ok_tty = length(parts) == 2 ? parts[1] : ""
            fail_tty = length(parts) == 2 ? parts[2] : ""

            # Success is observed via the rewritten map side effect + progress done.
            @test isfile(marker)
            @test occursin("DISTSSHKIT_RIDE_OK_MARKER", read(marker, String))
            _assert_kit_progress_done(od_ok; kind = :ride)
            ok_plain = _tty_strip_ansi(ok_tty)
            @test !isempty(strip(ok_plain))
            # `:progress` success hides `print_ride`; the finished bar must not
            # cursor-up over earlier payload.
            _assert_tty_progress_payload(ok_tty)

            fail_plain = _tty_strip_ansi(fail_tty)
            @test occursin("DISTSSHKIT_RIDE_BOOM", fail_plain)
            fail_lines = _tty_lines(fail_tty)
            @test any(
                l -> occursin("DISTSSHKIT_RIDE_BOOM", l) && !_tty_bar_line(l),
                fail_lines,
            )
            _assert_tty_progress_payload(fail_tty)
        end
    end

    @testset "drive --no-log stderr redirect stays off stdout" begin
        mktempdir() do dir
            proj = joinpath(dir, "stdio-proj")
            mkpath(proj)
            _write_host_project!(proj, "TtyStdio")
            script = joinpath(proj, "stdio.jl")
            write(
                script,
                """
                println(stdout, "DISTSSHKIT_STDOUT_MARK")
                println(stderr, "DISTSSHKIT_STDERR_MARK")
                """,
            )
            out_file = joinpath(dir, "stdout.txt")
            err_file = joinpath(dir, "stderr.txt")
            drive_cmd = _kit_drive_cmd(;
                script = script,
                host_root = proj,
                parent_workers = 1,
            )
            @test occursin("--no-log", join(String.(drive_cmd.exec), " "))
            runner = joinpath(dir, "stdio_runner.sh")
            write_runner(
                runner,
                """
                unset NO_COLOR
                unset DISTSSHKIT_QUIET
                unset DISTSSHKIT_VERBOSE
                unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
                unset DIST_SSH_KIT_CLI_INCLUDE
                export DISTSSHKIT_TEST=1
                export DISTSSHKIT_YES=1
                export DISTSSHKIT_PROGRESS=1
                export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
                unset JULIA_PROJECT
                export DISTRIBUTED_PROJECT_ROOT=$(sh_quote(proj))
                export DISTRIBUTED_INIT_DELAY_SEC=0
                $(argv_line(drive_cmd)) >$(sh_quote(out_file)) 2>$(sh_quote(err_file))
                """,
            )
            t0 = time()
            _tty_capture_script(
                runner;
                typescript = joinpath(dir, "stdio_typescript.txt"),
                hang_s = hang_s,
            )
            @info "drive stdio redirect progress_tty wall" elapsed = (time() - t0)
            @test isfile(out_file) && isfile(err_file)
            out = read(out_file, String)
            err = read(err_file, String)
            @test occursin("DISTSSHKIT_STDOUT_MARK", out)
            @test occursin("DISTSSHKIT_STDERR_MARK", err)
            @test !occursin("DISTSSHKIT_STDERR_MARK", out)
        end
    end

    @testset "drive --no-log interactive prompt before stdin" begin
        if _test_skip_unless_unix()
            mktempdir() do dir
                proj = joinpath(dir, "prompt-proj")
                mkpath(proj)
                _write_host_project!(proj, "TtyPrompt")
                script = joinpath(proj, "prompt.jl")
                write(
                    script,
                    """
                    print("DISTSSHKIT_PROMPT>")
                    flush(stdout)
                    line = readline(stdin)
                    println("DISTSSHKIT_GOT:", line)
                    """,
                )
                drive_cmd = _kit_drive_cmd(;
                    script = script,
                    host_root = proj,
                    parent_workers = 1,
                )
                runner = joinpath(dir, "prompt_runner.sh")
                write_runner(
                    runner,
                    """
                    unset NO_COLOR
                    unset DISTSSHKIT_QUIET
                    unset DISTSSHKIT_PROGRESS
                    unset DISTSSHKIT_VERBOSE
                    unset DISTSSHKIT_CLI_SUBCOMMAND_DONE
                    unset DIST_SSH_KIT_CLI_INCLUDE
                    export DISTSSHKIT_TEST=1
                    export DISTSSHKIT_YES=1
                    export JULIA_LOAD_PATH=$(sh_quote(_child_load_path()))
                    unset JULIA_PROJECT
                    export DISTRIBUTED_PROJECT_ROOT=$(sh_quote(proj))
                    export DISTRIBUTED_INIT_DELAY_SEC=0
                    $(argv_line(drive_cmd))
                    """,
                )
                t0 = time()
                pty = _tty_expect_script(
                    runner;
                    typescript = joinpath(dir, "prompt_typescript.txt"),
                    expect = "DISTSSHKIT_PROMPT>",
                    reply = "pong\n",
                    hang_s = hang_s,
                )
                @info "drive interactive progress_tty wall" elapsed = (time() - t0)
                plain = _tty_strip_ansi(pty)
                @test occursin("DISTSSHKIT_PROMPT>", plain)
                @test occursin("DISTSSHKIT_GOT:pong", plain)
                prompt_at = findfirst("DISTSSHKIT_PROMPT>", pty)
                got_at = findfirst("DISTSSHKIT_GOT:pong", pty)
                @test prompt_at !== nothing && got_at !== nothing
                @test first(prompt_at) < first(got_at)
                @test !occursin(r"[━╺⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][^\n]*DISTSSHKIT_PROMPT>", pty)
                # Visible model: prompt is its own payload line, not bar-glued.
                prompt_lines = filter(
                    l -> occursin("DISTSSHKIT_PROMPT>", l) && !_tty_bar_line(l),
                    _tty_lines(pty),
                )
                @test !isempty(prompt_lines)
            end
        end
    end
end
