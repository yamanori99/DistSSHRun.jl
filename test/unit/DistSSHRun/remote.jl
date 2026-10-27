using Test

function _remote_delete_fixture(root::String, parts::Vector{String})
    repo = joinpath(root, "Repo")
    proj = joinpath(repo, parts...)
    mkpath(proj)
    write(joinpath(proj, "Project.toml"), "name = \"P\"\n")
    write(joinpath(proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
    run(pipeline(`git -C $repo init -q`; stdout = devnull, stderr = devnull))
    return proj
end

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
        @test DistSSHRun._git_pull_remote_inner(tilde) == "cd ~/'App.jl' && git pull"
        @test DistSSHRun._git_pull_remote_inner(abs) == "cd $pq_abs && git pull"
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

    @testset "delete root does not climb to home or slash" begin
        Sys.which("git") === nothing && return
        mktempdir() do root
            proj = _remote_delete_fixture(root, ["proj"])
            @test DistSSHRun.remote_delete_root(proj) == "~/Repo"
            @test DistSSHRun.remote_git_clone_dest(proj) == "~/Repo"
        end
        mktempdir() do root
            proj = _remote_delete_fixture(root, ["a", "proj"])
            @test DistSSHRun.remote_delete_root(proj) == "~/a/proj"
            clone_err = try
                DistSSHRun.remote_git_clone_dest(proj)
                ""
            catch e
                e isa ArgumentError ? e.msg : sprint(showerror, e)
            end
            @test occursin("--remote-path", clone_err)
            @test DistSSHRun.remote_delete_root(proj; cli_override = "/a/proj") == "/a/proj"
            @test DistSSHRun.remote_delete_root(proj; cli_override = "/var/a/proj") == "/var/a/proj"
            @test_throws ArgumentError DistSSHRun.remote_delete_root(proj; cli_override = "~")
            @test_throws ArgumentError DistSSHRun.delete_remotes(String[], "~")
            @test_throws ArgumentError DistSSHRun.delete_remotes(String[], "~/../u")
        end
        mktempdir() do root
            proj = _remote_delete_fixture(root, ["x", "b", "proj"])
            @test DistSSHRun.remote_delete_root(proj) == "~/b/proj"
        end
    end

    @testset "delete shell stops when the path is ~ or /" begin
        mktempdir() do d
            home = joinpath(d, "home")
            proj = joinpath(d, "proj")
            mkdir(home)
            mkdir(proj)
            fake = joinpath(d, "bin")
            mkdir(fake)
            log = joinpath(d, "rm.log")
            write(joinpath(fake, "rm"), "#!/bin/sh\necho called >> $(repr(log))\n")
            chmod(joinpath(fake, "rm"), 0o755)
            path = fake * ":" * get(ENV, "PATH", "")
            home_script = DistSSHRun._remote_delete_shell(home)
            allowed = DistSSHRun._remote_delete_shell(proj)
            withenv("HOME" => home, "PATH" => path) do
                refused = run(
                    ignorestatus(pipeline(`sh -c $home_script`; stdout = devnull, stderr = devnull));
                    wait = true,
                )
                @test refused.exitcode != 0
                @test !isfile(log)
                ran = run(
                    ignorestatus(pipeline(`sh -c $allowed`; stdout = devnull, stderr = devnull));
                    wait = true,
                )
                @test ran.exitcode == 0
                @test isfile(log)
            end
        end
    end

    @testset "tagged pkill pattern does not match its own command" begin
        raw = DistSSHRun.kit_job_pkill_pattern("job.1")
        safe = DistSSHRun._pkill_regex_no_self(raw)
        @test safe == "[d]istsshkit-job:job.1"
        cmd = DistSSHRun._remote_tagged_pkill_sh("job.1")
        @test occursin(safe, cmd)
        @test !occursin(Regex(safe), cmd)
        @test occursin(Regex(safe), "--eval=#$(raw)")
        @test DistSSHRun._REAP_SSH_PHASE_S == 15.0
        @test DistSSHRun._REAP_SSH_PHASE_S >=
            Float64(DistSSHRun.DistSSHBase._SSH_CONNECT_TIMEOUT_S) + 5
        if Sys.which("pkill") !== nothing
            proc = run(
                pipeline(
                    ignorestatus(`pkill -9 -f distsshkit-job:no-such-reap-116`);
                    stdout = devnull,
                    stderr = devnull,
                ),
            )
            @test Int(proc.exitcode) == 1
        end
    end

    @testset "reap pkill is parallel, deduped, and bounded" begin
        _with_tempdir() do dir
            script = joinpath(dir, "reap_ssh.jl")
            write(
                script,
                """
                mark = joinpath(ENV["REAP_DIR"], ARGS[1])
                open(mark, "w") do io
                    println(io, "1")
                end
                code = parse(Int, get(ENV, "REAP_EXIT", "1"))
                code == 99 && sleep(60)
                exit(code)
                """,
            )
            marks = joinpath(dir, "marks")
            mkpath(marks)
            withenv(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => script,
                "REAP_DIR" => marks,
                "REAP_EXIT" => "1",
            ) do
                @test_logs DistSSHRun._reap_tagged_workers!("job.1", ["h", "h", "g"])
            end
            @test sort(readdir(marks)) == ["g", "h"]
            rm(joinpath(marks, "g"); force = true)
            rm(joinpath(marks, "h"); force = true)
            withenv(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => script,
                "REAP_DIR" => marks,
                "REAP_EXIT" => "255",
            ) do
                @test_logs (:warn, r"Tagged worker pkill did not reach: a, b") begin
                    DistSSHRun._reap_tagged_workers!("job.1", ["a", "a", "b"])
                end
            end
            withenv(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => script,
                "REAP_DIR" => marks,
                "REAP_EXIT" => "99",
            ) do
                t0 = time()
                @test_logs (:warn, r"Tagged worker pkill did not reach: a, b, c") begin
                    DistSSHRun._reap_tagged_workers!("job.1", ["a", "b", "c"])
                end
                @test time() - t0 < DistSSHRun._REAP_SSH_PHASE_S + 8
            end
        end
    end

    @testset "collect skips .git" begin
        @test DistSSHRun._collect_rel_is_git(".git")
        @test DistSSHRun._collect_rel_is_git(".git/HEAD")
        @test DistSSHRun._collect_rel_is_git(".git\\HEAD")
        @test !DistSSHRun._collect_rel_is_git("out/.git/HEAD")
        @test !DistSSHRun._collect_rel_is_git("result.txt")
    end
end
