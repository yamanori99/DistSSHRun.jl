using Test
using Distributed
using DistSSHRun

function _cluster_session(proj::AbstractString; head::Int = 2)
    return DistSSHSession(; project = proj, head_workers = head)
end

function _cluster_host!(proj::AbstractString)
    _write_host_project!(proj, "ClusterScope"; uuid = "cccccccc-dddd-eeee-ffff-555555555555")
    _git_init_min!(proj)
    return nothing
end

@testset "cluster scope" begin
    @testset "session.remote scopes launch" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            remote = "/session/CustomDeploy"
            keep = "/caller/KeepRemote"
            session = DistSSHSession(;
                project = proj, head_workers = 1, remote = remote,
            )
            prev = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
            after = nothing
            try
                ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = keep
                redirect_stdout(devnull) do
                    cluster(session) do c
                        @test length(c.workers) == 1
                        seen = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", "")
                        @test seen == DistSSHRun.remote_env_project_root(remote)
                        @test DistSSHRun.remote_deploy_root(proj) == remote
                        return :scoped
                    end
                end
                after = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
                @test after == keep
            finally
                if prev === nothing
                    delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
                else
                    ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = prev
                end
            end
        end
    end

    @testset "normal return removes launched workers" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            session = _cluster_session(proj)
            out = redirect_stdout(devnull) do
                cluster(session) do c
                    @test length(c.workers) == 2
                    @test launch_report_joined(c.report) == 2
                    return :done
                end
            end
            @test out === :done
            @test nprocs() == 1
            @test workers() == [1]
        end
    end

    @testset "error in body keeps foreign and user addprocs" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            session = _cluster_session(proj; head = 1)
            addprocs(1; topology = :master_worker)
            foreign = workers()[end]
            owned = Int[]
            user = 0
            err = nothing
            try
                try
                    redirect_stdout(devnull) do
                        cluster(session) do c
                            owned = copy(c.workers)
                            addprocs(1; topology = :master_worker)
                            user = workers()[end]
                            error("cluster body failed")
                        end
                    end
                catch e
                    err = e
                end
                @test err isa ErrorException
                @test occursin("cluster body failed", sprint(showerror, err))
                @test foreign in workers()
                @test user in workers()
                @test remotecall_fetch(identity, foreign, 1) === 1
                @test remotecall_fetch(identity, user, 2) === 2
                for w in owned
                    @test w ∉ workers()
                end
            finally
                for w in setdiff(workers(), [1])
                    w in workers() && rmprocs(w; waitfor = 2.0)
                end
            end
        end
    end

    @testset "InterruptException in body cleans launched workers" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            session = _cluster_session(proj; head = 1)
            owned = Int[]
            caught = false
            try
                redirect_stdout(devnull) do
                    cluster(session) do c
                        owned = copy(c.workers)
                        throw(InterruptException())
                    end
                end
            catch e
                e isa InterruptException && (caught = true)
                caught || rethrow()
            end
            @test caught
            for w in owned
                @test w ∉ workers()
            end
            @test nprocs() == 1
        end
    end

    @testset "provenance launch after success and after error" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            session = _cluster_session(proj; head = 1)
            try
                redirect_stdout(devnull) do
                    cluster(session) do c
                        prov = DistSSHRun.assemble_provenance(proj)
                        launch = prov["launch"]
                        @test launch["planned"] == launch_report_planned(c.report)
                        @test launch["joined"] == launch_report_joined(c.report)
                        error("after provenance snap")
                    end
                end
            catch
                prov = DistSSHRun.assemble_provenance(proj)
                launch = prov["launch"]
                @test launch["planned"] == 1
                @test launch["joined"] == 1
            end
        end
    end

    @testset "foreign worker warn on teardown" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            session = _cluster_session(proj; head = 1)
            addprocs(1; topology = :master_worker)
            foreign = workers()[end]
            try
                @test_logs (:warn, r"skipped worker removal") redirect_stdout(devnull) do
                    cluster(session) do c
                        return c.workers
                    end
                end
            finally
                foreign in workers() && rmprocs(foreign; waitfor = 2.0)
            end
        end
    end

    @testset "SIGINT child keeps user addprocs, drops cluster workers" begin
        _mktemp_host() do proj
            _cluster_host!(proj)
            _develop_kit!(proj)
            marker = joinpath(proj, "main_started")
            state = joinpath(proj, "cluster_state.txt")
            child = _fixture("cluster_sigint_child.jl")
            @test isfile(child)
            julia = _julia_exe()
            cmd = setenv(
                `$julia --startup-file=no --project=$proj $child`,
                merge(
                    _child_julia_env(),
                    Dict(
                        "DISTSSH_CLUSTER_TEST_PROJ" => abspath(proj),
                        "DISTSSH_TEST_SIGINT_MARKER" => marker,
                        "DISTSSH_TEST_CLUSTER_STATE" => state,
                    ),
                ),
            )
            proc, reader = _start_subprocess(cmd)
            started = timedwait(() -> isfile(marker) || !process_running(proc), 300.0; pollint = 0.5)
            @test started === :ok && isfile(marker)
            sleep(1)
            kill(proc, Base.SIGINT)
            stopped = timedwait(() -> !process_running(proc), 60.0; pollint = 0.5)
            stopped === :ok || kill(proc, Base.SIGKILL)
            wait(proc)
            combined = fetch(reader)
            if proc.exitcode != 130 || !isfile(state)
                println(stderr, "──── cluster SIGINT (exit=$(proc.exitcode)) ────")
                println(stderr, combined)
            end
            @test proc.exitcode == 130
            @test !occursin("TaskFailedException", combined)
            lines = readlines(state)
            owned_ids = Int[]
            user_ok = false
            foreign_ok = false
            for line in lines
                parts = split(line, '\t')
                length(parts) == 3 || continue
                kind, wid, present = parts[1], parse(Int, parts[2]), parts[3] == "true"
                if kind == "owned"
                    push!(owned_ids, wid)
                    @test !present
                elseif kind == "user"
                    user_ok = present
                elseif kind == "foreign"
                    foreign_ok = present
                end
            end
            @test length(owned_ids) == 2
            @test length(unique(owned_ids)) == 2
            @test user_ok
            @test foreign_ok
        end
    end
end
