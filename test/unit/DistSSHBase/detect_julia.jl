using Test

if !isdefined(@__MODULE__, :B)
    const B = DistSSHRun.DistSSHBase
end

# SSH failure throws and is not cached. A host with no Julia returns nothing.
# Kit CLI session is not required.

@testset "detect_julia_path" begin
    host = "detect-ssh-fail.test"
    _with_tempdir() do state_dir
        withenv(merge(_fake_setup_remote_env(state_dir), Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))...) do
            B.clear_detect_julia_path_cache!(host)
            try
                err = try
                    B.detect_julia_path(host)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("ssh-copy-id", err.msg)
                err2 = try
                    B.detect_julia_path(host)
                    nothing
                catch e
                    e
                end
                @test err2 isa ArgumentError
                @test !haskey(B._DETECT_JULIA_PATH_CACHE, host)
            finally
                B.clear_detect_julia_path_cache!(host)
            end
        end
    end
    _with_tempdir() do state_dir
        withenv(_fake_setup_remote_env(state_dir)...) do
            B.clear_detect_julia_path_cache!("detect-no-julia.test")
            try
                @test B.detect_julia_path("detect-no-julia.test") === nothing
            finally
                B.clear_detect_julia_path_cache!("detect-no-julia.test")
            end
        end
    end
end
