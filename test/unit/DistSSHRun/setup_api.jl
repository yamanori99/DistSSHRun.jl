using Test

@testset "setup!" begin
    function _with_fake_remotes(f::Function)
        _with_tempdir() do state_dir
            old_proj = get(ENV, "DISTRIBUTED_PROJECT_ROOT", nothing)
            old_remote = get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", nothing)
            try
                withenv(_fake_setup_remote_env(state_dir)...) do
                    _apply_quiet_setup_session!()
                    return f(state_dir)
                end
            finally
                if old_proj === nothing
                    delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
                else
                    ENV["DISTRIBUTED_PROJECT_ROOT"] = old_proj
                end
                if old_remote === nothing
                    delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
                else
                    ENV["DISTRIBUTED_REMOTE_PROJECT_ROOT"] = old_remote
                end
            end
        end
    end

    @testset "delete + multi-mode" begin
        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                write(joinpath(proj, "Manifest.toml"), "# lock\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                delete_path = DistSSHRun.remote_delete_root(proj; cli_override = "~/App.jl")
                del = DistSSHRun.setup!(session, :delete; confirm_path = delete_path)
                @test del.ok && !del.cancelled
                @test length(del.hosts) == 1 && del.hosts[1].ok
                @test !isdir(joinpath(state_dir, slot))
                prog = joinpath(proj, ".distsshkit", "setup", "kit.progress")
                @test isfile(prog)
                body = read(prog, String)
                @test occursin("kind=setup", body)
                @test occursin("label=delete/$host", body)

                tested = DistSSHRun.setup!(session, :runtest; julia = "/bin/echo")
                @test tested.ok && !tested.cancelled

                inst = DistSSHRun.setup!(session, :instantiate; julia = "/bin/echo")
                @test inst.ok && !inst.cancelled
            end
        end
    end

    @testset "prune leaves" begin
        _with_tempdir() do proj
            go_old = joinpath(proj, ".distsshkit", "go", "job_20200101T000000Z")
            go_keep = joinpath(proj, "scripts", ".distsshkit", "go", "job_keep_id")
            drive = joinpath(proj, "scripts", ".distsshkit", "drive")
            mkpath(go_old)
            mkpath(go_keep)
            mkpath(drive)
            write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
            run_keep = joinpath(proj, "scripts", ".distsshkit", "runs", "go", "job_keep_id")
            run_old = joinpath(proj, ".distsshkit", "runs", "drive", "job_20200101T000000Z")
            mkpath(run_keep)
            mkpath(run_old)
            n = DistSSHRun.prune_kit_leaf_dirs!(proj; id = "keep_id")
            @test n == 2
            @test isdir(go_old)
            @test !isdir(go_keep)
            @test isdir(drive)
            @test isdir(run_old)
            @test !isdir(run_keep)
            fake = joinpath(proj, ".distsshkit", "go", "job_fake")
            mkpath(fake)
            write(
                joinpath(fake, "run.toml"),
                "schema = 1\nwriter = \"Other 1.0\"\nkind = \"go\"\n",
            )
            err = try
                DistSSHRun.prune_kit_leaf_dirs!(proj)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("unowned run leaf", err.msg)
            @test isdir(fake)
            rm(joinpath(fake, "run.toml"); force = true)
            nested = joinpath(drive, "nested")
            mkpath(nested)
            write(
                joinpath(nested, "run.toml"),
                "schema = 1\nwriter = \"Other 1.0\"\nkind = \"drive\"\n",
            )
            err_nested = try
                DistSSHRun.prune_kit_leaf_dirs!(proj)
                nothing
            catch e
                e
            end
            @test err_nested isa ArgumentError
            @test occursin("unowned run leaf", err_nested.msg)
            @test isdir(nested)
            rm(joinpath(nested, "run.toml"); force = true)
            n2 = DistSSHRun.prune_kit_leaf_dirs!(proj)
            @test n2 >= 3
            @test !isdir(go_old)
            @test !isdir(drive)
            @test !isdir(run_old)
            @test !isdir(fake)
            @test isfile(joinpath(proj, "Project.toml"))
        end

        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(joinpath(tree, ".distsshkit", "go", "batch_a"))
                mkpath(joinpath(tree, "keep"))
                write(joinpath(tree, "keep", "Project.toml"), "name = \"Tmp\"\n")
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                pr = DistSSHRun.setup!(session, :prune; confirm_path = "~/App.jl")
                @test pr.ok && !pr.cancelled
                @test isfile(joinpath(tree, "keep", "Project.toml"))
                @test !isdir(joinpath(tree, ".distsshkit", "go", "batch_a"))
            end
        end
    end

    @testset "juliaup align" begin
        _with_fake_remotes() do _
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                host = "host1"
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                empty!(DistSSHRun.DistSSHBase._DETECT_JULIA_PATH_CACHE)
                ver_env = Dict(
                    "DISTSSHKIT_TEST_JULIA_VERSION" => "julia version $(VERSION)",
                    "DISTSSHKIT_TEST_UNAME" => "Linux",
                )
                withenv(ver_env...) do
                    up = DistSSHRun.setup!(session, :juliaup)
                    @test up.ok && !up.cancelled
                    @test length(up.hosts) == 1 && up.hosts[1].ok
                end
                withenv(
                    ver_env...,
                    "DISTSSHKIT_TEST_JULIAUP_ALREADY" => "1",
                ) do
                    empty!(DistSSHRun.DistSSHBase._DETECT_JULIA_PATH_CACHE)
                    # `quiet=true` would re-pin `:quiet` in `apply_session_env!`
                    # and swallow the `:progress` already-on line.
                    progress_session = DistSSHRun.KitSession(
                        project = proj,
                        workers = ["child:$host"],
                        remote = "~/App.jl",
                        yes = true,
                    )
                    out, up = with_kit_verbosity(:progress) do
                        _capture_stdio() do _, _
                            DistSSHRun.setup!(progress_session, :juliaup)
                        end
                    end
                    @test up.ok && !up.cancelled
                    ch = DistSSHRun.juliaup_channel()
                    @test occursin("$host: already on $ch", out)
                end
                withenv("DISTSSHKIT_TEST_NO_JULIAUP" => "1") do
                    empty!(DistSSHRun.DistSSHBase._DETECT_JULIA_PATH_CACHE)
                    bad = DistSSHRun.setup!(session, :juliaup)
                    @test !bad.ok
                end
                ssh_log = joinpath(proj, "ssh.log")
                withenv(ver_env..., "DISTSSHKIT_TEST_SSH_LOG" => ssh_log) do
                    empty!(DistSSHRun.DistSSHBase._DETECT_JULIA_PATH_CACHE)
                    upd = DistSSHRun.setup!(session, :juliaup_update)
                    @test upd.ok && !upd.cancelled
                    @test length(upd.hosts) == 1 && upd.hosts[1].ok
                    @test occursin("update", upd.hosts[1].message)
                    logged = isfile(ssh_log) ? read(ssh_log, String) : ""
                    @test occursin("\"\$JU\" update", logged)
                    @test !occursin("echo already", logged)
                    @test !occursin(" add ", logged)
                    @test !occursin("default", logged)
                end
                withenv("DISTSSHKIT_TEST_NO_JULIAUP" => "1") do
                    empty!(DistSSHRun.DistSSHBase._DETECT_JULIA_PATH_CACHE)
                    bad_up = DistSSHRun.setup!(session, :juliaup_update)
                    @test !bad_up.ok
                end
            end
        end
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
            mktempdir() do d
                ju = joinpath(d, "juliaup")
                jl = joinpath(d, "julia")
                write(
                    ju, """
                    #!/bin/sh
                    case "\$1" in
                      --version) echo 'Juliaup 1.22.7'; exit 0 ;;
                      add|update|default) exit 0 ;;
                      status) echo ok; exit 0 ;;
                      *) exit 1 ;;
                    esac
                    """
                )
                write(
                    jl, """
                    #!/bin/sh
                    echo "julia version $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
                    """
                )
                chmod(ju, 0o755)
                chmod(jl, 0o755)
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["parent"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                    up = DistSSHRun.setup!(session, :juliaup)
                    @test up.ok && !up.cancelled
                    @test length(up.hosts) == 1 && up.hosts[1].ok
                    @test up.hosts[1].host == "parent"
                end
            end
        end
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
            mktempdir() do d
                ju = joinpath(d, "juliaup")
                logp = joinpath(d, "argv.log")
                write(
                    ju, """
                    #!/bin/sh
                    printf '%s\\n' "\$1" >> $(repr(logp))
                    case "\$1" in
                      --version) echo 'Juliaup 1.22.7'; exit 0 ;;
                      add|update|default) exit 0 ;;
                      status) echo ok; exit 0 ;;
                      *) exit 1 ;;
                    esac
                    """
                )
                chmod(ju, 0o755)
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["parent"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                withenv("DISTSSHKIT_TEST" => "1", "DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                    upd = DistSSHRun.setup!(session, :juliaup_update)
                    @test upd.ok && !upd.cancelled
                    @test length(upd.hosts) == 1 && upd.hosts[1].ok
                    @test upd.hosts[1].host == "parent"
                    @test split(strip(read(logp, String)), '\n') == ["--version", "update"]
                end
            end
        end
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
            session = DistSSHRun.KitSession(
                project = proj,
                workers = ["parent", "child:host1"],
                remote = "~/App.jl",
                yes = true,
                quiet = true,
            )
            @test_throws ArgumentError DistSSHRun.setup!(session, :check)
            @test_throws ArgumentError DistSSHRun.setup!(session, :delete)
        end
    end

    @testset "quiet suppresses Log file on stdout" begin
        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                with_kit_verbosity(:verbose) do
                    out, del = _capture_stdio() do _, _
                        DistSSHRun.setup!(
                            session, :delete;
                            confirm_path = DistSSHRun.remote_delete_root(proj; cli_override = "~/App.jl"),
                        )
                    end
                    @test del.ok && !del.cancelled
                    @test !occursin("Log file:", out)
                    @test isfile(joinpath(proj, ".distsshkit", "setup", "kit.progress"))
                end
            end
        end
    end

    @testset "ambient progress keeps Log file off stdout" begin
        _with_fake_remotes() do _
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                # No quiet=: auto session would resolve to :verbose under a pipe.
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "~/App.jl",
                    yes = true,
                )
                with_kit_verbosity(:progress) do
                    out, _ = _capture_stdio() do _, _
                        DistSSHRun.setup!(session, :cleanup)
                    end
                    @test !occursin("Log file:", out)
                    @test DistSSHRun.kit_verbosity() === :progress
                end
            end
        end
    end

    @testset "multi-mode ship-tree needs a git work tree" begin
        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                write(joinpath(proj, "Manifest.toml"), "# lock\n")
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                @test_throws ArgumentError DistSSHRun.setup!(session, :ship_tree, :instantiate)
                @test isfile(joinpath(tree, "keepme.txt"))
            end
        end
    end

    @testset "instantiate preflight miss" begin
        _with_fake_remotes() do _
            _with_tempdir() do proj
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                withenv("DISTSSHKIT_TEST_SSH_FAIL" => "1") do
                    res = DistSSHRun.setup!(session, :instantiate; julia = "/bin/echo")
                    @test !res.ok
                end
            end
        end
    end

    @testset "clone requires repo=" begin
        _with_tempdir() do proj
            session = DistSSHRun.KitSession(
                project = proj,
                workers = ["child:host1"],
                remote = "~/App.jl",
                yes = true,
            )
            out, _ = _capture_stdio() do _, _
                @test_throws ArgumentError DistSSHRun.setup!(session, :clone)
                @test_throws ArgumentError DistSSHRun.setup!(session, :clone; repo = "")
            end
            @test !occursin("Log file:", out)
            @test !isdir(joinpath(proj, ".distsshkit", "setup"))
        end

        _with_fake_remotes() do _
            _with_tempdir() do proj
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                res = DistSSHRun.setup!(session, :clone; repo = "https://github.com/example/App.jl.git")
                @test res.ok && !res.cancelled
                @test length(res.hosts) == 1 && res.hosts[1].ok
            end
        end
    end

    @testset "check + cleanup + bad mode" begin
        _with_fake_remotes() do _
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\nuuid = \"00000000-0000-0000-0000-000000000001\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                out, res = withenv("PATH" => "/nonexistent-distsshkit-path") do
                    _capture_stdio() do _, _
                        DistSSHRun.setup!(session, :check; check_code_sync = false, ignore_julia_version = true)
                    end
                end
                @test res isa DistSSHRun.SyncResult
                @test !res.cancelled
                @test !res.ok
                @test any(
                    w -> w.kind === :tool_missing &&
                        w.host == DistSSHRun.PARENT_HOST_NAME &&
                        w.message == "git not found in PATH",
                    res.warnings,
                )
                @test occursin("Prerequisites not met", out)
                @test !occursin("Log file:", out)

                @test_throws ArgumentError DistSSHRun.setup!(session, :nope)
                @test_throws ArgumentError DistSSHRun.setup!(session, :delete, :check; ignore_julia_version = true)
            end
        end

        _with_fake_remotes() do _
            _with_tempdir() do proj
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                withenv("DISTSSHKIT_TEST_SSH_FAIL" => "1") do
                    clean = DistSSHRun.setup!(session, :cleanup)
                    @test clean isa DistSSHRun.SyncResult
                    @test !clean.cancelled
                    @test length(clean.hosts) == 1
                    @test !clean.hosts[1].ok
                end
            end
        end
    end

    @testset "confirm_path" begin
        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = false,
                    quiet = true,
                )
                delete_path = DistSSHRun.remote_delete_root(proj; cli_override = "~/App.jl")
                del = DistSSHRun.setup!(session, :delete; confirm_path = delete_path)
                @test del.ok && !del.cancelled
                @test !isdir(joinpath(state_dir, slot))
            end
        end

        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                mkpath(joinpath(tree, ".distsshkit", "go", "batch_a"))
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = false,
                    quiet = true,
                )
                prune_path = DistSSHRun.session_remote_root(session)
                pr = DistSSHRun.setup!(session, :prune; confirm_path = prune_path)
                @test pr.ok && !pr.cancelled
                @test isfile(joinpath(tree, "keepme.txt"))
                @test !isdir(joinpath(tree, ".distsshkit", "go", "batch_a"))
            end
        end

        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                slot = replace(host, r"[@:/]" => "_")
                tree = joinpath(state_dir, slot, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                log_dir = DistSSHRun.setup_log_dir(session.project)
                @test !isdir(log_dir)
                err = try
                    DistSSHRun.setup!(session, :delete; confirm_path = "/not/the/path")
                    nothing
                catch e
                    e
                end
                @test err isa DistSSHRun.ConfirmPathMismatch
                @test err.mode === :delete
                @test err.given == "/not/the/path"
                @test !isempty(err.expected)
                @test occursin("confirm_path", sprint(showerror, err))
                @test occursin("help setup", sprint(showerror, err))
                @test !occursin("--help", sprint(showerror, err))
                @test !isdir(log_dir)
                @test isfile(joinpath(tree, "keepme.txt"))

                missing = try
                    DistSSHRun.setup!(session, :delete)
                    nothing
                catch e
                    e
                end
                @test missing isa ArgumentError
                @test occursin("confirm_path", missing.msg)
                @test occursin("help setup", missing.msg)
                @test isfile(joinpath(tree, "keepme.txt"))

                blank = try
                    DistSSHRun.setup!(session, :delete; confirm_path = "  ")
                    nothing
                catch e
                    e
                end
                @test blank isa ArgumentError
                @test occursin("non-empty", blank.msg)
                @test !isdir(log_dir)
                @test isfile(joinpath(tree, "keepme.txt"))

                rsync_err = try
                    DistSSHRun.setup!(session, :ship_tree; confirm_path = "~/App.jl")
                    nothing
                catch e
                    e
                end
                @test rsync_err isa ArgumentError
                @test occursin("confirm_path", rsync_err.msg)
                @test isfile(joinpath(tree, "keepme.txt"))

                for modes in ((:delete, :prune), (:delete, :ship_tree))
                    chain_err = try
                        DistSSHRun.setup!(session, modes...; confirm_path = "~/App.jl")
                        nothing
                    catch e
                        e
                    end
                    @test chain_err isa ArgumentError
                    @test occursin("confirm_path", chain_err.msg)
                    @test occursin("multiple modes", chain_err.msg)
                end
                @test isfile(joinpath(tree, "keepme.txt"))
                @test !isdir(log_dir)
            end
        end
    end

    @testset "confirm_path hosts and normalization" begin
        @test DistSSHRun.normalize_remote_confirm_path("~/App.jl/") == "~/App.jl"
        @test DistSSHRun.normalize_remote_confirm_path("App.jl") == "~/App.jl"
        @test DistSSHRun.normalize_remote_confirm_path("/tmp//a/./b/") == "/tmp/a/b"
        @test DistSSHRun.normalize_remote_confirm_path("~/a/./b/") == "~/a/b"
        @test_throws ArgumentError DistSSHRun.normalize_remote_confirm_path("/tmp/../x")
        @test_throws ArgumentError DistSSHRun.normalize_remote_confirm_path("~/a/../b")
        @test_throws ArgumentError DistSSHRun.normalize_remote_confirm_path(".")

        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                for host in ("host1", "host2")
                    tree = joinpath(state_dir, host, "tree")
                    mkpath(tree)
                    touch(joinpath(tree, "keepme.txt"))
                end
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1", "child:host2"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                string_err = try
                    DistSSHRun.setup!(session, :delete; confirm_path = "~/App.jl")
                    nothing
                catch e
                    e
                end
                @test string_err isa ArgumentError
                @test occursin("one host", string_err.msg)
                @test occursin("help setup", string_err.msg)
                @test !occursin("--help", string_err.msg)
                @test isfile(joinpath(state_dir, "host1", "tree", "keepme.txt"))
                @test isfile(joinpath(state_dir, "host2", "tree", "keepme.txt"))

                unknown = try
                    DistSSHRun.setup!(
                        session, :delete;
                        confirm_path = Dict("host1" => "~/App.jl", "other" => "~/App.jl"),
                    )
                    nothing
                catch e
                    e
                end
                @test unknown isa ArgumentError
                @test occursin("unknown host", unknown.msg)
                @test isfile(joinpath(state_dir, "host1", "tree", "keepme.txt"))

                partial = DistSSHRun.setup!(
                    session, :delete;
                    confirm_path = Dict("host1" => "App.jl"),
                )
                @test partial.ok && !partial.cancelled
                @test [h.host for h in partial.hosts] == ["host1"]
                @test !isdir(joinpath(state_dir, "host1"))
                @test isfile(joinpath(state_dir, "host2", "tree", "keepme.txt"))

                token_key = try
                    DistSSHRun.setup!(
                        session, :delete;
                        confirm_path = Dict("child:host2" => "~/App.jl"),
                    )
                    nothing
                catch e
                    e
                end
                @test token_key isa ArgumentError
                @test occursin("unknown host", token_key.msg)
                @test isfile(joinpath(state_dir, "host2", "tree", "keepme.txt"))
            end
        end

        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                host = "host1"
                tree = joinpath(state_dir, host, "tree")
                mkpath(tree)
                touch(joinpath(tree, "keepme.txt"))
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = false,
                    quiet = true,
                )
                home = "/home/distsshkit"
                expanded = home * "/App.jl"
                withenv("DISTSSHKIT_TEST_REMOTE_HOME" => home) do
                    del = DistSSHRun.setup!(session, :delete; confirm_path = expanded)
                    @test del.ok && !del.cancelled
                end
                @test !isdir(joinpath(state_dir, host))
            end
        end
    end

    @testset "SSH preflight failure sets cancelled=false and map_host_jobs preserves order" begin
        _with_tempdir() do proj::String
            write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
            session = DistSSHRun.KitSession(
                project = proj,
                workers = ["child:h1", "child:h2"],
                remote = "~/App.jl",
                yes = true,
                quiet = true,
            )
            withenv(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => "/no/such/fake-ssh.jl",
            ) do
                res_setup = DistSSHRun.setup!(session, :runtest; julia = "/bin/echo")
                @test !res_setup.ok
                @test !res_setup.cancelled
                res_inst = DistSSHRun.instantiate!(session)
                @test !res_inst.ok
                @test !res_inst.cancelled
            end
        end

        _with_fake_remotes() do _
            _with_tempdir() do proj::String
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
                write(joinpath(proj, "Manifest.toml"), "# lock\n")
                hosts = ["h1", "h2", "h3"]
                inst_res = DistSSHRun.instantiate_remotes(
                    hosts, "/bin/echo", "~/App.jl", proj,
                )
                @test [r.host for r in inst_res.hosts] == hosts
                @test all(r -> r.ok, inst_res.hosts)
                test_res = DistSSHRun.runtest_remotes(
                    hosts, "/bin/echo", "~/App.jl", proj,
                )
                @test [r.host for r in test_res.hosts] == hosts
                @test all(r -> r.ok, test_res.hosts)
                clean_res = DistSSHRun.cleanup_remote_workers(hosts)
                @test [r.host for r in clean_res.hosts] == hosts
                @test all(r -> r.ok, clean_res.hosts)
            end
        end
    end
end
