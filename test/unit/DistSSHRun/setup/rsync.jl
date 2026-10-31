using Test

# Module setup rsync / clone dest messaging (CLI exit codes in integration/setup/exit.jl).

@testset "setup rsync" begin
    remote_path = "~/App.jl"

    function _with_fake_remotes(f::Function; extra_env = Dict{String, String}())
        _with_tempdir() do state_dir
            withenv(merge(_fake_setup_remote_env(state_dir), extra_env)...) do
                _apply_quiet_setup_session!()
                return f(state_dir)
            end
        end
    end

    function _mark_nonempty!(state_dir::AbstractString, host::AbstractString)
        slot = replace(host, r"[@:/]" => "_")
        tree = joinpath(state_dir, slot, "tree")
        mkpath(tree)
        touch(joinpath(tree, "keepme.txt"))
    end

    @testset "tar pull refuses an escaping symlink" begin
        mktempdir() do dest
            outside = joinpath(dirname(dest), "tar-pull-secret")
            write(outside, "nope\n")
            write(joinpath(dest, "a.txt"), "a\n")
            symlink(outside, joinpath(dest, "link"))
            try
                @test_throws ArgumentError DistSSHRun._finish_extracted_tree!(dest)
            finally
                rm(outside; force = true)
            end
        end
        mktempdir() do dest
            write(joinpath(dest, "a.txt"), "a\n")
            @test DistSSHRun._finish_extracted_tree!(dest) === nothing
        end
        filled = mktempdir()
        write(joinpath(filled, "x"), "x")
        @test_throws ArgumentError DistSSHRun._extract_remote_tar!(
            "host.test", "/remote/out", filled; julia_bin = "julia",
        )
        rm(filled; force = true, recursive = true)
        sh = DistSSHRun._remote_tar_create_sh("julia", "/remote/out")
        @test occursin("Tar.create", sh)
        @test occursin("/remote/out", sh)
        @test occursin("julia", sh)
        filtered = DistSSHRun._remote_tar_create_sh("/opt/julia/bin/julia", "/remote/out"; filtered = true)
        @test occursin("Tar.create", filtered)
        @test occursin("/opt/julia/bin/julia", filtered)
        @test occursin("stdin", filtered)
    end

    @testset "tar pull checks each symlink hop and does not touch it" begin
        mktempdir() do dest
            outside = mktempdir()
            try
                symlink(outside, joinpath(dest, "inside"))
                symlink(joinpath("inside", "secret"), joinpath(dest, "link"))
                @test_throws ArgumentError DistSSHRun._finish_extracted_tree!(dest)
                @test !ispath(joinpath(outside, "secret"))
            finally
                rm(outside; force = true, recursive = true)
            end
        end
        mktempdir() do dest
            outside = mktempdir()
            try
                symlink(outside, joinpath(dest, "dirlink"))
                @test_throws ArgumentError DistSSHRun._finish_extracted_tree!(dest)
            finally
                rm(outside; force = true, recursive = true)
            end
        end
        mktempdir() do dest
            mkpath(joinpath(dest, "sub"))
            write(joinpath(dest, "sub", "a.txt"), "a\n")
            symlink(joinpath("sub", "a.txt"), joinpath(dest, "link"))
            @test DistSSHRun._finish_extracted_tree!(dest) === nothing
            @test islink(joinpath(dest, "link"))
            @test readlink(joinpath(dest, "link")) == joinpath("sub", "a.txt")
        end
    end

    @testset "collect copy keeps a local directory" begin
        mktempdir() do tmp
            src = joinpath(tmp, "src")
            dest = joinpath(tmp, "dest")
            write(src, "file\n")
            mkpath(dest)
            write(joinpath(dest, "keep"), "keep\n")
            @test_throws ArgumentError DistSSHRun._copy_collected_path!(src, dest)
            @test read(joinpath(dest, "keep"), String) == "keep\n"
        end
        mktempdir() do tmp
            mkpath(joinpath(tmp, "empty"))
            write(joinpath(tmp, "a.txt"), "a\n")
            symlink("a.txt", joinpath(tmp, "link"))
            rels = Set(DistSSHRun._extracted_rel_paths(tmp))
            @test "empty" in rels
            @test "a.txt" in rels
            @test "link" in rels
        end
    end

    @testset "filtered tar archives only requested paths" begin
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        mktempdir() do tmp
            src = joinpath(tmp, "src")
            mkpath(joinpath(src, "keep"))
            write(joinpath(src, "keep", "a.txt"), "a\n")
            write(joinpath(src, "skip.txt"), "no\n")
            mkpath(joinpath(src, "empty"))
            blob = joinpath(tmp, "out.tar")
            script = DistSSHRun._remote_tar_create_sh(julia, src; filtered = true)
            open(blob, "w") do io
                run(pipeline(`sh -c $script`; stdin = IOBuffer("keep/a.txt\0empty\0"), stdout = io))
            end
            dest = joinpath(tmp, "dest")
            mkpath(dest)
            run(`$julia --startup-file=no -e "using Tar; Tar.extract(ARGS[1], ARGS[2])" $blob $dest`)
            @test read(joinpath(dest, "keep", "a.txt"), String) == "a\n"
            @test isdir(joinpath(dest, "empty"))
            @test !ispath(joinpath(dest, "skip.txt"))
        end
    end

    @testset "pull rsync uses --safe-links" begin
        opts = DistSSHRun._pull_rsync_opts("ssh -o BatchMode=yes")
        @test opts[1] == "-az"
        @test "--safe-links" in opts
        @test "-e" in opts
        system_rsync = Sys.which("rsync")
        system_rsync === nothing && return
        mktempdir() do tmp::String
            src = joinpath(tmp, "src")
            dest = joinpath(tmp, "dest")
            outside = joinpath(tmp, "secret.txt")
            mkpath(src)
            mkpath(dest)
            write(outside, "secret\n")
            write(joinpath(src, "ok.txt"), "ok\n")
            symlink(outside, joinpath(src, "escape"))
            DistSSHRun._run_rsync_files_from(
                [String(system_rsync)],
                DistSSHRun._pull_rsync_opts("ssh"),
                src * "/",
                dest * "/",
                ["ok.txt", "escape"],
            )
            @test isfile(joinpath(dest, "ok.txt"))
            @test !ispath(joinpath(dest, "escape"))
        end
    end

    @testset "files-from uses NUL and protects comment prefixes" begin
        mktempdir() do tmp::String
            rsync = joinpath(tmp, "rsync")
            argv = joinpath(tmp, "argv")
            list = joinpath(tmp, "list")
            write(
                rsync,
                """
                #!/bin/sh
                printf '%s\\n' "\$@" > "\$FAKE_RSYNC_ARGV"
                for arg in "\$@"; do
                  case "\$arg" in
                    --files-from=*)
                      cp "\${arg#--files-from=}" "\$FAKE_RSYNC_LIST"
                      ;;
                  esac
                done
                """,
            )
            chmod(rsync, 0o755)
            withenv("FAKE_RSYNC_ARGV" => argv, "FAKE_RSYNC_LIST" => list) do
                DistSSHRun._run_rsync_files_from(
                    [rsync],
                    ["-az"],
                    "/source/",
                    "host:/dest/",
                    ["plain.txt", "#hash.txt", ";semi.txt"],
                )
            end
            args = read(argv, String)
            @test occursin("--from0", args)
            @test occursin("--files-from=", args)
            entries = Set(split(read(list, String), '\0'; keepempty = false))
            @test entries == Set(["plain.txt", "./#hash.txt", "./;semi.txt"])

            system_rsync = Sys.which("rsync")
            if system_rsync !== nothing
                src = joinpath(tmp, "src")
                dest = joinpath(tmp, "dest")
                mkpath(src)
                for name in ("plain.txt", "#hash.txt", ";semi.txt")
                    write(joinpath(src, name), name)
                end
                DistSSHRun._run_rsync_files_from(
                    [String(system_rsync)],
                    ["-a"],
                    src * "/",
                    dest * "/",
                    ["plain.txt", "#hash.txt", ";semi.txt"],
                )
                @test Set(readdir(dest)) == Set(["plain.txt", "#hash.txt", ";semi.txt"])
            end
        end
    end

    @testset "rsync -e quotes ssh" begin
        Sys.which("ssh") === nothing && return
        withenv("DISTSSHKIT_TEST_SSH" => nothing) do
            t = DistSSHRun._host_sync_rsync_transport()
            @test startswith(t, Base.shell_escape(DistSSHRun._ssh_exe()))
            cmd = DistSSHRun._host_sync_remote_shell_cmd("host.test", "true")
            @test cmd.exec[1] == DistSSHRun._ssh_exe()
            @test "-n" in cmd.exec
            fed = DistSSHRun._host_sync_remote_shell_cmd(
                "host.test", "true"; forward_stdin = true,
            )
            @test !("-n" in fed.exec)
        end
        withenv(
            "DISTSSHKIT_TEST" => nothing,
            "DISTSSHKIT_TEST_SSH" => "/tmp/distsshkit-not-a-test.jl",
            "DISTSSHKIT_TEST_RSYNC" => "/tmp/distsshkit-not-a-test.sh",
            "DISTSSHKIT_TEST_LOCAL_JULIAUP" => "/tmp/distsshkit-not-a-juliaup",
        ) do
            cmd = DistSSHRun._host_sync_remote_shell_cmd("host.test", "true")
            @test cmd.exec[1] == DistSSHRun._ssh_exe()
            if Sys.which("rsync") !== nothing
                @test DistSSHRun._host_sync_rsync_argv() != ["sh", "/tmp/distsshkit-not-a-test.sh"]
            end
            @test !in("/tmp/distsshkit-not-a-juliaup", DistSSHRun.DistSSHBase.local_juliaup_candidates())
        end
        withenv(
            "DISTSSHKIT_TEST" => nothing,
            "DISTSSHKIT_TEST_SSH" => nothing,
            "DISTRIBUTED_SSH_OPTS" => "-F \"/tmp/cfg dir/config\" -o BatchMode=yes",
        ) do
            @test DistSSHRun.ssh_opts() == ["-F", "/tmp/cfg dir/config", "-o", "BatchMode=yes"]
            t = DistSSHRun._host_sync_rsync_transport()
            @test occursin(Base.shell_escape("/tmp/cfg dir/config"), t)
        end
        withenv("DISTRIBUTED_SSH_OPTS" => "-F \"unterminated") do
            @test_throws ArgumentError DistSSHRun.ssh_opts()
        end
        withenv("DISTRIBUTED_SSH_OPTS" => nothing) do
            @test "BatchMode=yes" in DistSSHRun.ssh_opts()
        end
    end

    @testset "remote_dir / ensure" begin
        _with_fake_remotes() do _
            host = "user@host.test"
            @test DistSSHRun.remote_dir_exists(host, remote_path) == false
            @test DistSSHRun.ensure_remote_dir(host, remote_path) == true
            @test DistSSHRun.remote_dest_status(host, remote_path) === :empty
        end
        _with_fake_remotes(extra_env = Dict("DISTSSHKIT_TEST_MKDIR_FAIL" => "1")) do _
            @test DistSSHRun.ensure_remote_dir("user@host.test", remote_path) == false
        end
    end

    @testset "rsync outcomes" begin
        # A user tree. The package checkout path-depends on this repo, which
        # setup correctly refuses to ship.
        smoke_project = mktempdir()
        write(joinpath(smoke_project, "Project.toml"), "name = \"RsyncSmoke\"\n")
        write(joinpath(smoke_project, "Manifest.toml"), "# lock\n")
        write(joinpath(smoke_project, "smoke.jl"), "smoke = 1\n")
        if Sys.which("git") !== nothing
            run(`git -C $smoke_project init --quiet`)
            run(`git -C $smoke_project config user.email t@t.t`)
            run(`git -C $smoke_project config user.name t`)
            run(`git -C $smoke_project add -A`)
            run(`git -C $smoke_project commit --quiet -m init`)
        end
        withenv("DISTSSHKIT_YES" => nothing) do
            prev_ni = DistSSHRun.kit_noninteractive()
            DistSSHRun.set_kit_noninteractive!(false)
            try
                for v in (:quiet, :progress, :verbose)
                    with_kit_verbosity(v) do
                        _with_active_kit_progress() do _
                            out, result, nsus = _capture_stdio(; probe_suspend = true) do stdin_io, _
                                println(stdin_io, "")
                                flush(stdin_io)
                                seekstart(stdin_io)
                                DistSSHRun.ship_project_to_hosts!(
                                    ["host1"], smoke_project, remote_path; confirm = true,
                                )
                            end
                            @test result.cancelled
                            @test occursin("Cancelled.", out)
                            @test occursin("Type 'ship-tree'", out)
                            # #374: bar is suspended while stdin is read, then released.
                            @test nsus >= 1
                            @test DistSSHRun.KIT_PROGRESS_SUSPEND[] == 0
                        end
                    end
                end
            finally
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end

        _with_fake_remotes(extra_env = Dict("DISTSSHKIT_TEST_MKDIR_FAIL" => "1")) do _
            raw = DistSSHRun.rsync_project_to_hosts!(
                ["host1"], smoke_project, remote_path; confirm = false, report = false,
            )
            @test raw.succeeded == 0 && raw.failed == 1
        end

        _with_fake_remotes() do _
            raw = DistSSHRun.rsync_project_to_hosts!(
                ["host1"], smoke_project, remote_path; confirm = false, report = false,
            )
            @test raw.succeeded == 1 && raw.failed == 0
        end

        _with_fake_remotes() do _
            withenv("DISTSSHKIT_JOBS" => "2") do
                raw = DistSSHRun.rsync_project_to_hosts!(
                    ["host1", "host2"], smoke_project, remote_path; confirm = false, report = false,
                )
                @test raw.succeeded == 2 && raw.failed == 0
                @test [hr.host for hr in raw.host_results] == ["host1", "host2"]
            end
        end

        _with_fake_remotes() do state_dir
            host = "user@host.test"
            _mark_nonempty!(state_dir, host)
            DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = false, yes = true))
            _, result = _capture_stdio() do _, _
                DistSSHRun.rsync_project_to_hosts!(
                    [host], smoke_project, remote_path; confirm = false, report = false,
                )
            end
            @test result.cancelled == false && result.failed == 1
            @test occursin("refusing to overwrite", result.host_results[1].message)
        end

        _with_fake_remotes(extra_env = Dict("DISTSSHKIT_TEST_RSYNC_FAIL" => "1")) do _
            raw = DistSSHRun.rsync_project_to_hosts!(
                ["host1"], smoke_project, remote_path; confirm = false, report = false,
            )
            @test raw.succeeded == 0 && raw.failed == 1
        end
    end

    @testset "probe failure is not a nonempty tree" begin
        _with_fake_remotes(extra_env = Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1")) do _
            host = "user@host.test"
            status, detail = DistSSHRun._remote_dest_probe(host, remote_path)
            @test status === :error
            @test occursin("Permission denied", detail)
            @test DistSSHRun.remote_dest_status(host, remote_path) === :nonempty
        end
    end
end

function _gitignore_tree!(dir::String)
    write(joinpath(dir, "Project.toml"), "name = \"App\"\n")
    write(
        joinpath(dir, ".gitignore"),
        "*.csv\n!data/input.csv\nManifest*.toml\n!Manifest.toml\n",
    )
    mkpath(joinpath(dir, "data"))
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, ".distsshkit"))
    write(joinpath(dir, "data", "input.csv"), "in\n")
    write(joinpath(dir, "data", "tmp.csv"), "tmp\n")
    write(joinpath(dir, "Manifest.toml"), "manifest\n")
    write(joinpath(dir, "Manifest-v1.13.toml"), "old\n")
    write(joinpath(dir, "src", "a.jl"), "1\n")
    write(joinpath(dir, ".distsshkit", "marker"), "x\n")
    return nothing
