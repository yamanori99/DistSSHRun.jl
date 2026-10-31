using Test

# Oracle: `collect!` skip / empty / tar-pull wiring via setup SSH fakes.
# Fake `Tar.create` exits 0 and writes no archive (or 1 when
# `DISTSSHKIT_TEST_TAR_PULL_FAIL=1`). Real collect of remote files is ssh-e2e.

# File scope: a local inside `@testset` is captured by `_capture_stdio` and boxed.
function _collect!(
        proj::AbstractString,
        out_dir::AbstractString,
        hosts::Vector{String};
        merge::Bool = false,
    )
    session = DistSSHRun.KitSession(
        project = proj,
        workers = hosts,
        remote = "/fake/remote/CollectHost",
    )
    return DistSSHRun.collect!(session, out_dir; merge = merge)
end

@testset "drive collect_tree" begin
    @testset "local symlink cannot leave the collect root" begin
        _with_tempdir() do root
            _with_tempdir() do outside
                symlink(outside, joinpath(root, "out"))
                @test DistSSHRun._collect_dest_escapes_root(root, "out/file.txt")
                @test DistSSHRun._collect_local_symlink_escape(root) == "out"
                @test !DistSSHRun._collect_dest_escapes_root(root, "kept.txt")
                write(joinpath(root, "kept.txt"), "ok\n")
                @test !DistSSHRun._collect_dest_escapes_root(root, "kept.txt")
                if !Sys.iswindows()
                    rm(joinpath(root, "out"))
                    symlink(outside, joinpath(root, "out\\side"))
                    @test DistSSHRun._collect_dest_escapes_root(root, "out\\side/file.txt")
                    @test DistSSHRun._collect_local_symlink_escape(root) == "out\\side"
                end
            end
        end
    end

    @testset "absolute remote paths and a symlinked collect root" begin
        _with_tempdir() do real
            mkdir(joinpath(real, "sub"))
            write(joinpath(real, "sub", "file.txt"), "ok\n")
            _with_tempdir() do holder
                link = joinpath(holder, "link")
                symlink(real, link)
                @test !DistSSHRun._collect_dest_escapes_root(link, "sub/file.txt")
                @test DistSSHRun._collect_local_symlink_escape(link) === nothing
                @test DistSSHRun._collect_dest_escapes_root(link, "/home/user/out/file")
                @test joinpath(link, "/home/user/out/file") == "/home/user/out/file"
            end
        end
    end

    function _seed_tree!(state_dir, host, rel)
        slot = replace(host, r"[@:/]" => "_")
        path = joinpath(state_dir, slot, "tree", rel)
        mkpath(dirname(path))
        write(path, "remote-bytes\n")
        return path
    end

    function _with_collect(f; extra_env = Dict{String, String}())
        _with_tempdir() do state_dir
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = \"CollectHost\"\n")
                remote = "/fake/remote/CollectHost"
                env = merge(
                    _fake_setup_remote_env(state_dir),
                    Dict(
                        "DISTRIBUTED_PROJECT_ROOT" => proj,
                        "DISTRIBUTED_REMOTE_PROJECT_ROOT" => remote,
                        "DISTSSHKIT_TEST_JULIA_WHICH" => "/usr/bin/julia",
                    ),
                    extra_env,
                )
                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!()
                withenv(env...) do
                    DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = true, yes = true))
                    return f(state_dir, proj)
                end
            end
        end
    end

    @testset "skip missing remote dir" begin
        _with_collect() do _, proj
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"])
                end
                @test result.ok
                @test occursin("no directory on host", captured)
            end
        end
    end

    @testset "empty remote" begin
        _with_collect() do state_dir, proj
            mkpath(joinpath(state_dir, "host1", "tree"))
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"])
                end
                @test result.ok
                @test occursin("no files found", captured)
            end
        end
    end

    @testset "collect-missing lists files and calls rsync" begin
        _with_collect() do state_dir, proj
            _seed_tree!(state_dir, "host1", joinpath("data", "a.txt"))
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"])
                end
                @test result.ok
                @test occursin("1 file", captured)
                # Parents may be mkdir'd; fake rsync does not write the file.
                @test !isfile(joinpath(out_dir, "data", "a.txt"))
            end
        end
    end

    @testset "collect-missing skips existing" begin
        _with_collect() do state_dir, proj
            _seed_tree!(state_dir, "host1", "a.txt")
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            write(joinpath(out_dir, "a.txt"), "local\n")
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"])
                end
                @test result.ok
                @test occursin("nothing new", captured)
                @test read(joinpath(out_dir, "a.txt"), String) == "local\n"
            end
        end
    end

    @testset "collect-overwrite calls rsync" begin
        _with_collect() do state_dir, proj
            _seed_tree!(state_dir, "host1", "a.txt")
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"]; merge = true)
                end
                @test result.ok
                @test occursin("synced", captured)
                @test !isfile(joinpath(out_dir, "a.txt"))
            end
        end
    end

    @testset "tar pull failure" begin
        _with_collect(; extra_env = Dict("DISTSSHKIT_TEST_TAR_PULL_FAIL" => "1")) do state_dir, proj
            _seed_tree!(state_dir, "host1", "a.txt")
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"]; merge = true)
                end
                @test !result.ok
                @test result.exit_code == 1
                @test occursin("some hosts failed", captured)
            end
        end
    end

    @testset "collect-missing find failure is not empty success" begin
        _with_collect(; extra_env = Dict("DISTSSHKIT_TEST_FIND_FAIL" => "1")) do state_dir, proj
            mkpath(joinpath(state_dir, "host1", "tree"))
            write(joinpath(state_dir, "host1", "tree", "a.txt"), "x\n")
            out_dir = joinpath(proj, "out")
            mkpath(out_dir)
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, out_dir, ["child:host1"])
                end
                @test !result.ok
                @test !occursin("no files found", captured)
                @test occursin("some hosts failed", captured)
            end
        end
    end

    @testset "post-run find failure sets HostRunResult" begin
        _with_collect(; extra_env = Dict("DISTSSHKIT_TEST_FIND_FAIL" => "1")) do state_dir, proj
            mkpath(joinpath(state_dir, "host1", "tree"))
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            out = joinpath(proj, "out")
            mkpath(out)
            withenv("DISTRIBUTED_OUTPUT_DIR" => out) do
                ok, hrs = DistSSHRun.collect_drive_results!(
                    ["host1"], dirname(script), ".drive_sentinel_x", false, proj, proj,
                )
                @test !ok
                @test length(hrs) == 1
                @test !hrs[1].ok
                @test hrs[1].error isa String
                @test occursin("find: failed", something(hrs[1].error, ""))
            end
        end
    end

    @testset "skip_collect does not place sentinels" begin
        _with_collect() do state_dir, proj
            logp = joinpath(state_dir, "ssh.log")
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            withenv("DISTSSHKIT_TEST_SSH_LOG" => logp) do
                name = DistSSHRun.place_drive_sentinels!(["host1"], dirname(script), true, proj)
                @test name == ""
            end
            @test !isfile(logp) || !occursin("mkdir", read(logp, String))
        end
    end

    @testset "sentinel per host and shared collect" begin
        @test DistSSHRun.drive_sentinel_for_host("s", "a b") == "s_a+20b"
        @test DistSSHRun.drive_sentinel_for_host("s", "a:b") !=
            DistSSHRun.drive_sentinel_for_host("s", "a_b")
        @test DistSSHRun.drive_sentinel_for_host("s", "a:b") == "s_a+3ab"
        @test DistSSHRun.drive_sentinel_for_host("s", "a_b") == "s_a+5fb"
        @test DistSSHRun.drive_sentinel_for_host("s", "h1") !=
            DistSSHRun.drive_sentinel_for_host("s", "h2")
        _with_collect(; extra_env = Dict("DISTSSHKIT_TEST_SHARED_TREE" => "1")) do state_dir, proj
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            out = joinpath(proj, "out")
            mkpath(out)
            mkpath(joinpath(state_dir, "shared", "tree"))
            withenv("DISTRIBUTED_OUTPUT_DIR" => out) do
                base = DistSSHRun.place_drive_sentinels!(
                    ["host1", "host2"], dirname(script), false, proj,
                )
                # After sentinels: a real `find -newer` includes this file.
                write(joinpath(state_dir, "shared", "tree", "a.txt"), "x\n")
                @test !isempty(base)
                captured, (ok, hrs) = _capture_stdio() do _, _
                    DistSSHRun.collect_drive_results!(
                        ["host1", "host2"], dirname(script), base, false, proj, proj,
                    )
                end
                @test ok
                @test all(h -> h.ok, hrs)
                @test occursin("more than one host", captured)
                @test !any(
                    f -> startswith(f, ".drive_sentinel_"),
                    Iterators.flatten((files for (_, _, files) in walkdir(out))),
                )
            end
        end
    end

    @testset "newline paths are skipped" begin
        captured, paths = _capture_stdio() do _, _
            DistSSHRun._find_print0_paths("plain.txt\0has\nline.txt\0")
        end
        @test paths == ["plain.txt"]
        @test occursin("newline", captured)
    end

    @testset "collect root overlap is an error" begin
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"CollectHost\"\n")
            out_ok, refused_inside = _capture_stdio() do _, _
                DistSSHRun._error_collect_root_overlap(joinpath(proj, "out"), proj)
            end
            @test refused_inside == false
            @test !occursin("Error:", out_ok)
            out_proj, refused_proj = _capture_stdio() do _, _
                DistSSHRun._error_collect_root_overlap(proj, proj)
            end
            @test refused_proj
            @test occursin("Error:", out_proj)
            @test occursin("collect root", out_proj)
            @test !occursin("will be an error", out_proj)
            @test !occursin("--help", out_proj)
            out_parent, refused_parent = _capture_stdio() do _, _
                DistSSHRun._error_collect_root_overlap(dirname(proj), proj)
            end
            @test refused_parent
            @test occursin("Error:", out_parent)
            withenv("DISTRIBUTED_COLLECT_DIRS" => ".") do
                roots = DistSSHRun.distributed_collect_root_dirs(proj, proj)
                @test length(roots) == 1
                @test rstrip(roots[1], '/') ==
                    rstrip(DistSSHRun.canonical_local_path(proj), '/')
            end
        end
        _with_collect() do state_dir, proj
            logp = joinpath(state_dir, "ssh.log")
            script = joinpath(proj, "job.jl")
            write(script, "true\n")
            withenv(
                "DISTSSHKIT_TEST_SSH_LOG" => logp,
                "DISTRIBUTED_COLLECT_DIRS" => ".",
            ) do
                captured, name = _capture_stdio() do _, _
                    DistSSHRun.place_drive_sentinels!(
                        ["host1"], dirname(script), false, proj,
                    )
                end
                @test name === nothing
                @test occursin("Error:", captured)
                @test occursin("collect root", captured)
                @test !occursin("--help", captured)
            end
            @test !isfile(logp) || !occursin("mkdir", read(logp, String))
            mkpath(joinpath(state_dir, "host1", "tree"))
            with_kit_verbosity(:verbose) do
                captured, result = _capture_stdio() do _, _
                    _collect!(proj, proj, ["child:host1"])
                end
                @test !result.ok
                @test result.exit_code == 1
                @test count("Error:", captured) == 1
                @test occursin("collect root", captured)
                @test !occursin("will be an error", captured)
                @test !occursin("collect-missing", captured)
            end
        end
    end

    @testset "collect warnings are ordered and find stderr is kept" begin
        e = DistSSHRun._collect_find_failure(
            "host1", ErrorException("fail"), "find: no such file\n",
        )
        @test e.msg == "collect find -newer on host1: fail: find: no such file"
        long = DistSSHRun._collect_find_failure("h", ErrorException("x"), "e"^300)
        @test endswith(long.msg, "…")
        @test length(long.msg) < 400
        lines = withenv("DISTSSHKIT_JOBS" => "1") do
            DistSSHRun._collect_dup_warning_lines(
                Dict(
                    ("root", "b.txt") => ["z", "a", "a"],
                    ("root", "a.txt") => ["m", "a"],
                    ("root-b", "same.txt") => ["m", "b"],
                    ("root-a", "same.txt") => ["z", "a"],
                ),
            )
        end
        @test lines == [
            "4 result path(s) came from more than one host. The last transfer remains.",
            "  a.txt (a, m)",
            "  b.txt (a, z)",
            "  same.txt (a, z)",
            "  same.txt (b, m)",
        ]
        @test DistSSHRun._collect_escape_line("out/x", "/tmp/root") ==
            "Warning: skipping out/x; it would write outside /tmp/root."
    end
end
