using Test

@testset "session env restore" begin
    function _env_pair(key::AbstractString)
        return get(ENV, key, nothing)
    end

    @testset "_with_session_env!" begin
        saved_root = _env_pair("DISTRIBUTED_PROJECT_ROOT")
        try
            _with_tempdir() do tmp
                withenv("DISTRIBUTED_PROJECT_ROOT" => nothing) do
                    session = DistSSHRun.DistSSHSession(project = tmp, workers = String[], quiet = true)
                    DistSSHRun._with_session_env!(session) do
                        @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
                    end
                    @test !haskey(ENV, "DISTRIBUTED_PROJECT_ROOT")
                end
                withenv("DISTRIBUTED_PROJECT_ROOT" => "/caller/keep") do
                    session = DistSSHRun.DistSSHSession(project = tmp, workers = String[], quiet = true)
                    DistSSHRun._with_session_env!(session) do
                        @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
                    end
                    @test ENV["DISTRIBUTED_PROJECT_ROOT"] == "/caller/keep"
                end
                withenv("DISTRIBUTED_PROJECT_ROOT" => nothing) do
                    session = DistSSHRun.DistSSHSession(project = tmp, workers = String[], quiet = true)
                    err = try
                        DistSSHRun._with_session_env!(session) do
                            @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
                            error("force-fail")
                        end
                    catch e
                        e
                    end
                    @test err isa ErrorException
                    @test !haskey(ENV, "DISTRIBUTED_PROJECT_ROOT")
                end
            end
        finally
            if saved_root === nothing
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            else
                ENV["DISTRIBUTED_PROJECT_ROOT"] = saved_root
            end
        end
    end

    @testset "pool!" begin
        saved_root = _env_pair("DISTRIBUTED_PROJECT_ROOT")
        try
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"PoolEnvRestore\"\n")
                withenv("DISTRIBUTED_PROJECT_ROOT" => "/before/pool") do
                    session = DistSSHRun.DistSSHSession(project = proj, workers = String[])
                    DistSSHRun.pool!(session)
                    @test ENV["DISTRIBUTED_PROJECT_ROOT"] == "/before/pool"
                end
                withenv("DISTRIBUTED_PROJECT_ROOT" => nothing) do
                    session = DistSSHRun.DistSSHSession(project = proj, workers = String[])
                    err = try
                        DistSSHRun.setup!(session, :ship_tree)
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test !haskey(ENV, "DISTRIBUTED_PROJECT_ROOT")
                end
            end
        finally
            if saved_root === nothing
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            else
                ENV["DISTRIBUTED_PROJECT_ROOT"] = saved_root
            end
        end
    end

    @testset "kit CLI wrappers restore DISTSSH_CLI_SUBCOMMAND_DONE" begin
        saved_done = _env_pair("DISTSSH_CLI_SUBCOMMAND_DONE")
        saved_root = _env_pair("DISTRIBUTED_PROJECT_ROOT")
        try
            withenv("DISTSSH_CLI_SUBCOMMAND_DONE" => "/before", "DISTRIBUTED_PROJECT_ROOT" => nothing) do
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.run_pool(["-h"])
                    end
                end
                @test ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] == "/before"
            end
            withenv("DISTRIBUTED_PROJECT_ROOT" => nothing) do
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.run_hostinfo(["-h"])
                    end
                end
                @test !haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.run_pool(["--nope"])
                    end
                end
                @test !haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
            end
            withenv("DISTRIBUTED_PROJECT_ROOT" => nothing) do
                status = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.run_pool(["-h"])
                    end
                end
                @test status == 0
                ver = DistSSHRun.dist_ssh_kit_version()
                code = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.main(["--version"])
                    end
                end
                @test code == 0
                mktemp() do out_path, out_io
                    code2 = redirect_stdout(out_io) do
                        redirect_stderr(devnull) do
                            DistSSHRun.main(["--version"])
                        end
                    end
                    flush(out_io)
                    out = read(out_path, String)
                    @test code2 == 0
                    @test occursin("DistSSHRun $ver", out)
                end
                @test !haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
            end
        finally
            if saved_done === nothing
                delete!(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
            else
                ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] = saved_done
            end
            if saved_root === nothing
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            else
                ENV["DISTRIBUTED_PROJECT_ROOT"] = saved_root
            end
        end
    end
end