end

function _gitignore_git!(dir::String)
    run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.email "t@example.com"`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.name "T"`; stdout = devnull, stderr = devnull))
    return nothing
end

function _gitignore_names(dest::String)::Set{String}
    out = Set{String}()
    for (root, _, files) in walkdir(dest)
        rel = relpath(root, dest)
        for f in files
            push!(out, rel == "." ? f : joinpath(rel, f))
        end
    end
    return out
end

const _GITIGNORE_ALL5 = Set(
    [
        "data/input.csv",
        "data/tmp.csv",
        "Manifest.toml",
        "Manifest-v1.13.toml",
        "src/a.jl",
    ]
)

function _gitignore_copy_list!(bin::String, src::String, dest::String)
    env = DistSSHRun.resolve_pkg_env(src)
    listed = DistSSHRun._rsync_send_list(env.env_dir, env; warn = false)
    @test listed isa Vector
    DistSSHRun._run_rsync_files_from(
        [bin],
        ["-a", "--exclude", ".git/", "--exclude", ".distsshkit/"],
        src * "/",
        dest * "/",
        listed,
    )
    return nothing
end

function _gitignore_copy_tree!(bin::String, src::String, dest::String; gitignore::Bool)
    run(
        pipeline(
            DistSSHRun._rsync_tree_cmd([bin], "ssh", src, dest * "/"; gitignore = gitignore);
            stderr = devnull,
        )
    )
    return nothing
