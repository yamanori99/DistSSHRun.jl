using Test

@testset "doctor CLI entry" begin
    function _doctor_capture(args)
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv("DISTSSH_CLI_SUBCOMMAND_DONE" => "") do
                    redirect_stdin(devnull) do
                        redirect_stdout(out_io) do
                            redirect_stderr(err_io) do
                                DistSSHRun.run_doctor(args)
                            end
                        end
                    end
                end
                flush(out_io)
                flush(err_io)
                return code, read(out_path, String), read(err_path, String)
            end
        end
    end

    let (code, out, err) = _doctor_capture(["--help"])
        shown = out * err
        @test code == 0
        @test occursin("--deploy", shown)
        @test occursin("doctor", shown)
    end

    let (code, out, err) = _doctor_capture(["host1"])
        shown = out * err
        @test code == 2
        @test occursin("doctor needs --deploy", shown)
    end

    let (code, out, err) = _doctor_capture(["--not-a-flag", "host1"])
        @test code == 1
        @test occursin("unknown doctor option", out * err)
    end
end
