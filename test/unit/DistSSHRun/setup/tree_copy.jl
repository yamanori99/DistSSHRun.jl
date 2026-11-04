using Test

# Tar pull, dest status, ship confirm, and the gitignore send list.

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
        @test occursin("unset JULIA_PROJECT", sh)
        @test occursin("JULIA_DEPOT_PATH=", sh)
        @test occursin("JULIA_LOAD_PATH=@stdlib", sh)
        @test occursin("--compiled-modules=existing", sh)
        @test occursin("--startup-file=no", sh)
        @test occursin("exec ", sh)
        @test !occursin("env -u JULIA_PROJECT", sh)
        filtered = DistSSHRun._remote_tar_create_sh("/opt/julia/bin/julia", "/remote/out"; filtered = true)
        @test occursin("Tar.create", filtered)
        @test occursin("/opt/julia/bin/julia", filtered)
        @test occursin("stdin", filtered)
        @test occursin("unset JULIA_PROJECT", filtered)
        eq = DistSSHRun._remote_stdlib_julia_e("/opt/julia=1.13/bin/julia", "using Tar")
        @test occursin("unset JULIA_PROJECT", eq)
        @test occursin("exec ", eq)
        @test occursin("/opt/julia=1.13/bin/julia", eq)
        @test !occursin(r"env .*/opt/julia=1\.13/bin/julia", eq)
    end

    @testset "stdlib julia helper does not write an isolated depot" begin
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        extract = DistSSHRun._remote_stdlib_julia_e(
            julia,
            "using Tar; isdir(ARGS[1]) || mkdir(ARGS[1]); Tar.extract(stdin, ARGS[1])";
            args = String["/src"],
        )
        @test occursin("Tar.extract", extract)
        @test occursin("--compiled-modules=existing", extract)
        @test occursin("JULIA_DEPOT_PATH=", extract)
        _with_tempdir() do tmp
            depot = joinpath(tmp, "depot")
            dummy = joinpath(tmp, "proj")
            mkpath(depot)
            mkpath(dummy)
            write(joinpath(dummy, "Project.toml"), "name = \"Dummy\"\n")
            script = DistSSHRun._remote_stdlib_julia_e(julia, "using Tar; print(string(Tar))")
            out = withenv(
                "JULIA_DEPOT_PATH" => depot,
                "JULIA_PROJECT" => dummy,
                "JULIA_LOAD_PATH" => dummy,
            ) do
                return read(`sh -c $script`, String)
            end
            @test occursin("Tar", out)
            @test !isdir(joinpath(depot, "compiled"))
            @test !isdir(joinpath(depot, "packages"))
            leftover = readdir(depot)
            @test isempty(leftover)
        end
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
        mktempdir() do tmp
            src = joinpath(tmp, "src")
            dest = joinpath(tmp, "dest")
            mkpath(joinpath(src, "sub"))
            write(joinpath(src, "sub", "file"), "secret\n")
            mkpath(dest)
            outside = mktempdir()
            try
                symlink(outside, joinpath(dest, "sub"))
                @test_throws ArgumentError DistSSHRun._copy_pulled_rels!(src, dest, ["sub/file"])
                @test !isfile(joinpath(outside, "file"))
            finally
                rm(outside; force = true, recursive = true)
            end
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
            dest = joinpath(tmp, "dest")
            script = DistSSHRun._remote_tar_create_sh(julia, src; filtered = true)
            withenv("JULIA_LOAD_PATH" => _child_load_path()) do
                open(blob, "w") do io
                    run(pipeline(`sh -c $script`; stdin = IOBuffer("keep/a.txt\0empty\0"), stdout = io))
                end
                mkpath(dest)
                run(`$julia --startup-file=no -e "using Tar; Tar.extract(ARGS[1], ARGS[2])" $blob $dest`)
            end
            @test read(joinpath(dest, "keep", "a.txt"), String) == "a\n"
            @test isdir(joinpath(dest, "empty"))
            @test !ispath(joinpath(dest, "skip.txt"))
        end
    end

    @testset "ssh -e quotes the transport" begin
        Sys.which("ssh") === nothing && return
        withenv("DISTSSHKIT_TEST_SSH" => nothing) do
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
            "DISTSSHKIT_TEST_LOCAL_JULIAUP" => "/tmp/distsshkit-not-a-juliaup",
        ) do
            cmd = DistSSHRun._host_sync_remote_shell_cmd("host.test", "true")
            @test cmd.exec[1] == DistSSHRun._ssh_exe()
            @test !in("/tmp/distsshkit-not-a-juliaup", DistSSHRun.DistSSHBase.local_juliaup_candidates())
        end
        withenv(
            "DISTSSHKIT_TEST" => nothing,
            "DISTSSHKIT_TEST_SSH" => nothing,
            "DISTRIBUTED_SSH_OPTS" => "-F \"/tmp/cfg dir/config\" -o BatchMode=yes",
        ) do
            @test DistSSHRun.ssh_opts() == ["-F", "/tmp/cfg dir/config", "-o", "BatchMode=yes"]
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

@testset "rsync gitignore keyword" begin
    Sys.which("git") === nothing && return

    _with_tempdir() do tmp
        src = joinpath(tmp, "proj")
        mkpath(src)
        _gitignore_tree!(src)
        _gitignore_git!(src)
        env = DistSSHRun.resolve_pkg_env(src)
        listed = DistSSHRun._rsync_send_list(env.env_dir, env; warn = false)
        @test listed isa Vector
        got = Set(listed)
        @test "data/input.csv" in got
        @test "Manifest.toml" in got
        @test "src/a.jl" in got
        @test "data/tmp.csv" ∉ got
        @test "Manifest-v1.13.toml" ∉ got
        @test ".distsshkit/marker" ∉ got
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