end

@testset "rsync gitignore keyword" begin
    raw = Sys.which("rsync")
    raw === nothing && return
    bin = String(raw)

    _with_tempdir() do tmp
        src = joinpath(tmp, "proj")
        mkpath(src)
        _gitignore_tree!(src)
        _gitignore_git!(src)
        dest = joinpath(tmp, "dest")
        mkpath(dest)
        _gitignore_copy_list!(bin, src, dest)
        got = _gitignore_names(dest)
        @test "data/input.csv" in got
        @test "Manifest.toml" in got
        @test "src/a.jl" in got
        @test "data/tmp.csv" ∉ got
        @test "Manifest-v1.13.toml" ∉ got
        @test ".distsshkit/marker" ∉ got
    end

    _with_tempdir() do tmp
        src = joinpath(tmp, "proj")
        mkpath(src)
        _gitignore_tree!(src)
        dest = joinpath(tmp, "dest")
        mkpath(dest)
        _gitignore_copy_tree!(bin, src, dest; gitignore = true)
        got = _gitignore_names(dest)
        @test "data/input.csv" ∉ got
        @test "Manifest.toml" ∉ got
        @test "data/tmp.csv" ∉ got
        @test "Manifest-v1.13.toml" ∉ got
        @test "src/a.jl" in got
    end

    for inside in (false, true)
        _with_tempdir() do tmp
            src = joinpath(tmp, "proj")
            mkpath(src)
            _gitignore_tree!(src)
            inside && _gitignore_git!(src)
            dest = joinpath(tmp, "dest")
            mkpath(dest)
            _gitignore_copy_tree!(bin, src, dest; gitignore = false)
            got = _gitignore_names(dest)
            @test _GITIGNORE_ALL5 ⊆ got
            @test ".distsshkit/marker" ∉ got
            @test !any(n -> n == ".git" || startswith(n, ".git/"), got)
        end
    end

    session = DistSSHRun.KitSession(
        project = pwd(), workers = ["child:h"], yes = true, quiet = true,
    )
    sync_err = try
        DistSSHRun.sync!(session; mode = :sync, gitignore = false)
        nothing
    catch e
        e
    end
    @test sync_err isa ArgumentError
    @test occursin("gitignore", sync_err.msg)
    setup_err = try
        DistSSHRun.setup!(session, :check; gitignore = false)
        nothing
    catch e
        e
    end
    @test setup_err isa ArgumentError
    @test occursin("gitignore", setup_err.msg)
