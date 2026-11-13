using Test

function _git_sync_via_ssh_shim!(bindir, work, remote; hosts = ["dest"])
    path0 = get(ENV, "PATH", "")
    return withenv(
        "PATH" => bindir * ":" * path0,
        "DISTSSH_TEST" => nothing,
        "DISTRIBUTED_SSH_OPTS" => "-o BatchMode=yes",
    ) do
        return _capture_stdio() do _, _
            DistSSHRun.git_sync_project_to_hosts!(
                hosts, work, remote;
                do_push = false, do_pull = true, confirm = false,
            )
        end
    end
end

# Oracle: local `git` CLI for the origin push, and `git_sync` stopping before
# remotes when that push fails or the tree is dirty. Remote checkout is a local
# `ssh` shim that speaks `receive-pack` and runs the remote shell. Unreachable
# hosts only for the real ssh failure. Docker SSH E2E covers a real remote.

@testset "setup git" begin
    withenv("PATH" => "/nonexistent-distsshkit-path") do
        @test_throws ArgumentError DistSSHRun.git_push_project!(".")
        @test_throws ArgumentError DistSSHRun._kit_git_ssh_command()
    end
    function _git_ident!(dir)
        run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
        # Last-wins, so this overrides a user `push.default` such as `current`.
        run(pipeline(`git -C $dir config push.default simple`; stdout = devnull, stderr = devnull))
        # `git push` only ORs this flag, so a later false does not clear an earlier true.
        run(pipeline(`git -C $dir config push.autoSetupRemote false`; stdout = devnull, stderr = devnull))
        return nothing
    end

    # Hide global, system, and `GIT_CONFIG_*` for one push. A repo-local false cannot
    # clear `push.autoSetupRemote` once any earlier true was seen, and `GIT_CONFIG_COUNT`
    # is command-line config, which overrides the temp repo.
    function _without_inherited_push_config(f)
        blank_global = tempname()
        blank_system = tempname()
        write(blank_global, "")
        write(blank_system, "")
        env = Dict{String, Union{Nothing, String}}(
            "GIT_CONFIG_GLOBAL" => blank_global,
            "GIT_CONFIG_SYSTEM" => blank_system,
            "GIT_CONFIG_COUNT" => nothing,
            "GIT_CONFIG_PARAMETERS" => nothing,
        )
        for k in keys(ENV)
            if startswith(k, "GIT_CONFIG_KEY_") || startswith(k, "GIT_CONFIG_VALUE_")
                env[k] = nothing
            end
        end
        return withenv(env...) do
            f()
        end
    end

    function _init_commit!(dir)
        run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
        _git_ident!(dir)
        write(joinpath(dir, "f.txt"), "hi\n")
        run(pipeline(`git -C $dir add f.txt`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $dir -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
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

    if _test_skip_unless_git()

        @testset "push to origin" begin
            _with_tempdir() do tmp
                work = joinpath(tmp, "work")
                mkpath(work)
                _init_commit!(work)
                @test DistSSHRun._git_remote_url(work) == "<repo_url>"
                @test !DistSSHRun.git_push_project!(work)

                bare = joinpath(tmp, "origin.git")
                run(pipeline(`git init -q --bare $bare`; stdout = devnull, stderr = devnull))
                run(pipeline(`git -C $work remote add origin $bare`; stdout = devnull, stderr = devnull))
                @test DistSSHRun._git_remote_url(work) == bare
                # `git push` with no upstream tracking fails.
                _without_inherited_push_config() do
                    @test !DistSSHRun.git_push_project!(work)
                end
                run(pipeline(`git -C $work push -q -u origin HEAD`; stdout = devnull, stderr = devnull))
                @test DistSSHRun.git_push_project!(work)
            end
        end

        @testset "SHA and path helpers" begin
            @test DistSSHRun._git_sha_valid("0123456789abcdef0123456789abcdef01234567")
            @test DistSSHRun._git_sha_valid("a"^64)
            @test !DistSSHRun._git_sha_valid("A"^40)
            @test !DistSSHRun._git_sha_valid("deadbeef")
            @test !DistSSHRun._git_sha_valid("0123456789abcdef0123456789abcdef01234567\n")
            encoded = DistSSHRun._percent_encode_git_path("/tmp/a b")
            @test encoded == "/tmp/a%20b"
            @test DistSSHRun._git_ssh_repo_url("dev@h", "/tmp/a b") == "ssh://dev@h/tmp/a%20b"
            @test DistSSHRun._missing_sha_message("h", "abc", true) ==
                "h is a shallow clone and does not contain abc. Refusing to unshallow it. See help setup."
            @test occursin("does not contain abc", DistSSHRun._missing_sha_message("h", "abc", false))
            @test !occursin("unshallow", DistSSHRun._missing_sha_message("h", "abc", false))
        end

        @testset "remote deploy metadata status filter" begin
            @test DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh/")
            @test DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh")
            @test DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh/deploy.toml")
            @test DistSSHRun._is_deploy_metadata_status_entry(
                "??", ".distssh/deploy.toml.20260101T000000Z-aaaaaa.tmp",
            )
            @test DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh/shipment.toml")
            @test DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh/ship.toml")
            @test !DistSSHRun._is_deploy_metadata_status_entry("??", "extra.txt")
            @test !DistSSHRun._is_deploy_metadata_status_entry("??", "nested/.distssh/deploy.toml")
            @test !DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh-foo/")
            @test !DistSSHRun._is_deploy_metadata_status_entry("??", ".distssh-foo/deploy.toml")
            @test !DistSSHRun._is_deploy_metadata_status_entry(" M", ".distssh/deploy.toml")
            @test !DistSSHRun._is_deploy_metadata_status_entry("M ", ".distssh/deploy.toml")
            @test !DistSSHRun._is_deploy_metadata_status_entry("R ", ".distssh/deploy.toml")
            @test !DistSSHRun._is_deploy_metadata_status_entry("C ", ".distssh/deploy.toml")
            @test DistSSHRun._remote_git_has_blocking_dirty("?? .distssh-foo/\0")
            @test DistSSHRun._remote_git_has_blocking_dirty(
                "R  .distssh/deploy.toml\0.distssh/deploy.toml.old\0",
            )
            @test DistSSHRun._remote_git_has_blocking_dirty(
                "C  .distssh/shipment.toml\0.distssh/deploy.toml\0",
            )
            @test !DistSSHRun._remote_git_has_blocking_dirty("?? .distssh/\0")
            @test !DistSSHRun._remote_git_has_blocking_dirty(
                "?? .distssh/deploy.toml\0?? .distssh/deploy.toml.x.tmp\0",
            )
            @test DistSSHRun._remote_git_has_blocking_dirty("?? extra.txt\0")
            @test DistSSHRun._remote_git_has_blocking_dirty(
                "?? .distssh/\0?? extra.txt\0",
            )
            @test DistSSHRun._remote_git_has_blocking_dirty(" M .distssh/deploy.toml\0")
            probe = DistSSHRun._commit_tracks_deploy_metadata_dir("/nonexistent-distsshkit-repo", "a"^40)
            @test !probe.ok
            @test !probe.tracks
            @test !isempty(probe.detail)
            collision = DistSSHRun._detach_sha_deploy_metadata_collision(
                "dest",
                "/nonexistent-distsshkit-repo",
                "a"^40,
                "?? .distssh/deploy.toml\0",
            )
            @test collision isa String
            @test occursin("could not read whether commit", collision)
            @test occursin("Refusing checkout", collision)
        end

        @testset "git_sync stops on local failure" begin
            _apply_quiet_setup_session!()
            _with_tempdir() do tmp
                work = joinpath(tmp, "work")
                mkpath(work)
                _init_commit!(work)
                out, raw = _capture_stdio() do _, _
                    redirect_stderr(devnull) do
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["192.0.2.1"], work, "~/App.jl";
                            do_push = true, do_pull = true,
                        )
                    end
                end
                @test !raw.ok
                @test isempty(raw.host_results)
                @test occursin("Push failed.", out)
                @test occursin("fatal:", out)

                write(joinpath(work, "dirty.txt"), "x\n")
                out_dirty, raw_dirty = _capture_stdio() do _, _
                    redirect_stderr(devnull) do
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["192.0.2.1"], work, "~/App.jl";
                            do_push = false, do_pull = true,
                        )
                    end
                end
                @test !raw_dirty.ok
                @test isempty(raw_dirty.host_results)
                @test occursin("dirty", out_dirty)
                @test occursin("--skip-git-guard", out_dirty)
                @test occursin("help setup", out_dirty)
                @test !occursin("--help", out_dirty)

                out_allow, raw_allow = _capture_stdio() do _, _
                    redirect_stderr(devnull) do
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["192.0.2.1"], work, "~/App.jl";
                            do_push = false, do_pull = true, allow_dirty = true,
                            confirm = false,
                        )
                    end
                end
                @test !raw_allow.ok
                @test !occursin("--skip-git-guard", out_allow)
                @test !occursin("Local git tree is dirty", out_allow)

                session = DistSSHRun.KitSession(
                    project = work, workers = ["child:192.0.2.1"], yes = true, quiet = true,
                )
                out_sync, _ = _capture_stdio() do _, _
                    redirect_stderr(devnull) do
                        DistSSHRun.sync!(session; mode = :git_sync, allow_dirty = true)
                    end
                end
                @test !occursin("--skip-git-guard", out_sync)
                @test !occursin("Local git tree is dirty", out_sync)
            end
        end

        @testset "allow_dirty option wiring" begin
            @test_throws ArgumentError DistSSHRun.check_setup_options!(
                :ship_tree; allow_dirty = true,
            )
            session = DistSSHRun.KitSession(project = pwd(), workers = ["child:h"], yes = true)
            err = try
                DistSSHRun.sync!(session; mode = :ship_tree, allow_dirty = true)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("allow_dirty", err.msg)
        end

        @testset "setup host outcome reads NamedTuple ok" begin
            @test DistSSHRun._setup_host_outcome_ok((; ok = true, detail = ""))
            @test !DistSSHRun._setup_host_outcome_ok((; ok = false, detail = "fatal:"))
            @test !DistSSHRun._setup_host_outcome_ok(
                DistSSHRun._git_run_detail(["-C", "/nonexistent-distsshkit-repo", "status"]),
            )
        end

        @testset "git_sync confirm abort" begin
            withenv("DISTSSH_YES" => nothing) do
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
                                            do_push = true, do_pull = true,
                                        )
                                    end
                                    @test !raw.ok
                                    @test raw.cancelled
                                    @test isempty(raw.host_results)
                                    @test occursin("Cancelled.", out)
                                    @test occursin("Proceed?", out)
                                    @test occursin("git push", out)
                                    @test occursin("detached HEAD", out)
                                    # #374: bar is suspended while stdin is read, then released.
                                    @test nsus >= 1
                                    @test DistSSHRun.KIT_PROGRESS_SUSPEND[] == 0
                                end
                            end
                        end
                        _, raw_skip = _capture_stdio() do _, _
                            redirect_stderr(devnull) do
                                DistSSHRun.git_sync_project_to_hosts!(
                                    ["192.0.2.1"], work, "~/App.jl";
                                    do_push = true, do_pull = false, confirm = false,
                                )
                            end
                        end
                        @test !raw_skip.ok
                        @test !raw_skip.cancelled
                    end
                finally
                    DistSSHRun.set_kit_noninteractive!(prev_ni)
                end
            end
        end

        @testset "remote checkout: unreachable host" begin
            if _test_skip_unless_ssh()
                _apply_quiet_setup_session!()
                withenv("DISTRIBUTED_SSH_OPTS" => "-o BatchMode=yes -o ConnectTimeout=1") do
                    _with_tempdir() do tmp
                        work = joinpath(tmp, "work")
                        mkpath(work)
                        _init_commit!(work)
                        _, raw = _capture_stdio() do _, _
                            DistSSHRun.git_sync_project_to_hosts!(
                                ["192.0.2.1", "192.0.2.2"], work, "~/App.jl";
                                do_push = false, do_pull = true, confirm = false,
                            )
                        end
                        @test !raw.ok
                        @test length(raw.host_results) == 1
                        @test raw.host_results[1].host == "192.0.2.1"
                        @test !raw.host_results[1].ok
                        @test occursin("help setup", raw.host_results[1].message)
                    end
                end
            end
        end

        # Local stand-in for ssh: `git push` speaks receive-pack; other commands run
        # the remote shell, which uses the absolute path of the stand-in repo.
        function _write_git_ssh_shim!(dir)
            path = joinpath(dir, "ssh")
            write(
                path,
                raw"""#!/bin/sh
                skip=0
                host=
                cmd=
                for a in "$@"; do
                  if [ "$skip" = 1 ]; then
                    skip=0
                    continue
                  fi
                  case "$a" in
                    -o|-p|-F|-i|-l|-b|-c|-D|-E|-J|-L|-R|-S|-W|-w)
                      skip=1
                      continue
                      ;;
                    --)
                      continue
                      ;;
                    -*)
                      continue
                      ;;
                  esac
                  if [ -z "$host" ]; then
                    host=$a
                  else
                    cmd=$a
                  fi
                done
                case "$cmd" in
                  git-receive-pack\ *|git\ receive-pack\ *)
                    path=$(printf '%s\n' "$cmd" | sed -e "s/^[^ ]* //" -e "s/^'//" -e "s/'$//")
                    exec git receive-pack "$path"
                    ;;
                  "")
                    exit 0
                    ;;
                  *)
                    exec sh -c "$cmd"
                    ;;
                esac
                """,
            )
            chmod(path, 0o755)
            return path
        end

        @testset "checkout detaches at the SHA" begin
            _apply_quiet_setup_session!()
            _with_tempdir() do tmp
                bindir = joinpath(tmp, "bin")
                mkdir(bindir)
                _write_git_ssh_shim!(bindir)
                work = joinpath(tmp, "work")
                remote = joinpath(tmp, "remote")
                mkpath(work)
                mkpath(remote)
                _init_commit!(work)
                run(pipeline(`git init -q $remote`; stdout = devnull, stderr = devnull))
                hook = joinpath(remote, ".git", "hooks", "post-checkout")
                mkpath(dirname(hook))
                write(hook, "#!/bin/sh\necho ran > \"$(joinpath(remote, "hook-ran"))\"\n")
                chmod(hook, 0o755)
                sha = strip(read(`git -C $work rev-parse HEAD`, String))
                path0 = get(ENV, "PATH", "")
                withenv(
                    "PATH" => bindir * ":" * path0,
                    "DISTSSH_TEST" => nothing,
                    "DISTRIBUTED_SSH_OPTS" => "-o BatchMode=yes",
                ) do
                    out, raw = _capture_stdio() do _, _
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["dest"], work, remote;
                            do_push = false, do_pull = true, confirm = false,
                        )
                    end
                    @test raw.ok
                    @test raw.host_results[1].ok
                    @test occursin("detached HEAD", raw.host_results[1].message)
                    @test !occursin("Warning", out)
                    @test strip(read(`git -C $remote rev-parse HEAD`, String)) == sha
                    @test strip(read(`git -C $remote rev-parse refs/distssh/$sha`, String)) == sha
                    sym = run(
                        pipeline(
                            ignorestatus(`git -C $remote symbolic-ref -q HEAD`);
                            stdout = devnull, stderr = devnull,
                        )
                    )
                    @test sym.exitcode != 0
                    @test !isfile(joinpath(remote, "hook-ran"))
                    @test read(joinpath(remote, "f.txt"), String) == "hi\n"

                    write(joinpath(remote, "extra.txt"), "shadow\n")
                    write(joinpath(work, "f.txt"), "next\n")
                    run(pipeline(`git -C $work add f.txt`; stdout = devnull, stderr = devnull))
                    run(
                        pipeline(
                            `git -C $work -c commit.gpgsign=false commit -q -m next`;
                            stdout = devnull, stderr = devnull,
                        )
                    )
                    sha2 = strip(read(`git -C $work rev-parse HEAD`, String))
                    out2, raw2 = _capture_stdio() do _, _
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["dest"], work, remote;
                            do_push = false, do_pull = true, confirm = false,
                        )
                    end
                    @test !raw2.ok
                    @test occursin("untracked or uncommitted", out2)
                    @test occursin("help setup", out2)
                    @test strip(read(`git -C $remote rev-parse HEAD`, String)) == sha
                    @test sha2 != sha
                end
            end
        end

        @testset "deploy metadata on remote checkout" begin
            _apply_quiet_setup_session!()
            _with_tempdir() do tmp
                bindir = joinpath(tmp, "bin")
                mkdir(bindir)
                _write_git_ssh_shim!(bindir)
                work = joinpath(tmp, "work")
                remote = joinpath(tmp, "remote")
                mkpath(work)
                mkpath(remote)
                _init_commit!(work)
                run(pipeline(`git init -q $remote`; stdout = devnull, stderr = devnull))
                _, raw0 = _git_sync_via_ssh_shim!(bindir, work, remote)
                @test raw0.ok

                mkpath(joinpath(remote, ".distssh"))
                write(joinpath(remote, ".distssh", "deploy.toml"), "schema = 1\n")
                write(joinpath(work, "f.txt"), "after-deploy-record\n")
                run(pipeline(`git -C $work add f.txt`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $work -c commit.gpgsign=false commit -q -m sync-with-record`;
                        stdout = devnull, stderr = devnull,
                    )
                )
                _, raw1 = _git_sync_via_ssh_shim!(bindir, work, remote)
                @test raw1.ok
                @test strip(read(`git -C $remote rev-parse HEAD`, String)) ==
                    strip(read(`git -C $work rev-parse HEAD`, String))

                head_before_block = strip(read(`git -C $remote rev-parse HEAD`, String))
                mkpath(joinpath(remote, ".distssh"))
                write(joinpath(remote, ".distssh", "deploy.toml"), "schema = 1\n")
                write(joinpath(remote, "shadow.txt"), "untracked\n")
                write(joinpath(work, "f.txt"), "blocked\n")
                run(pipeline(`git -C $work add f.txt`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $work -c commit.gpgsign=false commit -q -m blocked`;
                        stdout = devnull, stderr = devnull,
                    )
                )
                _, raw2 = _git_sync_via_ssh_shim!(bindir, work, remote)
                @test !raw2.ok
                @test occursin("untracked or uncommitted", raw2.host_results[1].message)
                @test strip(read(`git -C $remote rev-parse HEAD`, String)) == head_before_block

                rm(joinpath(remote, "shadow.txt"); force = true)
                rm(joinpath(remote, ".distssh", "deploy.toml"); force = true)
                mkpath(joinpath(work, ".distssh"))
                write(joinpath(work, ".distssh", "tracked.toml"), "in-repo\n")
                run(pipeline(`git -C $work add .distssh`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $work -c commit.gpgsign=false commit -q -m track-distssh`;
                        stdout = devnull, stderr = devnull,
                    )
                )
                _, raw3a = _git_sync_via_ssh_shim!(bindir, work, remote)
                @test raw3a.ok
                mkpath(joinpath(remote, ".distssh"))
                write(joinpath(remote, ".distssh", "deploy.toml"), "schema = 1\n")
                write(joinpath(remote, ".distssh", "tracked.toml"), "dirty\n")
                head_before_mod = strip(read(`git -C $remote rev-parse HEAD`, String))
                write(joinpath(work, "f.txt"), "tracked-mod-blocked\n")
                run(pipeline(`git -C $work add f.txt`; stdout = devnull, stderr = devnull))
                run(
                    pipeline(
                        `git -C $work -c commit.gpgsign=false commit -q -m tracked-mod`;
                        stdout = devnull, stderr = devnull,
                    )
                )
                _, raw3 = _git_sync_via_ssh_shim!(bindir, work, remote)
                @test !raw3.ok
                msg3 = raw3.host_results[1].message
                @test occursin("untracked or uncommitted", msg3) ||
                    occursin("tracks files under .distssh/", msg3)
                @test strip(read(`git -C $remote rev-parse HEAD`, String)) == head_before_mod

                _with_tempdir() do tmp2
                    work2 = joinpath(tmp2, "work")
                    remote2 = joinpath(tmp2, "remote")
                    mkpath(work2)
                    mkpath(remote2)
                    _init_commit!(work2)
                    mkpath(joinpath(work2, ".distssh"))
                    write(joinpath(work2, ".distssh", "tracked.toml"), "in-repo\n")
                    run(pipeline(`git -C $work2 add .distssh`; stdout = devnull, stderr = devnull))
                    run(
                        pipeline(
                            `git -C $work2 -c commit.gpgsign=false commit -q -m distssh-in-repo`;
                            stdout = devnull, stderr = devnull,
                        )
                    )
                    run(pipeline(`git init -q $remote2`; stdout = devnull, stderr = devnull))
                    _, raw_base = _git_sync_via_ssh_shim!(bindir, work2, remote2)
                    @test raw_base.ok
                    head0 = strip(read(`git -C $remote2 rev-parse HEAD`, String))
                    mkpath(joinpath(remote2, ".distssh"))
                    write(joinpath(remote2, ".distssh", "deploy.toml"), "schema = 1\n")
                    write(joinpath(work2, "f.txt"), "collide\n")
                    run(pipeline(`git -C $work2 add f.txt`; stdout = devnull, stderr = devnull))
                    run(
                        pipeline(
                            `git -C $work2 -c commit.gpgsign=false commit -q -m collide`;
                            stdout = devnull, stderr = devnull,
                        )
                    )
                    sha_collide = strip(read(`git -C $work2 rev-parse HEAD`, String))
                    _, raw4 = _git_sync_via_ssh_shim!(bindir, work2, remote2)
                    @test !raw4.ok
                    @test occursin("tracks files under .distssh/", raw4.host_results[1].message)
                    @test occursin(sha_collide, raw4.host_results[1].message)
                    @test strip(read(`git -C $remote2 rev-parse HEAD`, String)) == head0
                end
            end
        end

    end # _test_skip_unless_git()
end

@testset "git LFS check uses shell_status" begin
    proc = run(ignorestatus(`sh -c "exit 3"`); wait = true)
    @test DistSSHRun._process_failed_code(ProcessFailedException(Base.Process[proc])) == 3
    signaled = run(ignorestatus(`sleep 30`); wait = false)
    process_running(signaled) || error("sleep exited before SIGTERM")
    kill(signaled, Base.SIGTERM)
    wait(signaled)
    @test DistSSHRun._process_failed_code(ProcessFailedException(Base.Process[signaled])) == 143

    double = joinpath(@__DIR__, "..", "..", "..", "..", "..", "lib", "DistSSHBase", "test", "fixtures", "fake_shell_ssh.jl")
    @test isfile(double)
    _with_tempdir() do dir
        logp = joinpath(dir, "ssh.log")
        ready = joinpath(dir, "ready")
        base = Dict{String, String}(
            "DISTSSH_TEST" => "1",
            "DISTSSH_TEST_SSH" => double,
            "SHELL_DOUBLE_LOG" => logp,
            "DISTSSH_TEST_POSIX_SHELL" => "1",
        )
        try
            withenv(merge(base, Dict("SHELL_DOUBLE_MODE" => "exit0"))...) do
                none = DistSSHRun._remote_lfs_required("lfs-none.test", "/repo")
                @test none.ok
                @test !none.uses
            end
            withenv(merge(base, Dict("SHELL_DOUBLE_MODE" => "exit1"))...) do
                missing = DistSSHRun._remote_lfs_required("lfs-missing.test", "/repo")
                @test missing.ok
                @test !missing.uses
            end
            killed = withenv(
                merge(
                    base, Dict(
                        "SHELL_DOUBLE_MODE" => "sleep",
                        "SHELL_DOUBLE_READY" => ready,
                    )
                )...
            ) do
                task = @async DistSSHRun._remote_lfs_required("lfs-sig.test", "/repo")
                _kill_ready_child(ready)
                return fetch(task)
            end
            @test !killed.ok
            @test !killed.uses
        finally
            DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
        end
    end
end
