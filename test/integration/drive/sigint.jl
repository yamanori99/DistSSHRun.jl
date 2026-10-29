using Test

# SIGINT while `main` is in `pmap`: exit 130, process state restored, and
# Distributed's atexit does not report `TaskFailedException`.

function _sigint_restore_lines(path)::Dict{String, String}
    lines = Dict{String, String}()
    isfile(path) || return lines
    for line in eachline(path)
        key, value = split(line, "="; limit = 2)
        lines[key] = value
    end
    return lines
end

function _sigint_child(proj::AbstractString; marker::AbstractString, restore::AbstractString)
    script = joinpath(proj, "job.jl")
    cp(_fixture("drive_sigint.jl"), script; force = true)
    return _kit_drive_cmd(;
        script, host_root = proj, parent_workers = 2,
        extra_env = Dict(
            "DISTSSHKIT_TEST_SIGINT_MARKER" => marker,
            "DISTSSHKIT_TEST_RESTORE_FILE" => restore,
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(proj, "keep-output"),
            "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "keep-remote",
        ),
    )
end

@testset "drive SIGINT" begin
    _mktemp_host() do proj
        marker = joinpath(proj, "main_started")
        restore = joinpath(proj, "restored.txt")
        cmd = _sigint_child(proj; marker = marker, restore = restore)
        proc, reader = _start_subprocess(cmd)
        started = timedwait(() -> isfile(marker) || !process_running(proc), 300.0; pollint = 0.5)
        @test started === :ok && isfile(marker)
        sleep(2)
        kill(proc, Base.SIGINT)
        stopped = timedwait(() -> !process_running(proc), 60.0; pollint = 0.5)
        stopped === :ok || kill(proc, Base.SIGKILL)
        wait(proc)
        combined = fetch(reader)
        if proc.exitcode != 130 || occursin("TaskFailedException", combined) || !isfile(restore)
            println(stderr, "──── drive SIGINT (exit=$(proc.exitcode)) ────")
            println(stderr, combined)
            println(stderr, "──── end drive SIGINT output ────")
        end
        @test stopped === :ok
        @test proc.exitcode == 130
        @test occursin("Interrupted. Cleaning up workers...", combined)
        @test !occursin("TaskFailedException", combined)
        lines = _sigint_restore_lines(restore)
        @test lines["active"] == repr(Base.active_project())
        @test lines["DISTRIBUTED_PROJECT_ROOT"] == repr(abspath(proj))
        @test lines["DISTRIBUTED_REMOTE_PROJECT_ROOT"] == repr("keep-remote")
        @test lines["DISTRIBUTED_OUTPUT_DIR"] == repr(joinpath(proj, "keep-output"))
        @test lines["DISTRIBUTED_RUNNER"] == "absent"
    end
end

@testset "drive second SIGINT skips cleanup" begin
    _mktemp_host() do proj
        marker = joinpath(proj, "main_started")
        restore = joinpath(proj, "restored.txt")
        cmd = _sigint_child(proj; marker = marker, restore = restore)
        out = Pipe()
        proc = run(ignorestatus(cmd), RawFD(0), out, out; wait = false)
        close(out.in)
        # `read` pulls the libuv pipe. A poll of `bytesavailable` alone stays empty.
        acc = UInt8[]
        reader = @async begin
            try
                while !eof(out)
                    append!(acc, readavailable(out))
                end
            catch
            end
            return nothing
        end
        started = timedwait(() -> isfile(marker) || !process_running(proc), 300.0; pollint = 0.5)
        @test started === :ok && isfile(marker)
        sleep(2)
        kill(proc, Base.SIGINT)
        seen = timedwait(30.0; pollint = 0.05) do
            occursin("Cleaning up workers", String(acc)) || !process_running(proc)
        end
        process_running(proc) && kill(proc, Base.SIGINT)
        stopped = timedwait(() -> !process_running(proc), 30.0; pollint = 0.05)
        stopped === :ok || kill(proc, Base.SIGKILL)
        wait(proc)
        wait(reader)
        combined = String(acc)
        if proc.exitcode != 130 || !occursin("Cleanup skipped", combined)
            println(
                stderr,
                "──── drive second SIGINT (exit=$(proc.exitcode) signal=$(proc.termsignal) seen=$(seen)) ────",
            )
            println(stderr, combined)
            println(stderr, "──── end drive second SIGINT output ────")
        end
        @test stopped === :ok
        @test proc.exitcode == 130
        @test occursin("Cleanup skipped after a second interrupt.", combined)
        @test occursin("help drive", combined)
        @test !occursin("--help", combined)
    end
end
