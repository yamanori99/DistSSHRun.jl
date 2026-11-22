using Test

@testset "session env restore" begin
    function _restore_env!(key::AbstractString, saved::Union{Nothing, String})
        if saved === nothing
            delete!(ENV, key)
        else
            ENV[key] = saved
        end
        return nothing
    end

    @testset "_with_session_env!" begin
        saved_root = haskey(ENV, "DISTRIBUTED_PROJECT_ROOT") ? ENV["DISTRIBUTED_PROJECT_ROOT"] : nothing
        try
            _with_tempdir() do tmp
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
                session = DistSSHRun.DistSSHSession(project = tmp, workers = String[], quiet = true)
                DistSSHRun._with_session_env!(session) do
                    @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
                end
                @test !haskey(ENV, "DISTRIBUTED_PROJECT_ROOT")

                keep = joinpath(tmp, "caller-keep")
                ENV["DISTRIBUTED_PROJECT_ROOT"] = keep
                session = DistSSHRun.DistSSHSession(project = tmp, workers = String[], quiet = true)
                DistSSHRun._with_session_env!(session) do
                    @test ENV["DISTRIBUTED_PROJECT_ROOT"] == abspath(tmp)
                end
                @test ENV["DISTRIBUTED_PROJECT_ROOT"] == keep
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")

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
        finally
            _restore_env!("DISTRIBUTED_PROJECT_ROOT", saved_root)
        end
    end

    @testset "pool!" begin
        saved_root = haskey(ENV, "DISTRIBUTED_PROJECT_ROOT") ? ENV["DISTRIBUTED_PROJECT_ROOT"] : nothing
        try
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"PoolEnvRestore\"\n")
                before = joinpath(proj, "before-pool")
                ENV["DISTRIBUTED_PROJECT_ROOT"] = before
                session = DistSSHRun.DistSSHSession(project = proj, workers = String[])
                DistSSHRun.pool!(session)
                @test ENV["DISTRIBUTED_PROJECT_ROOT"] == before
                delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
                session = DistSSHRun.DistSSHSession(project = proj, workers = String[])
                err = try
                    DistSSHRun.setup!(session, :ship_tree)
                catch e
                    e
                end
                @test err isa ArgumentError
                @test !haskey(ENV, "DISTRIBUTED_PROJECT_ROOT")
            end
        finally
            _restore_env!("DISTRIBUTED_PROJECT_ROOT", saved_root)
        end
    end

    @testset "kit CLI wrappers restore DISTSSH_CLI_SUBCOMMAND_DONE" begin
        saved_done = haskey(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE") ?
            ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] : nothing
        saved_root = haskey(ENV, "DISTRIBUTED_PROJECT_ROOT") ? ENV["DISTRIBUTED_PROJECT_ROOT"] : nothing
        try
            ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] = "before"
            delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    DistSSHRun.run_pool(["-h"])
                end
            end
            @test ENV["DISTSSH_CLI_SUBCOMMAND_DONE"] == "before"

            delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            delete!(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
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

            delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
            delete!(ENV, "DISTSSH_CLI_SUBCOMMAND_DONE")
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
        finally
            _restore_env!("DISTSSH_CLI_SUBCOMMAND_DONE", saved_done)
            _restore_env!("DISTRIBUTED_PROJECT_ROOT", saved_root)
        end
    end
end