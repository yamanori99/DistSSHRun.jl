using Test

@testset "placement messages" begin
    host = DistSSHRun.kit_head_host_label()
    line_w = DistSSHRun.format_kit_head_placement(2, "workers")
    line_s = DistSSHRun.format_kit_head_placement(3, "slots")
    @test startswith(line_w, "head: $host (")
    @test occursin("2 workers", line_w)
    @test occursin("3 slots", line_s)
    @test occursin("head-slots", DistSSHRun.zero_placement_usage_error(:go; surface = :cli))
    @test occursin("head-workers", DistSSHRun.zero_placement_usage_error(:drive; surface = :cli))
    @test_throws ArgumentError DistSSHRun.assert_go_argv_no_head_workers!(["--head-workers", "1", "job.jl"])
    let (n, imp) = DistSSHRun.resolve_go_head_slots(String[], nothing)
        @test n == 1
        @test imp
        @test occursin("no hosts given", DistSSHRun.format_kit_go_implicit_head_slot())
    end
    @test DistSSHRun.resolve_go_head_slots(String[], 2) == (2, false)
    @test DistSSHRun.resolve_go_head_slots(["1*h"], nothing) == (0, false)
    @test DistSSHRun.resolve_go_head_slots(String[], 0) == (0, false)
end
