using Test

# Oracle: staged with_kit recipes under a temp host — square_file CSV bytes,
# square_echo needle, pipeline_square CSV. Not SSH (test/e2e.jl).
# One `Pkg.develop`, then a copy of that tree per demo. The three children
# run together and do not share `output/square_results.csv`.

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
        echo_host = joinpath(tmp, "echo")
        pipe_host = joinpath(tmp, "pipe")
        cp(staged, echo_host)
        cp(staged, pipe_host)

        function drive_cmd(host, script_name)
            script = joinpath(host, "demos", "with_kit", script_name)
            cmd = _kit_cli_cmd(
                ["drive", "-y", "parent:1", "--no-log", script, "--n", "3"];
                julia = julia,
                project = kit_root,
            )
            return setenv(
                cmd,
                _child_julia_env(
                    Dict(
                        "DISTRIBUTED_INIT_DELAY_SEC" => "0",
                        "DISTRIBUTED_PROJECT_ROOT" => host,
                    ),
                ),
            )
        end

        pipe_script = joinpath(pipe_host, "demos", "with_kit", "pipeline_square.jl")
        pipe_cmd = setenv(
            Cmd([julia, "--startup-file=no", "--project=$pipe_host", pipe_script, "--n", "3"]),
            _child_julia_env(
                Dict(
                    "DISTRIBUTED_INIT_DELAY_SEC" => "0",
                    "DISTRIBUTED_PROJECT_ROOT" => pipe_host,
                ),
            ),
        )
        (file_proc, file_out), (echo_proc, echo_out), (pipe_proc, pipe_out) = _run_subprocesses(
            [
                drive_cmd(staged, "square_file.jl"),
                drive_cmd(echo_host, "square_echo.jl"),
                pipe_cmd,
            ]
        )

        _assert_proc_ok(file_proc, file_out; label = "square_file demo")
        @test occursin("Results:", file_out)
        file_out_dir = joinpath(staged, "demos", "with_kit", "output")
        file_csv = joinpath(file_out_dir, "square_results.csv")
        @test isfile(file_csv)
        @test read(file_csv, String) == expected
        @test occursin("wrote ", file_out)
        _assert_kit_progress_done(file_out_dir; kind = :drive)

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
