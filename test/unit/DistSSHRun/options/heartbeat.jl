using Test
using DistSSHRun

@testset "drive heartbeat policy" begin
    @testset "parse_drive_args env opt-in requires deadline at runtime" begin
        parsed = DistSSHRun.parse_drive_args(
            String["--unsafe-master-silence-exit", "parent:1", "script.jl"],
        )
        @test parsed.unsafe_master_silence_exit
        @test_throws ArgumentError begin
            DistSSHRun.resolve_drive_heartbeat_policy(self_exit = parsed.unsafe_master_silence_exit)
        end
    end

    @testset "provenance heartbeat table" begin
        DistSSHRun._reset_run_provenance!(pwd())
        pol = DistSSHRun.resolve_drive_heartbeat_policy(
            env = Dict(
                "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "11",
            ),
            self_exit = true,
        )
        DistSSHRun.record_heartbeat_provenance!(pol)
        prov = DistSSHRun.assemble_provenance()
        @test prov["heartbeat"]["self_exit"] == true
        @test prov["heartbeat"]["deadline_sec"] == 11.0
        pol_off = DistSSHRun.resolve_drive_heartbeat_policy(self_exit = false)
        DistSSHRun.record_heartbeat_provenance!(pol_off)
        prov2 = DistSSHRun.assemble_provenance()
        @test prov2["heartbeat"]["self_exit"] == false
        @test !haskey(prov2["heartbeat"], "deadline_sec")
    end
end
