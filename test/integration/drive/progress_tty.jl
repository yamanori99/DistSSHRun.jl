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

    hang_s = 300.0

    @testset "drive success failure and quiet" begin
        mktempdir() do dir
            proj = joinpath(dir, "drive-proj")
            mkpath(proj)
            _write_host_project!(proj, "TtyDrive")
            ok_script = joinpath(proj, "ok.jl")
            cp(_fixture("drive_local_smoke.jl"), ok_script; force = true)
            fail_script = joinpath(proj, "fail.jl")
            write(fail_script, "error(\"DISTSSHKIT_RUNNER_BOOM\")\n")

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
            @test length(parts) == 3
            ok_tty = length(parts) == 3 ? parts[1] : ""
            fail_tty = length(parts) == 3 ? parts[2] : ""
            quiet_tty = length(parts) == 3 ? parts[3] : ""

            ok_plain = _tty_strip_ansi(ok_tty)
            @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK", ok_plain)
            @test occursin("parent", ok_plain) || occursin("nw=2", ok_plain)
            ok_lines = _tty_lines(ok_tty)
            @test any(l -> occursin("DISTSSHKIT_RUNNER_SMOKE_OK", l) && !_tty_bar_line(l), ok_lines)
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
            # Quiet keeps the boom; progress chrome (spinner glyphs) stays off.
            quiet_lines = _tty_lines(quiet_tty)
            @test !any(_tty_spinner_bar_line, quiet_lines)
            # `:progress` failure path may draw a bar; quiet must not be denser.
            @test length(filter(!isempty ∘ strip, quiet_lines)) <=
                length(filter(!isempty ∘ strip, fail_lines))
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
            ok_script = joinpath(proj, "ok.jl")
            write(ok_script, "map(identity, 1:2)\n")
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

            ok_plain = _tty_strip_ansi(ok_tty)
            # Ride success may hide the result table at `:progress`; the bar
            # must still finish without cursor-up over a prior payload.
            @test !isempty(strip(ok_plain)) || occursin("ride", lowercase(ok_plain))
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
end
