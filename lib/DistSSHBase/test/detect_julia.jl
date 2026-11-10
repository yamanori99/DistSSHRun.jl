using Test

let _BASE = DistSSHBase

    # SSH failure throws and is not cached. A miss (no Julia) is not cached either.
    # Kit CLI session is not required.

    @testset "detect_julia_path" begin
        _with_tempdir() do state_dir
            withenv(merge(_fake_setup_remote_env(state_dir), Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))...) do
                _BASE.clear_detect_julia_path_cache!("detect-ssh-fail.test")
                try
                    err = try
                        _BASE.detect_julia_path("detect-ssh-fail.test")
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("ssh-copy-id", err.msg)
                    err2 = try
                        _BASE.detect_julia_path("detect-ssh-fail.test")
                        nothing
                    catch e
                        e
                    end
                    @test err2 isa ArgumentError
                    @test !haskey(_BASE._DETECT_JULIA_PATH_CACHE, "detect-ssh-fail.test")
                finally
                    _BASE.clear_detect_julia_path_cache!("detect-ssh-fail.test")
                end
            end
        end
        _with_tempdir() do state_dir
            withenv(_fake_setup_remote_env(state_dir)...) do
                _BASE.clear_detect_julia_path_cache!("detect-no-julia.test")
                try
                    @test _BASE.detect_julia_path("detect-no-julia.test") === nothing
                    @test !haskey(_BASE._DETECT_JULIA_PATH_CACHE, "detect-no-julia.test")
                finally
                    _BASE.clear_detect_julia_path_cache!("detect-no-julia.test")
                end
            end
        end
        _with_tempdir() do state_dir
            withenv(_fake_setup_remote_env(state_dir)...) do
                _BASE.clear_detect_julia_path_cache!("detect-julia-retry.test")
                try
                    @test _BASE.detect_julia_path("detect-julia-retry.test") === nothing
                    @test !haskey(_BASE._DETECT_JULIA_PATH_CACHE, "detect-julia-retry.test")
                    withenv("DISTSSHKIT_TEST_JULIA_WHICH" => "/usr/bin/julia") do
                        got = _BASE.detect_julia_path("detect-julia-retry.test")
                        @test got == "/usr/bin/julia"
                        @test _BASE._DETECT_JULIA_PATH_CACHE["detect-julia-retry.test"] == "/usr/bin/julia"
                    end
                finally
                    _BASE.clear_detect_julia_path_cache!("detect-julia-retry.test")
                end
            end
        end
    end
end
