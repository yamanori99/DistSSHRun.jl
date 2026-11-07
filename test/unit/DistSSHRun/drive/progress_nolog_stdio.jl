using Test

# `--no-log` + `:progress` must keep driver stdout/stderr live on their original
# destinations (no whole-`main` capture). Log-enabled capture/replay is separate.
#
# `function main` binds a constant in Main. Leave that binding in this process
# and later `drive!` fixtures (`integration/drive/api.jl`) warn-overwrite it.
# Run the cases in a child so parent `Main` never gains `main`.

module DSRNoLogStdioHook
    const hook = Ref{Any}(nothing)
end

function _with_nolog_driver_hook(body, hook::Function)
    prev = DSRNoLogStdioHook.hook[]
    DSRNoLogStdioHook.hook[] = hook
    try
        return body()
    finally
        DSRNoLogStdioHook.hook[] = prev
    end
end

function _nolog_stdio_spawn_child()
    test_root = _test_root()
    this_file = joinpath(test_root, "unit", "DistSSHRun", "drive", "progress_nolog_stdio.jl")
    isdefined(Main, :TEST_PROJECT) || error("progress_nolog_stdio: TEST_PROJECT is not set")
    project = String(TEST_PROJECT::AbstractString)
    hang_s = 120.0
    julia = _julia_exe()
    bootstrap = """
    const TEST_PROJECT = $(repr(project))
    using Test
    using DistSSHRun
    include($(repr(joinpath(test_root, "support.jl"))))
    DistSSHRun.set_kit_verbosity!(:progress)
    include($(repr(this_file)))
    """
    cmd = `$(_julia_cmd_for(julia)) --startup-file=no --project=$project -e $bootstrap`
    env = Dict{String, String}(
        String(k) => String(v) for (k, v) in ENV if !isempty(v)
    )
    env["DISTSSHKIT_NOLOG_STDIO_CHILD"] = "1"
    proc, reader = _start_subprocess(setenv(cmd, env))
    try
        done = timedwait(() -> !process_running(proc), hang_s; pollint = 0.2)
        if done !== :ok
            process_running(proc) && kill(proc, Base.SIGTERM)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            process_running(proc) && kill(proc, Base.SIGKILL)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            error("progress_nolog_stdio child exceeded $(hang_s)s")
        end
        wait(proc)
        return proc, fetch(reader)
    finally
        if process_running(proc)
            kill(proc, Base.SIGKILL)
            timedwait(() -> !process_running(proc), 5.0; pollint = 0.2)
            try
                wait(proc)
            catch
            end
        end
    end
end

