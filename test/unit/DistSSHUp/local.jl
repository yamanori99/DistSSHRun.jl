using Test

let _UP = DistSSHRun.DistSSHUp
    @testset "juliaup align local" begin
        mktempdir() do d
            fake = _write_aligned_fake_juliaup(d)
            withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => fake.ju) do
                r = _UP.juliaup_align_local!(fake.ch)
                @test !r.changed
                @test _UP.julia_version_mismatch_kind(VERSION, r.ver) != :minor
            end
        end
    end
end
