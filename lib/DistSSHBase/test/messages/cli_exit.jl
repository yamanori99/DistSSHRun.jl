using Test

# Builds with `Base.CANCEL_TOKEN` only. Looked up by name so 1.13 / beta1 never resolve them.
const _CLI_EXIT_CANCELS = isdefined(Base, :CANCEL_TOKEN)
_cli_exit_base(name::Symbol) = getglobal(Base, Base.inferencebarrier(name))

function _cli_exit_cancelled_scope()
    src = _cli_exit_base(:CancellationTokenSource)()
    tok = _cli_exit_base(:CancellationToken)(src)
    _cli_exit_base(:cancel!)(src, _cli_exit_base(:CANCEL_REQUEST_SAFE))
    return _cli_exit_base(:CANCEL_TOKEN) => tok
end

function _cli_exit_stderr(f)
    old = stderr
    rd, wr = redirect_stderr()
    reader = @async read(rd, String)
    result = try
        f()
    finally
        redirect_stderr(old)
        close(wr)
    end
    return result, fetch(reader)
end

@testset "cli exit" begin
    @testset "cli_parse" begin
        @test DistSSHBase.cli_parse(() -> 3) == 3
        err = try
            DistSSHBase.cli_parse(() -> throw(ArgumentError("unknown flag")))
            nothing
        catch e
            e
        end
        @test err isa DistSSHBase.CliUsageError
        @test err.msg == "unknown flag"
        @test_throws ErrorException DistSSHBase.cli_parse(() -> throw(ErrorException("later")))
        @test_throws InterruptException DistSSHBase.cli_parse(() -> throw(InterruptException()))
    end

    @testset "usage and runtime ArgumentError" begin
        reported = Ref("")
        code = DistSSHBase.with_cli_exit(
            () -> DistSSHBase.cli_parse(() -> throw(ArgumentError("unknown flag")));
            report = msg -> (reported[] = msg),
        )
        @test code == Cint(2)
        @test reported[] == "unknown flag"

        code, text = _cli_exit_stderr() do
            return DistSSHBase.with_cli_exit() do
                throw(ArgumentError("no Julia on host"))
            end
        end
        @test code == Cint(1)
        @test startswith(text, "ArgumentError: no Julia on host")
        @test !startswith(text, "Error: ")
    end

    @testset "default report and success" begin
        @test DistSSHBase.with_cli_exit(() -> Cint(0)) == Cint(0)
        @test DistSSHBase.with_cli_exit(() -> Cint(7)) == Cint(7)
        code, text = _cli_exit_stderr() do
            return DistSSHBase.with_cli_exit(() -> throw(DistSSHBase.CliUsageError("need a host")))
        end
        @test code == Cint(2)
        @test text == "Error: need a host\n"
        code, text = _cli_exit_stderr() do
            return DistSSHBase.with_cli_exit(() -> 0)
        end
        @test code == Cint(1)
        @test occursin("TypeError", text)
    end

    @testset "sigint" begin
        code, text = _cli_exit_stderr() do
            return DistSSHBase.with_cli_exit(() -> throw(InterruptException()))
        end
        @test code == Cint(130)
        @test isempty(text)
        code = DistSSHBase.with_cli_exit(
            () -> throw(InterruptException());
            interrupted = () -> Cint(0),
        )
        @test code == Cint(0)
        if _CLI_EXIT_CANCELS
            req = _cli_exit_base(:CANCEL_REQUEST_SAFE)
            code = DistSSHBase.with_cli_exit(() -> throw(req))
            @test code == Cint(130)
            saw = Ref(false)
            code = Base.ScopedValues.with(_cli_exit_cancelled_scope()) do
                return DistSSHBase.with_cli_exit(
                    () -> throw(DistSSHBase.CliUsageError("x"));
                    report = _ -> begin
                        sleep(0.02)
                        saw[] = true
                        return nothing
                    end,
                )
            end
            @test saw[]
            @test code == Cint(2)
        end
    end

    @testset "epipe" begin
        code, text = _cli_exit_stderr() do
            return DistSSHBase.with_cli_exit() do
                throw(Base.IOError("write: broken pipe (EPIPE)", Base.UV_EPIPE))
            end
        end
        @test code == Cint(141)
        @test isempty(text)
        code, text = _cli_exit_stderr() do
            return DistSSHBase.with_cli_exit() do
                throw(Base.IOError("no such file", Base.UV_ENOENT))
            end
        end
        @test code == Cint(1)
        @test occursin("IOError", text)
    end

    @testset "process sigint" begin
        proj = joinpath(@__DIR__, "..", "..")
        dir = mktempdir()
        marker = joinpath(dir, "ready")
        open(joinpath(dir, "CliExitTiny.jl"), "w") do io
            write(
                io, """
                module CliExitTiny
                using DistSSHBase
                function (@main)(::Vector{String})
                    return Int(DistSSHBase.with_cli_exit() do
                        open($(repr(marker)), "w") do ready
                            println(ready, "ready")
                        end
                        sleep(60)
                        return Cint(0)
                    end)
                end
                end
                """
            )
        end
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        env = copy(ENV)
        env["JULIA_LOAD_PATH"] = dir * ":"
        cmd = setenv(
            `$julia --startup-file=no --project=$proj -m CliExitTiny`,
            env,
        )
        proc = run(ignorestatus(cmd); wait = false)
        started = timedwait(() -> isfile(marker) || !process_running(proc), 90.0; pollint = 0.1)
        @test started === :ok && isfile(marker)
        process_running(proc) && kill(proc, Base.SIGINT)
        stopped = timedwait(() -> !process_running(proc), 30.0; pollint = 0.1)
        stopped === :ok || kill(proc, Base.SIGKILL)
        wait(proc)
        @test stopped === :ok
        @test proc.exitcode == 130
    end
end