end

@testset "setup clone dest safety" begin
    remote_path = "~/App.jl"

    _with_tempdir() do state_dir
        withenv(_fake_setup_remote_env(state_dir)...) do
            DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = false, yes = true))
            host = "host1"
            slot = replace(host, r"[@:/]" => "_")
            tree = joinpath(state_dir, slot, "tree")
            mkpath(tree)
            touch(joinpath(tree, "keepme.txt"))
            out, result = _capture_stdio() do _, _
                DistSSHRun.clone_to_remotes(
                    [host], remote_path, "git@example.com:org/App.jl.git",
                )
            end
            @test !result.cancelled && result.succeeded == 0 && result.failed == 1
            @test length(result.hosts) == 1 && !result.hosts[1].ok
            @test occursin("refusing to overwrite", out)
            @test isfile(joinpath(tree, "keepme.txt"))
        end
    end

    @testset "forbidden remote dest and clone parent" begin
        @test_throws ArgumentError DistSSHRun.prune_kit_leaves(
            ["host1"], "/", pwd(); confirm = false,
        )
        @test occursin("pwd -P", DistSSHRun._prune_remote_shell("~/App.jl"))
        @test occursin("refusing to prune", DistSSHRun._prune_remote_shell("~/App.jl"))
        @test DistSSHRun._remote_clone_parent("~/jobs/App") == "~/jobs"
        @test DistSSHRun._remote_clone_parent("~/App") === nothing
        @test DistSSHRun._remote_clone_parent("/tmp/jobs/App") == "/tmp/jobs"
    end
end
