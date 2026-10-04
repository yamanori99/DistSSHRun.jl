using Test

@testset "remote" begin
    let r = DistSSHRun.get_local_resources()
        @test r.total_gb > 0
        @test r.nproc >= 1
    end

    _with_tempdir() do tmp
        d = tmp
        @test DistSSHRun.get_local_git_hash(d) === nothing
        @test DistSSHRun.local_git_clean(d)

        Sys.which("git") === nothing && return
        run(Cmd(["git", "-C", d, "init", "-q"]))
        run(Cmd(["git", "-C", d, "config", "user.email", "test@example.com"]))
        run(Cmd(["git", "-C", d, "config", "user.name", "Test"]))
        @test DistSSHRun.local_git_clean(d)

        write(joinpath(d, "f.txt"), "hi")
        @test !DistSSHRun.local_git_clean(d)

        run(Cmd(["git", "-C", d, "add", "f.txt"]))
        run(Cmd(["git", "-C", d, "commit", "-q", "-m", "init"]))
        @test DistSSHRun.local_git_clean(d)

        write(joinpath(d, "f.txt"), "hi2")
        @test !DistSSHRun.local_git_clean(d)

        run(Cmd(["git", "-C", d, "add", "f.txt"]))
        run(Cmd(["git", "-C", d, "commit", "-q", "-m", "dirty"]))
        @test DistSSHRun.local_git_clean(d)
        idx = joinpath(d, ".git", "index")
        if isfile(idx)
            backup = read(idx)
            write(idx, "not-a-git-index")
            try
                @test DistSSHRun.get_local_git_hash(d) isa String
                @test !DistSSHRun.local_git_clean(d)
            finally
                write(idx, backup)
            end
        end

        full = DistSSHRun.get_local_git_hash(d)
        @test full isa String
        full isa String || error("expected full git hash")
        @test length(full) == 40
        short = DistSSHRun.get_local_git_hash(d; short = 8)
        @test short isa String
        short isa String || error("expected short git hash")
        @test length(short) == 8
        @test startswith(full, short)
    end

    @testset "compat remote git shells" begin
        tilde = "~/App.jl"
        abs = "/opt/App.jl"
        pq_abs = DistSSHRun._remote_shell_path_word(abs)
        @test DistSSHRun._git_pull_remote_inner(tilde) == "cd ~/App.jl && git pull"
        @test DistSSHRun._git_pull_remote_inner(abs) == "cd $pq_abs && git pull"
    end

    @testset "detect_julia_path skips Linux candidates when uname fails" begin
        _with_tempdir() do state_dir
            logp = joinpath(state_dir, "ssh.log")
            env = merge(
                _fake_setup_remote_env(state_dir),
                Dict(
                    "DISTSSHKIT_TEST_UNAME_FAIL" => "1",
                    "DISTSSHKIT_TEST_JULIA_WHICH" => "/opt/custom/julia",
                    "DISTSSHKIT_TEST_SSH_LOG" => logp,
                ),
            )
            empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
            try
                withenv(env...) do
                    @test DistSSHRun.detect_julia_path("host1") == "/opt/custom/julia"
                end
                body = isfile(logp) ? read(logp, String) : ""
                @test occursin("uname -s", body)
                @test occursin("command -v julia", body)
                @test !occursin("/usr/bin/julia", body)
            finally
                empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
            end
        end
    end

    @testset "run_on_host remote sh" begin
        withenv("PATH" => "/nonexistent-distsshkit-path") do
            @test_throws ArgumentError DistSSHRun._remote_ssh_ok("no-such-host.invalid")
            @test_throws ArgumentError DistSSHRun.git_pull_remote_host!("x", ".")
        end
        if Sys.which("ssh") !== nothing
            @test !DistSSHRun._remote_ssh_ok("no-such-host.invalid")
        end
    end
end
