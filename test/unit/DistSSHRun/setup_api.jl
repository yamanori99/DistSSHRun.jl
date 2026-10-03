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
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:$host"],
                    remote = "~/App.jl",
                    yes = true,
                    quiet = true,
                )
                del = DistSSHRun.setup!(session, :delete)
                @test del.ok && !del.cancelled
                @test length(del.hosts) == 1 && del.hosts[1].ok
                @test !isdir(joinpath(state_dir, slot))
                prog = joinpath(proj, ".distsshkit", "setup", "kit.progress")
                @test isfile(prog)
                body = read(prog, String)
                @test occursin("kind=setup", body)
                @test occursin("label=delete/$host", body)

                # Fresh empty remote then rsync+instantiate path (fake rsync creates tree).
                chained = DistSSHRun.setup!(session, :rsync)
                @test chained isa DistSSHRun.SyncResult
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
            n2 = DistSSHRun.prune_kit_leaf_dirs!(proj)
            @test n2 >= 3
            @test !isdir(go_old)
            @test !isdir(drive)
            @test !isdir(run_old)
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
                pr = DistSSHRun.setup!(session, :prune)
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
                empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
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
                    empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
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
                    ch = "$(VERSION.major).$(VERSION.minor)"
                    @test occursin("$host: already on $ch", out)
                end
                withenv("DISTSSHKIT_TEST_NO_JULIAUP" => "1") do
                    empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
                    bad = DistSSHRun.setup!(session, :juliaup)
                    @test !bad.ok
                end
                ssh_log = joinpath(proj, "ssh.log")
                withenv(ver_env..., "DISTSSHKIT_TEST_SSH_LOG" => ssh_log) do
                    empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
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
                    empty!(DistSSHRun._DETECT_JULIA_PATH_CACHE)
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
                withenv("DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
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
                withenv("DISTSSHKIT_TEST_LOCAL_JULIAUP" => ju) do
                    upd = DistSSHRun.setup!(session, :juliaup_update)
                    @test upd.ok && !upd.cancelled
                    @test length(upd.hosts) == 1 && upd.hosts[1].ok
                    @test upd.hosts[1].host == "parent"
                    @test strip(read(logp, String)) == "update"
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
                        DistSSHRun.setup!(session, :delete)
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

    @testset "multi-mode stops after rsync refuse" begin
        _with_fake_remotes() do state_dir
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"Tmp\"\n")
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
                _, res = _capture_stdio() do _, _
                    DistSSHRun.setup!(session, :rsync, :instantiate)
                end
                @test !res.ok
                # Nonempty tree still there: instantiate must not have been the stop reason.
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
                out, res = _capture_stdio() do _, _
                    DistSSHRun.setup!(session, :check; check_code_sync = false, ignore_julia_version = true)
                end
                @test res isa DistSSHRun.SyncResult
                @test !res.cancelled
                @test !res.ok
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
end
