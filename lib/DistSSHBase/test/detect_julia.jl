using Test

let _BASE = DistSSHBase

    # SSH failure throws and is not cached. A host with no Julia returns nothing.
    # Kit CLI session is not required.

    @testset "detect_julia_path" begin
        host = "detect-ssh-fail.test"
        _with_tempdir() do state_dir
            withenv(merge(_fake_setup_remote_env(state_dir), Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))...) do
                _BASE.clear_detect_julia_path_cache!(host)
                try
                    err = try
                        _BASE.detect_julia_path(host)
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("ssh-copy-id", err.msg)
                    err2 = try
                        _BASE.detect_julia_path(host)
                        nothing
                    catch e
                        e
                    end
                    @test err2 isa ArgumentError
                    @test !haskey(_BASE._DETECT_JULIA_PATH_CACHE, host)
                finally
                    _BASE.clear_detect_julia_path_cache!(host)
                end
            end
        end
        _with_tempdir() do state_dir
            withenv(_fake_setup_remote_env(state_dir)...) do
                _BASE.clear_detect_julia_path_cache!("detect-no-julia.test")
                try
                    @test _BASE.detect_julia_path("detect-no-julia.test") === nothing
                finally
                    _BASE.clear_detect_julia_path_cache!("detect-no-julia.test")
                end
            end
        end
    end
end
