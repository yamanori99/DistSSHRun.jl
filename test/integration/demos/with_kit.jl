using Test

# Oracle: staged with_kit recipes under a temp host — square_file CSV bytes,
# square_echo needle, pipeline_square CSV. Not SSH (test/e2e.jl).
# One `Pkg.develop` on `staged`. `square_file` runs on that tree. The other two
# demos run on copies, so the three children do not share `output/square_results.csv`.

@testset "with_kit drive local" begin
    kit_root = _kit_root()
    julia = _julia_exe()
    expected = join(
        [
            "param,result",
            ("$n,$(n^2)" for n in 1:3)...,
        ], '\n'
    ) * '\n'

    _mktemp_host() do tmp
        staged = joinpath(tmp, "staged")
        mkpath(joinpath(staged, "demos"))
        _stage_with_kit_demos!(joinpath(staged, "demos"), kit_root)
        file_host = staged
        echo_host = joinpath(tmp, "echo")
        pipe_host = joinpath(tmp, "pipe")
        cp(staged, echo_host)
        cp(staged, pipe_host)

        function drive_cmd(host, script_name)
            return _kit_drive_cmd(;
                julia = julia,
                kit_root = kit_root,
                script = joinpath(host, "demos", "with_kit", script_name),
                script_args = ["--n", "3"],
                host_root = host,
            )
        end

        pipe_script = joinpath(pipe_host, "demos", "with_kit", "pipeline_square.jl")
        pipe_cmd = setenv(
            Cmd([julia, "--startup-file=no", "--project=$pipe_host", pipe_script, "--n", "3"]),
            _drive_host_env(pipe_host),
        )
        (file_proc, file_out), (echo_proc, echo_out), (pipe_proc, pipe_out) = _run_subprocesses(
            [
                drive_cmd(file_host, "square_file.jl"),
                drive_cmd(echo_host, "square_echo.jl"),
                pipe_cmd,
            ]
        )

        _assert_proc_ok(file_proc, file_out; label = "square_file demo")
        @test occursin("Results:", file_out)
        file_out_dir = joinpath(file_host, "demos", "with_kit", "output")
        file_csv = joinpath(file_out_dir, "square_results.csv")
        @test isfile(file_csv)
        @test read(file_csv, String) == expected
        @test occursin("wrote ", file_out)
        _assert_kit_progress_done(file_out_dir; kind = :drive)
        file_proc2, file_out2 = _run_subprocess(drive_cmd(file_host, "square_file.jl"))
        _assert_proc_ok(file_proc2, file_out2; label = "square_file demo second run")
        @test read(file_csv, String) == expected
        csvs = String[]
        for (dir, _, files) in walkdir(file_out_dir)
            "square_results.csv" in files && push!(csvs, joinpath(dir, "square_results.csv"))
        end
        @test length(csvs) >= 2

        _assert_proc_ok(echo_proc, echo_out; label = "square_echo demo")
        @test occursin("param^2:", echo_out)
        _assert_kit_progress_done(joinpath(echo_host, "demos", "with_kit", "output"); kind = :drive)

        _assert_proc_ok(pipe_proc, pipe_out; label = "pipeline_square demo")
        @test occursin("pipeline! ok", pipe_out)
        pipe_out_dir = joinpath(pipe_host, "demos", "with_kit", "output")
        @test isfile(joinpath(pipe_out_dir, "square_results.csv"))
        @test read(joinpath(pipe_out_dir, "square_results.csv"), String) == expected
        _assert_kit_progress_done(pipe_out_dir; kind = :drive)
    end
end
