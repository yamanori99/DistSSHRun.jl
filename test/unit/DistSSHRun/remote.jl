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

    @testset "remote shell quotes metacharacters" begin
        @test DistSSHRun._remote_shell_path_word("/srv/x;id") == "'/srv/x;id'"
        @test DistSSHRun._remote_shell_path_word("~/Repo") == "~/'Repo'"
        @test DistSSHRun._remote_shell_path_word("~/a/b c") == "~/'a/b c'"
        @test DistSSHRun._ssh_host_args("host", "true") == ["--", "host", "true"]
        @test_throws ArgumentError DistSSHRun.parse_placement_token("child:-oBatchMode=yes")
    end

    @testset "delete root does not climb to home or slash" begin
        Sys.which("git") === nothing && return
        function lay(parts::Vector{String})
            root = mktempdir()
            repo = joinpath(root, "Repo")
            proj = joinpath(repo, parts...)
            mkpath(proj)
            write(joinpath(proj, "Project.toml"), "name = \"P\"\n")
            write(joinpath(proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
            run(pipeline(`git -C $repo init -q`; stdout = devnull, stderr = devnull))
            return root, proj
        end
        root, proj = lay(["proj"])
        try
            @test DistSSHRun.remote_delete_root(proj) == "~/Repo"
            @test DistSSHRun.remote_git_clone_dest(proj) == "~/Repo"
        finally
            rm(root; recursive = true)
        end
        root, proj = lay(["a", "proj"])
        try
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
            @test DistSSHRun._remote_path_forbidden("~/../u")
            @test DistSSHRun._remote_path_forbidden("/a/../b")
            @test !DistSSHRun._remote_path_forbidden("~/a/proj")
        finally
            rm(root; recursive = true)
        end
        root, proj = lay(["x", "b", "proj"])
        try
            @test DistSSHRun.remote_delete_root(proj) == "~/b/proj"
        finally
            rm(root; recursive = true)
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
end
