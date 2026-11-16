using Test
using Random

@testset "seed scheme 1 golden vectors" begin
    @test DistSSHRun.SEED_SCHEME == 1
    @test DistSSHRun.worker_seed(11, 1) == 0x96409df7efcc15b7
    @test DistSSHRun.worker_seed(11, 2) == 0x0ab80c20d5393762
    @test DistSSHRun.job_domain_seed(0xdeadbeefcafebabe) == 0x3a5930c90f6a3531
    s = DistSSHRun.job_item_seed(0x1234, 2, 5)
    @test s == 0x610183a31ddec8b3
    @test rand(Random.Xoshiro(s), UInt64) == 0xed967daa9d47bfc4
end