using Test

# Oracle: local `git` CLI for push/pull, and `git_sync` stopping before remotes
# when local push/pull fails. Remote `git pull` uses the setup SSH double. Unreachable
# hosts only. Real remote git is SSH E2E.

@testset "setup git" begin
    withenv("PATH" => "/nonexistent-distsshkit-path") do
        @test_throws ArgumentError DistSSHRun.git_push_project!(".")
        @test_throws ArgumentError DistSSHRun.git_pull_local_project!(".")
        @test_throws ArgumentError DistSSHRun.git_pull_remote_host!("x", ".")
    end
    function _git_ident!(dir)
        run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
        return nothing
    end

    function _init_commit!(dir)
        run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
        _git_ident!(dir)
        write(joinpath(dir, "f.txt"), "hi\n")
        run(pipeline(`git -C $dir add f.txt`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir commit -q -m init`; stdout = devnull, stderr = devnull))
        return nothing
    end

    @testset "resolve_clone_url" begin
        @test DistSSHRun.resolve_clone_url(
            "https://github.com/org/App.jl.git",
            "/unused",
        ) == "git@github.com:org/App.jl.git"
        _with_tempdir() do tmp
            @test_throws ErrorException DistSSHRun.resolve_clone_url(nothing, tmp; surface = :cli)
            @test_throws ErrorException DistSSHRun.resolve_clone_url("", tmp; surface = :api)
        end
    end

    Sys.which("git") === nothing && return

    @testset "push / local pull" begin
        _with_tempdir() do tmp
            work = joinpath(tmp, "work")
            mkpath(work)
            _init_commit!(work)
            @test DistSSHRun._git_remote_url(work) == "<repo_url>"
            @test !DistSSHRun.git_push_project!(work)
            @test !DistSSHRun.git_pull_local_project!(work)

            bare = joinpath(tmp, "origin.git")
            run(pipeline(`git init -q --bare $bare`; stdout = devnull, stderr = devnull))
            run(pipeline(`git -C $work remote add origin $bare`; stdout = devnull, stderr = devnull))
            @test DistSSHRun._git_remote_url(work) == bare
            # `git push` with no upstream tracking fails.
            @test !DistSSHRun.git_push_project!(work)
            run(pipeline(`git -C $work push -q -u origin HEAD`; stdout = devnull, stderr = devnull))
            @test DistSSHRun.git_push_project!(work)
            @test DistSSHRun.git_pull_local_project!(work)
        end
    end

    @testset "git_sync stops on local failure" begin
        _apply_quiet_setup_session!()
        _with_tempdir() do tmp
            work = joinpath(tmp, "work")
            mkpath(work)
            _init_commit!(work)
            out, raw = _capture_stdio() do _, _
                DistSSHRun.git_sync_project_to_hosts!(
                    ["192.0.2.1"], work, "~/App.jl";
                    do_push = true, do_pull = true, do_local_pull = false,
                )
            end
            @test !raw.ok
            @test isempty(raw.host_results)
            @test occursin("Push failed.", out)
            @test occursin("fatal:", out)

            out_pull, raw_pull = _capture_stdio() do _, _
                DistSSHRun.git_sync_project_to_hosts!(
                    ["192.0.2.1"], work, "~/App.jl";
                    do_push = false, do_pull = true, do_local_pull = true,
                )
            end
            @test !raw_pull.ok
            @test isempty(raw_pull.host_results)
            @test occursin("no tracking information", out_pull)
        end
    end

    @testset "setup host outcome reads NamedTuple ok" begin
        @test DistSSHRun._setup_host_outcome_ok((; ok = true, detail = ""))
        @test !DistSSHRun._setup_host_outcome_ok((; ok = false, detail = "fatal:"))
        @test !DistSSHRun._setup_host_outcome_ok(
            DistSSHRun._git_run_detail(["-C", "/nonexistent-distsshkit-repo", "status"]),
        )
    end

    @testset "git_sync confirm abort" begin
        withenv("DISTSSHKIT_YES" => nothing) do
            prev_ni = DistSSHRun.kit_noninteractive()
            DistSSHRun.set_kit_noninteractive!(false)
            try
                _with_tempdir() do tmp
                    work = joinpath(tmp, "work")
                    mkpath(work)
                    _init_commit!(work)
                    for v in (:quiet, :progress, :verbose)
                        with_kit_verbosity(v) do
                            _with_active_kit_progress() do _
                                out, raw, nsus = _capture_stdio(; probe_suspend = true) do stdin_io, _
                                    println(stdin_io, "n")
                                    flush(stdin_io)
                                    seekstart(stdin_io)
                                    DistSSHRun.git_sync_project_to_hosts!(
                                        ["host1"], work, "~/App.jl";
                                        do_push = true, do_pull = true, do_local_pull = false,
                                    )
                                end
                                @test !raw.ok
                                @test raw.cancelled
                                @test isempty(raw.host_results)
                                @test occursin("Cancelled.", out)
                                @test occursin("Proceed?", out)
                                @test occursin("git push", out)
                                # #374: bar is suspended while stdin is read, then released.
                                @test nsus >= 1
                                @test DistSSHRun.KIT_PROGRESS_SUSPEND[] == 0
                            end
                        end
                    end
                    _, raw_skip = _capture_stdio() do _, _
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["192.0.2.1"], work, "~/App.jl";
                            do_push = true, do_pull = false, do_local_pull = false, confirm = false,
                        )
                    end
                    @test !raw_skip.ok
                    @test !raw_skip.cancelled
                end
            finally
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end
    end

    @testset "remote pull: unreachable host" begin
        Sys.which("ssh") === nothing && return
        _apply_quiet_setup_session!()
        withenv("DISTRIBUTED_SSH_OPTS" => "-o BatchMode=yes -o ConnectTimeout=1") do
            @test !DistSSHRun.git_pull_remote_host!("192.0.2.1", "~/App.jl")
            _with_tempdir() do tmp
                work = joinpath(tmp, "work")
                mkpath(work)
                _init_commit!(work)
                raw = DistSSHRun.git_sync_project_to_hosts!(
                    ["192.0.2.1", "192.0.2.2"], work, "~/App.jl";
                    do_push = false, do_pull = true, do_local_pull = false,
                )
                @test !raw.ok
                @test length(raw.host_results) == 1
                @test raw.host_results[1].host == "192.0.2.1"
                @test !raw.host_results[1].ok
            end
        end
    end

    @testset "remote pull detail and HEAD check" begin
        _apply_quiet_setup_session!()
        _with_tempdir() do state
            _with_tempdir() do tmp
                work = joinpath(tmp, "work")
                mkpath(work)
                _init_commit!(work)
                hash = strip(read(`git -C $work rev-parse HEAD`, String))
                branch = strip(read(`git -C $work rev-parse --abbrev-ref HEAD`, String))
                env = merge(
                    _fake_setup_remote_env(state),
                    Dict(
                        "DISTSSHKIT_TEST_GIT_HEAD" => hash,
                        "DISTSSHKIT_TEST_GIT_BRANCH" => branch,
                    ),
                )
                withenv(env...) do
                    raw = DistSSHRun.git_sync_project_to_hosts!(
                        ["host1"], work, "/tmp/App.jl";
                        do_push = false, do_pull = true, do_local_pull = false, confirm = false,
                    )
                    @test raw.ok
                    @test raw.host_results[1].ok
                end
                bad = merge(
                    env, Dict(
                        "DISTSSHKIT_TEST_GIT_HEAD" => "deadbeef",
                        "DISTSSHKIT_TEST_GIT_BRANCH" => "remote-main",
                    )
                )
                withenv(bad...) do
                    out, raw = _capture_stdio() do _, _
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["host1", "host2"], work, "/tmp/App.jl";
                            do_push = false, do_pull = true, do_local_pull = false, confirm = false,
                        )
                    end
                    @test raw.ok
                    @test length(raw.host_results) == 2
                    @test raw.host_results[1].ok
                    @test raw.host_results[2].ok
                    @test occursin("remote-main", raw.host_results[1].message)
                    @test occursin(branch, raw.host_results[1].message)
                    @test occursin("deadbeef", raw.host_results[1].message)
                    @test occursin("Warning:", out)
                    @test occursin("will be an error", out)
                end
                fail_pull = merge(env, Dict("DISTSSHKIT_TEST_GIT_PULL_FAIL" => "1"))
                withenv(fail_pull...) do
                    raw = DistSSHRun.git_sync_project_to_hosts!(
                        ["host1"], work, "/tmp/App.jl";
                        do_push = false, do_pull = true, do_local_pull = false, confirm = false,
                    )
                    @test !raw.ok
                    @test occursin("not a git repository", raw.host_results[1].message)
                end
            end
        end
    end
end
