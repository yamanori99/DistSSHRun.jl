using Test

const _STATUS_ROW = "*  1.13  1.13.0+0.aarch64.apple.darwin14  1.13.3"

@testset "up status summary" begin
    line = DistSSHRun.juliaup_status_summary_line(
        "worker",
        [_STATUS_ROW];
        parent_patch = "1.13.3",
    )
    @test occursin("worker", line)
    @test occursin("channel 1.13", line)
    @test occursin("installed 1.13.0", line)
    @test occursin("behind parent 1.13.3", line)
    @test occursin("available 1.13.3", line)
    @test !occursin("aarch64", line)
    @test DistSSHRun.DistSSHUp._juliaup_patch_from_status(_STATUS_ROW) == "1.13.0"

    same = DistSSHRun.juliaup_status_summary_line(
        "parent",
        [_STATUS_ROW];
        parent_patch = "1.13.0",
    )
    @test occursin("same as parent", same)
    @test !occursin("behind", same)

    ahead = DistSSHRun.juliaup_status_summary_line(
        "worker",
        ["* release 1.13.4+0.x 1.13.4"];
        parent_patch = "1.13.3",
    )
    @test occursin("ahead of parent 1.13.3", ahead)
    @test occursin("channel release", ahead)
    @test !occursin("+0", ahead)

    unknown = DistSSHRun.juliaup_status_summary_line(
        "worker",
        ["* 1.13"];
        parent_patch = "-",
    )
    @test occursin("installed -", unknown)
    @test occursin("parent unknown", unknown)
    @test occursin("available none", unknown)

    none = DistSSHRun.juliaup_status_summary_line("worker", String[]; parent_patch = "1.13.3")
    @test occursin("(none)", none)

    mktempdir() do d
        ju = joinpath(d, "juliaup")
        write(
            ju,
            """
            #!/bin/sh
            case "\$1" in
              status) printf '%s\\n' '$_STATUS_ROW' ;;
              *) exit 1 ;;
            esac
            """,
        )
        chmod(ju, 0o755)
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
            progress_out, progress = with_kit_verbosity(:progress) do
                _capture_stdio() do _, _
                    return DistSSHRun.juliaup_verb_remotes(["parent"]; verb = "status")
                end
            end
            @test progress.succeeded == 1
            @test progress.failed == 0
            @test occursin("installed 1.13.0", progress_out)
            @test occursin("same as parent", progress_out)
            @test occursin("available 1.13.3", progress_out)
            @test !occursin("aarch64", progress_out)

            verbose_out, verbose = with_kit_verbosity(:verbose) do
                _capture_stdio() do _, _
                    return DistSSHRun.juliaup_verb_remotes(["parent"]; verb = "status")
                end
            end
            @test verbose.succeeded == 1
            @test occursin("installed 1.13.0", verbose_out)
            @test occursin("aarch64", verbose_out)
        end
        missing = joinpath(d, "missing")
        withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => missing) do
            failed_out, failed = with_kit_verbosity(:progress) do
                _capture_stdio() do _, _
                    return DistSSHRun.juliaup_verb_remotes(["parent"]; verb = "status")
                end
            end
            @test failed.succeeded == 0
            @test failed.failed == 1
            @test occursin("juliaup not found", failed_out)
        end
    end
end
