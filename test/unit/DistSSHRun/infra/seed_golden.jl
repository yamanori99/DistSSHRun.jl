using Test
using Random

# Independent reference for seed scheme 1 (must match `launch.jl` domain tags and mixer;
# duplicated here so golden expected values are derived, not copied from package output).
const _REF_SEED_SCHEME = 1
const _REF_DOMAIN_JOB = 0x44535348_4a4f4201
const _REF_DOMAIN_WORKER = 0x44535348_574f524b
const _REF_DOMAIN_ITEM = 0x44535348_4954454d

function _ref_seed_mix(domain::UInt64, a::UInt64, b::UInt64)::UInt64
    x = xor(domain, xor(a, b * 0x9E3779B97F4A7C15))
    x = xor(x, x >> 30) * 0xBF58476D1CE4E5B9
    x = xor(x, x >> 27) * 0x94D049BB133111EB
    return xor(x, x >> 31)
end

_ref_worker_seed(job::Integer, rank::Integer) =
    _ref_seed_mix(_REF_DOMAIN_WORKER, UInt64(job), UInt64(rank))

_ref_job_domain_seed(job::Integer) =
    _ref_seed_mix(_REF_DOMAIN_JOB, UInt64(job), UInt64(_REF_SEED_SCHEME))

function _ref_job_item_seed(job::Integer, call::Integer, item::Integer)::UInt64
    tag = xor(UInt64(call), UInt64(item) * 0x9E3779B97F4A7C15)
    return _ref_seed_mix(_REF_DOMAIN_ITEM, UInt64(job), tag)
end

@testset "seed scheme 1 golden vectors" begin
    @test DistSSHRun.SEED_SCHEME == _REF_SEED_SCHEME
    job = 11
    rank1, rank2 = 1, 2
    expect_w1 = _ref_worker_seed(job, rank1)
    expect_w2 = _ref_worker_seed(job, rank2)
    @test DistSSHRun.worker_seed(job, rank1) == expect_w1
    @test DistSSHRun.worker_seed(job, rank2) == expect_w2
    @test expect_w1 == 0x96357b346c664e17
    @test expect_w2 == 0x0ab3bbd7024bd1a2

    job_wide = 0xdeadbeefcafebabe
    expect_job = _ref_job_domain_seed(job_wide)
    @test DistSSHRun.job_domain_seed(job_wide) == expect_job
    @test expect_job == 0x3a5930c90f6a3531

    s = _ref_job_item_seed(0x1234, 2, 5)
    @test DistSSHRun.job_item_seed(0x1234, 2, 5) == s
    @test s == 0x610183a31ddec8b3
    @test rand(Random.Xoshiro(s), UInt64) == 0xed967daa9d47bfc4
end
