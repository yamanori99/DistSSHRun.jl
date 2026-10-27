using Test

@testset "distributed" begin
    _with_tempdir() do tmp
        repo = tmp
        sd = joinpath(repo, "scripts")
        mkpath(sd)
        out2 = joinpath(repo, "nested", "out2")
        withenv(
            "DISTRIBUTED_COLLECT_DIRS" => "out1:$(out2)",
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(repo, "ignored"),
        ) do
            roots = DistSSHRun.distributed_collect_root_dirs(sd, repo)
            @test roots == String[abspath(joinpath(repo, "out1")), abspath(out2)]
        end
        withenv(
            "DISTRIBUTED_COLLECT_DIRS" => "out1:out1",
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(repo, "ignored"),
        ) do
            roots = DistSSHRun.distributed_collect_root_dirs(sd, repo)
            @test roots == String[abspath(joinpath(repo, "out1"))]
        end
        withenv(
            "DISTRIBUTED_COLLECT_DIRS" => "",
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(repo, "solo"),
        ) do
            @test DistSSHRun.distributed_collect_root_dirs(sd, repo) ==
                String[abspath(joinpath(repo, "solo"))]
        end
    end

    _with_tempdir() do tmp
        default = joinpath(tmp, "output")
        withenv("DISTRIBUTED_OUTPUT_DIR" => nothing) do
            @test DistSSHRun.resolve_distributed_output_dir!(String[], default) == abspath(default)
            @test ENV["DISTRIBUTED_OUTPUT_DIR"] == abspath(default)
        end

        custom = joinpath(tmp, "custom")
        withenv("DISTRIBUTED_OUTPUT_DIR" => custom) do
            @test DistSSHRun.resolve_distributed_output_dir!(String[], default) == abspath(custom)
        end

        from_args = joinpath(tmp, "from_args")
        withenv("DISTRIBUTED_OUTPUT_DIR" => "") do
            got = DistSSHRun.resolve_distributed_output_dir!(
                String["--output-dir", from_args],
                default,
            )
            @test got == abspath(from_args)
        end
    end

    @testset "resolve_drive_output_dir" begin
        _with_tempdir() do tmp
            script_dir = joinpath(tmp, "app")
            mkpath(script_dir)
            withenv("DISTRIBUTED_OUTPUT_DIR" => nothing) do
                got = DistSSHRun.resolve_drive_output_dir(script_dir)
                @test got == DistSSHRun.kit_dir_beside_script(script_dir, :drive)
            end
            explicit = joinpath(tmp, "explicit-out")
            withenv("DISTRIBUTED_OUTPUT_DIR" => explicit) do
                got = DistSSHRun.resolve_drive_output_dir(script_dir)
                @test got == DistSSHRun.canonical_local_path(explicit)
            end
        end
    end

    @testset "resolve_drive_log_dir" begin
        _with_tempdir() do tmp
            script_dir = joinpath(tmp, "app")
            mkpath(script_dir)
            withenv(
                "DISTRIBUTED_OUTPUT_DIR" => nothing,
                DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => nothing,
            ) do
                @test DistSSHRun.resolve_drive_log_dir(nothing, script_dir) ==
                    DistSSHRun.kit_dir_beside_script(script_dir, :drive)
            end
            run_dir = joinpath(tmp, "run")
            mkpath(run_dir)
            withenv(
                "DISTRIBUTED_OUTPUT_DIR" => joinpath(tmp, "env-out"),
                DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => run_dir,
            ) do
                @test DistSSHRun.resolve_drive_log_dir(nothing, script_dir) ==
                    DistSSHRun.canonical_local_path(run_dir)
            end
            env_dir = joinpath(tmp, "env-out")
            withenv(
                "DISTRIBUTED_OUTPUT_DIR" => env_dir,
                DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => nothing,
            ) do
                @test DistSSHRun.resolve_drive_log_dir(nothing, script_dir) == env_dir
                explicit = joinpath(tmp, "explicit-logs")
                @test DistSSHRun.resolve_drive_log_dir(explicit, script_dir) == explicit
            end
        end
    end

    @testset "prepare_output_dir!" begin
        _with_tempdir() do tmp
            missing = joinpath(tmp, "missing")
            made = DistSSHRun._prepare_output_dir!(missing; command = :drive, surface = :api)
            @test made == DistSSHRun.canonical_local_path(missing)
            @test isdir(made)
            @test isempty(readdir(made))
            empty_dir = joinpath(tmp, "empty")
            mkdir(empty_dir)
            @test DistSSHRun._prepare_output_dir!(empty_dir; command = :ride) ==
                DistSSHRun.canonical_local_path(empty_dir)
            file = joinpath(tmp, "a-file")
            write(file, "x\n")
            file_err = try
                DistSSHRun._prepare_output_dir!(file; command = :go, surface = :cli)
                nothing
            catch e
                e
            end
            @test file_err isa ArgumentError
            file_err isa ArgumentError || error("expected ArgumentError")
            @test occursin(file, file_err.msg)
            @test occursin("Run `julia -m DistSSHKit help go` for flags.", file_err.msg)
            @test !occursin("--help", file_err.msg)
            link = joinpath(tmp, "link")
            symlink(empty_dir, link)
            link_err = try
                DistSSHRun._prepare_output_dir!(link; command = :drive, surface = :api)
                nothing
            catch e
                e
            end
            @test link_err isa ArgumentError
            link_err isa ArgumentError || error("expected ArgumentError")
            @test occursin("symlink", link_err.msg)
            @test occursin("Omit output_dir or pass an empty directory.", link_err.msg)
            sidecars = joinpath(tmp, "sidecars")
            mkdir(sidecars)
            write(joinpath(sidecars, "kit.pid"), "1\n")
            write(joinpath(sidecars, "kit.job"), "q-1\n")
            @test DistSSHRun._prepare_output_dir!(
                sidecars; command = :go, allow_parent_sidecars = true,
            ) == DistSSHRun.canonical_local_path(sidecars)
            bare = try
                DistSSHRun._prepare_output_dir!(sidecars; command = :go)
                nothing
            catch e
                e
            end
            @test bare isa ArgumentError
            write(joinpath(sidecars, "stale.txt"), "old\n")
            mixed = try
                DistSSHRun._prepare_output_dir!(
                    sidecars; command = :go, allow_parent_sidecars = true,
                )
                nothing
            catch e
                e
            end
            @test mixed isa ArgumentError
            mixed isa ArgumentError || error("expected ArgumentError")
            @test occursin("stale.txt", mixed.msg)
            @test occursin("kit.pid", mixed.msg)
        end
    end
end