function _nolog_stdio_cases()
    return @testset "drive --no-log progress stdio" begin
        # `function main` binds a constant in Main; reassigning it errors on 1.13+.
        # Install a one-shot dispatcher once and swap the hook per case.
        if !isdefined(Main, :main)
            Core.eval(
                Main,
                quote
                    function main()
                        h = DSRNoLogStdioHook.hook[]
                        h isa Function || return nothing
                        return h()
                    end
                end,
            )
        end

        @testset "stdout and stderr stay on original destinations" begin
            _with_nolog_driver_hook(
                () -> begin
                    println(stdout, "DISTSSHKIT_STDOUT_MARK")
                    println(stderr, "DISTSSHKIT_STDERR_MARK")
                    return nothing
                end,
            ) do
                DistSSHRun._reset_job_stdout_capture!()
                with_kit_verbosity(:progress) do
                    DistSSHRun.kit_progress_begin!("drive"; steps = 2, kind = :drive)
                    mktemp() do out_path, out_io
                        mktemp() do err_path, err_io
                            redirect_stdout(out_io) do
                                redirect_stderr(err_io) do
                                    DistSSHRun.run_driver_script!(false)
                                end
                            end
                            flush(out_io)
                            flush(err_io)
                            out = read(out_path, String)
                            err = read(err_path, String)
                            @test out == "DISTSSHKIT_STDOUT_MARK\n"
                            @test err == "DISTSSHKIT_STDERR_MARK\n"
                            @test occursin("DISTSSHKIT_STDOUT_MARK", out)
                            @test occursin("DISTSSHKIT_STDERR_MARK", err)
                            @test !occursin("DISTSSHKIT_STDERR_MARK", out)
                            captured = String(take!(DistSSHRun.KIT_JOB_STDOUT[]))
                            DistSSHRun.KIT_JOB_STDOUT[] = IOBuffer()
                            @test !occursin("DISTSSHKIT_STDOUT_MARK", captured)
                            @test !occursin("DISTSSHKIT_STDERR_MARK", captured)
                        end
                    end
                end
            end
        end

        @testset "prompt is visible before stdin is supplied" begin
            _with_nolog_driver_hook(
                () -> begin
                    print(stdout, "DISTSSHKIT_PROMPT>")
                    flush(stdout)
                    line = readline(stdin)
                    println(stdout, "DISTSSHKIT_GOT:", line)
                    return nothing
                end,
            ) do
                DistSSHRun._reset_job_stdout_capture!()
                with_kit_verbosity(:progress) do
                    DistSSHRun.kit_progress_begin!("drive"; steps = 2, kind = :drive)
                    pin = Pipe()
                    Base.link_pipe!(pin)
                    mktemp() do out_path, out_io
                        redirect_stdout(out_io) do
                            redirect_stdin(pin) do
                                feeder = @async begin
                                    try
                                        t0 = time()
                                        while true
                                            flush(out_io)
                                            if occursin("DISTSSHKIT_PROMPT>", read(out_path, String))
                                                write(pin.in, "yes-please\n")
                                                flush(pin.in)
                                                return nothing
                                            end
                                            (time() - t0) > 30 &&
                                                error("timeout waiting for live prompt")
                                            sleep(0.05)
                                        end
                                    finally
                                        close(pin.in)
                                    end
                                end
                                DistSSHRun.run_driver_script!(false)
                                wait(feeder)
                            end
                        end
                        flush(out_io)
                        out = read(out_path, String)
                        @test out == "DISTSSHKIT_PROMPT>DISTSSHKIT_GOT:yes-please\n"
                        @test occursin("DISTSSHKIT_PROMPT>", out)
                        @test occursin("DISTSSHKIT_GOT:yes-please", out)
                        prompt_at = findfirst("DISTSSHKIT_PROMPT>", out)
                        got_at = findfirst("DISTSSHKIT_GOT:yes-please", out)
                        @test prompt_at !== nothing && got_at !== nothing
                        @test first(prompt_at) < first(got_at)
                    end
                end
            end
        end

        @testset "large driver output is not retained in the job capture buffer" begin
            nlines = 5_000
            _with_nolog_driver_hook(
                () -> begin
                    for i in 1:nlines
                        println(stdout, "DISTSSHKIT_BULK_", i, "_", "x"^64)
                    end
                    return nothing
                end,
            ) do
                DistSSHRun._reset_job_stdout_capture!()
                with_kit_verbosity(:progress) do
                    DistSSHRun.kit_progress_begin!("drive"; steps = 2, kind = :drive)
                    mktemp() do out_path, out_io
                        redirect_stdout(out_io) do
                            DistSSHRun.run_driver_script!(false)
                        end
                        flush(out_io)
                        out = read(out_path, String)
                        @test occursin("DISTSSHKIT_BULK_1_", out)
                        @test occursin("DISTSSHKIT_BULK_$(nlines)_", out)
                        # Structural: --no-log progress must not feed the job buffer.
                        @test position(DistSSHRun.KIT_JOB_STDOUT[]) == 0
                    end
                end
            end
        end

        @testset "stdio restored after driver exception" begin
            _with_nolog_driver_hook(
                () -> begin
                    println(stdout, "DISTSSHKIT_BEFORE_BOOM")
                    error("DISTSSHKIT_DRIVER_BOOM")
                end,
            ) do
                DistSSHRun._reset_job_stdout_capture!()
                with_kit_verbosity(:progress) do
                    DistSSHRun.kit_progress_begin!("drive"; steps = 2, kind = :drive)
                    orig_out = stdout
                    orig_err = stderr
                    mktemp() do out_path, out_io
                        err = try
                            redirect_stdout(out_io) do
                                DistSSHRun.run_driver_script!(false)
                            end
                            nothing
                        catch e
                            e
                        end
                        flush(out_io)
                        @test err isa ErrorException
                        @test occursin("DISTSSHKIT_DRIVER_BOOM", sprint(showerror, err))
                        @test stdout === orig_out
                        @test stderr === orig_err
                        @test read(out_path, String) == "DISTSSHKIT_BEFORE_BOOM\n"
                    end
                end
            end
        end

        @testset "log-enabled progress still captures stdout only" begin
            # Shared enable_log path: stdout may be captured; stderr stays live.
            _with_nolog_driver_hook(
                () -> begin
                    println(stdout, "DISTSSHKIT_LOG_STDOUT")
                    println(stderr, "DISTSSHKIT_LOG_STDERR")
                    return nothing
                end,
            ) do
                DistSSHRun._reset_job_stdout_capture!()
                with_kit_verbosity(:progress) do
                    DistSSHRun.kit_progress_begin!("drive"; steps = 2, kind = :drive)
                    mktemp() do _, log_io
                        prev = DistSSHRun.LOG_FILE_HANDLE[]
                        try
                            DistSSHRun.LOG_FILE_HANDLE[] = log_io
                            mktemp() do out_path, out_io
                                mktemp() do err_path, err_io
                                    redirect_stdout(out_io) do
                                        redirect_stderr(err_io) do
                                            DistSSHRun.run_driver_script!(true)
                                        end
                                    end
                                    flush(out_io)
                                    flush(err_io)
                                    flush(log_io)
                                    out = read(out_path, String)
                                    err = read(err_path, String)
                                    @test !occursin("DISTSSHKIT_LOG_STDOUT", out)
                                    @test occursin("DISTSSHKIT_LOG_STDERR", err)
                                    @test !occursin("DISTSSHKIT_LOG_STDERR", out)
                                    captured = String(take!(DistSSHRun.KIT_JOB_STDOUT[]))
                                    DistSSHRun.KIT_JOB_STDOUT[] = IOBuffer()
                                    @test occursin("DISTSSHKIT_LOG_STDOUT", captured)
                                    @test !occursin("DISTSSHKIT_LOG_STDERR", captured)
                                end
                            end
                        finally
                            DistSSHRun.LOG_FILE_HANDLE[] = prev
                        end
                    end
                end
            end
        end

        @testset "verbose and quiet --no-log stay live without job capture" begin
            for v in (:verbose, :quiet)
                _with_nolog_driver_hook(
                    () -> begin
                        println(stdout, "DISTSSHKIT_MODE_STDOUT")
                        println(stderr, "DISTSSHKIT_MODE_STDERR")
                        return nothing
                    end,
                ) do
                    DistSSHRun._reset_job_stdout_capture!()
                    with_kit_verbosity(v) do
                        mktemp() do out_path, out_io
                            mktemp() do err_path, err_io
                                redirect_stdout(out_io) do
                                    redirect_stderr(err_io) do
                                        DistSSHRun.run_driver_script!(false)
                                    end
                                end
                                flush(out_io)
                                flush(err_io)
                                out = read(out_path, String)
                                err = read(err_path, String)
                                @test occursin("DISTSSHKIT_MODE_STDOUT", out)
                                @test occursin("DISTSSHKIT_MODE_STDERR", err)
                                @test !occursin("DISTSSHKIT_MODE_STDERR", out)
                                @test position(DistSSHRun.KIT_JOB_STDOUT[]) == 0
                            end
                        end
                    end
                end
            end
        end
    end
end

if get(ENV, "DISTSSHKIT_NOLOG_STDIO_CHILD", "") != "1"
    @testset "drive --no-log progress stdio" begin
        proc, combined = _nolog_stdio_spawn_child()
        print(combined)
        @test success(proc)
        @test occursin("drive --no-log progress stdio", combined)
        @test !isdefined(Main, :main)
    end
else
    _nolog_stdio_cases()
end
