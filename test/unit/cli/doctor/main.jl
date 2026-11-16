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

    help_text = DistSSHRun.doctor_help_text()

    let (code, help_out, help_err) = _doctor_capture(["--help"])
        @test code == 0
        @test help_out == help_text
        @test !occursin("DistSSHKit doctor", help_err)
    end

    let (code, bare_out, bare_err) = _doctor_capture(String[])
        @test code == 2
        @test bare_err == help_text
        @test isempty(strip(bare_out))
    end

    let (code, out, err) = _doctor_capture(["host1"])
        shown = out * err
        @test code == 2
        @test occursin("doctor needs --deploy", shown)
        @test occursin("doctor --deploy", shown)
        @test occursin("--run-id ID", shown)
    end

    let (code, out, err) = _doctor_capture(["--not-a-flag", "host1"])
        shown = out * err
        @test code == 2
        @test occursin("unknown doctor option", shown)
    end
end
