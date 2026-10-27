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

    @testset "delete shell refuses a final symlink and quotes odd names" begin
        script = DistSSHRun._remote_delete_shell("~/proj")
        @test occursin("test -L", script)
        @test occursin("cd -P", script)
        @test occursin("pwd -P", script)
        @test occursin("rm -rf", script)
        @test !occursin("--one-file-system", script)
        @test !occursin("--preserve-root", script)
        @test occursin("printf 'refusing to delete symlink %s\\n'", script)
        @test !occursin("echo \"", script)
        mktempdir() do d
            home = joinpath(d, "home")
            mkdir(home)
            nasty = joinpath(d, "a b'c\\d")
            mkdir(nasty)
            touch(joinpath(nasty, "f"))
            target = joinpath(d, "real")
            mkdir(target)
            touch(joinpath(target, "keep"))
            link = joinpath(d, "link name")
            symlink(target, link)
            via = joinpath(d, "via")
            symlink(d, via)
            nested = joinpath(via, "nested")
            mkdir(nested)
            touch(joinpath(nested, "gone"))
            depot = joinpath(home, ".julia")
            mkdir(depot)
            touch(joinpath(depot, "packages"))
            log = joinpath(d, "rm.log")
            fake = joinpath(d, "bin")
            mkdir(fake)
            real_rm = String(something(Sys.which("rm"), "/bin/rm"))
            write(
                joinpath(fake, "rm"),
                "#!/bin/sh\necho called >> $(repr(log))\nexec $(DistSSHRun._remote_sh_quote(real_rm)) \"\$@\"\n",
            )
            chmod(joinpath(fake, "rm"), 0o755)
            path = fake * ":" * get(ENV, "PATH", "")
            function run_script(target_path)
                body = DistSSHRun._remote_delete_shell(target_path)
                return run(
                    ignorestatus(pipeline(`sh -c $body`; stdout = devnull, stderr = devnull));
                    wait = true,
                )
            end
            withenv("HOME" => home, "PATH" => path) do
                rm(log; force = true)
                refused = run_script(link)
                @test refused.exitcode != 0
                @test islink(link)
                @test isfile(joinpath(target, "keep"))
                @test !isfile(log)
                rm(log; force = true)
                depot_refused = run_script(depot)
                @test depot_refused.exitcode != 0
                @test isdir(depot)
                @test !isfile(log)
                removed = run_script(nasty)
                @test removed.exitcode == 0
                @test !isdir(nasty)
                @test isfile(log)
                rm(log; force = true)
                followed = run_script(nested)
                @test followed.exitcode == 0
                @test !isdir(nested)
                @test islink(via)
                @test isfile(log)
            end
        end
    end

    @testset "delete and prune print a nasty path literally" begin
        # `$(...)`, backticks, a quote, and `~` must stay text. Nothing runs.
        # One path component: a slash inside the name would be another directory.
        leaf = "a'b~" * "\$(echo pwned; pwn)" * "`pwn`"
        mktempdir() do d
            home = joinpath(d, "home")
            mkdir(home)
            target = joinpath(d, "real")
            mkdir(target)
            link = joinpath(home, leaf)
            # Julia `symlink` expands `~` anywhere in the link path.
            run(Cmd(["ln", "-s", target, link]))
            fake = joinpath(d, "bin")
            mkdir(fake)
            log = joinpath(d, "ran.log")
            write(joinpath(fake, "pwn"), "#!/bin/sh\necho ran >> $(repr(log))\n")
            chmod(joinpath(fake, "pwn"), 0o755)
            path = fake * ":" * get(ENV, "PATH", "")
            function run_body(body)
                err = IOBuffer()
                proc = run(
                    ignorestatus(pipeline(`sh -c $body`; stdout = devnull, stderr = err));
                    wait = true,
                )
                return proc, String(take!(err))
            end
            withenv("HOME" => home, "PATH" => path) do
                rm(log; force = true)
                delete_body = DistSSHRun._remote_delete_shell("~/" * leaf)
                @test occursin("printf 'refusing to delete symlink %s\\n'", delete_body)
                @test !occursin("echo \"", delete_body)
                proc, err = run_body(delete_body)
                @test proc.exitcode != 0
                @test occursin("refusing to delete symlink " * joinpath(home, leaf), err)
                @test occursin(leaf, err)
                @test islink(link)
                @test !isfile(log)
                rm(log; force = true)
                abs_link = joinpath(d, leaf)
                run(Cmd(["ln", "-s", target, abs_link]))
                proc, err = run_body(DistSSHRun._remote_delete_shell(abs_link))
                @test proc.exitcode != 0
                @test occursin("refusing to delete symlink " * abs_link, err)
                @test islink(abs_link)
                @test !isfile(log)
                rm(log; force = true)
                prune_body = DistSSHRun._prune_remote_shell("~/" * leaf)
                @test occursin("printf 'refusing to prune symlink %s\\n'", prune_body)
                @test !occursin("echo \"", prune_body)
                proc, err = run_body(prune_body)
                @test proc.exitcode != 0
                @test occursin("refusing to prune symlink " * joinpath(home, leaf), err)
                @test occursin(leaf, err)
                @test islink(link)
                @test !isfile(log)
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
