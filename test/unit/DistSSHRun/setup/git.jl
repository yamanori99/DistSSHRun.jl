using Test

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

    Sys.which("git") === nothing && return

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

    @testset "git_sync stops on local failure" begin
        _apply_quiet_setup_session!()
        _with_tempdir() do tmp
            work = joinpath(tmp, "work")
            mkpath(work)
            _init_commit!(work)
            out, raw = _capture_stdio() do _, _
                DistSSHRun.git_sync_project_to_hosts!(
                    ["192.0.2.1"], work, "~/App.jl";
                    do_push = true, do_pull = true,
                )
            end
            @test !raw.ok
            @test isempty(raw.host_results)
            @test occursin("Push failed.", out)
            @test occursin("fatal:", out)

            write(joinpath(work, "dirty.txt"), "x\n")
            out_dirty, raw_dirty = _capture_stdio() do _, _
                DistSSHRun.git_sync_project_to_hosts!(
                    ["192.0.2.1"], work, "~/App.jl";
                    do_push = false, do_pull = true,
                )
            end
            @test !raw_dirty.ok
            @test isempty(raw_dirty.host_results)
            @test occursin("dirty", out_dirty)
            @test occursin("not sent as a patch", out_dirty)
            @test occursin("help setup", out_dirty)
            @test !occursin("--help", out_dirty)
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
                        DistSSHRun.git_sync_project_to_hosts!(
                            ["192.0.2.1"], work, "~/App.jl";
                            do_push = true, do_pull = false, confirm = false,
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

    @testset "remote checkout: unreachable host" begin
        Sys.which("ssh") === nothing && return
        _apply_quiet_setup_session!()
        withenv("DISTRIBUTED_SSH_OPTS" => "-o BatchMode=yes -o ConnectTimeout=1") do
            _with_tempdir() do tmp
                work = joinpath(tmp, "work")
                mkpath(work)
                _init_commit!(work)
                raw = DistSSHRun.git_sync_project_to_hosts!(
                    ["192.0.2.1", "192.0.2.2"], work, "~/App.jl";
                    do_push = false, do_pull = true, confirm = false,
                )
                @test !raw.ok
                @test length(raw.host_results) == 1
                @test raw.host_results[1].host == "192.0.2.1"
                @test !raw.host_results[1].ok
                @test occursin("help setup", raw.host_results[1].message)
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
                "DISTSSHKIT_TEST" => nothing,
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
end
