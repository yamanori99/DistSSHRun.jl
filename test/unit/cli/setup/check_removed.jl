using Test

@testset "setup check removal" begin
    function _setup_capture(args)
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv("DISTSSH_INTERNAL_CLI_SUBCOMMAND_DONE" => "") do
                    redirect_stdin(devnull) do
                        redirect_stdout(out_io) do
                            redirect_stderr(err_io) do
                                DistSSHRun.setup(args)
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

    for argv in (["check", "host1"], ["--check", "host1"])
        let (code, out, err) = _setup_capture(argv)
            shown = out * err
            @test code == 2
            @test occursin("setup check was removed in 0.2.0", shown)
            @test occursin("doctor --deploy", shown)
        end
    end

    msg = DistSSHRun.setup_check_removed_message()
    @test occursin("doctor --deploy", msg)
end
