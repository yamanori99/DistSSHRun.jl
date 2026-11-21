using Test

# Oracle: in-process `drive!` fails after an earlier driver include unless
# `reuse_main=true` or `isolated=true`. Runs after `integration/drive/api.jl`,
# so this process already loaded a driver into `Main`.

@testset "drive! reuse_main and isolated" begin
    @testset "fail closed without reuse_main or isolated" begin
        _mktemp_host() do proj
            _write_host_project!(proj, "DrvReuseGate")
            first = joinpath(proj, "first.jl")
            second = joinpath(proj, "second.jl")
            marker = joinpath(proj, "second.ran")
            write(first, "function main()\n    return nothing\nend\n")
            write(
                second,
                """
                write($(repr(marker)), "x")
                function main()
                    return nothing
                end
                """,
            )
            prev = DistSSHRun.kit_verbosity()
            try
                DistSSHRun.set_kit_verbosity!(:quiet)
                if DistSSHRun._drive_main_driver_included()
                    DistSSHRun.drive!(
                        first; head_workers = 1,
                        project = proj,
                        enable_log = false,
                        reuse_main = true,
                    )
                else
                    DistSSHRun.drive!(
                        first; head_workers = 1,
                        project = proj,
                        enable_log = false,
                    )
                end
                err = try
                    DistSSHRun.drive!(
                        second; head_workers = 1,
                        project = proj,
                        enable_log = false,
                    )
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("reuse_main=true", err.msg)
                @test occursin("isolated=true", err.msg)
                @test !isfile(marker)
            finally
                DistSSHRun.set_kit_verbosity!(prev)
            end
        end
    end

    @testset "nested drive! during include fails closed" begin
        _mktemp_host() do proj
            _write_host_project!(proj, "DrvReuseNested")
            inner = joinpath(proj, "inner.jl")
            outer = joinpath(proj, "outer.jl")
            touched = joinpath(proj, "inner.ran")
            write(
                inner,
                """
                write($(repr(touched)), "ran")
                function main()
                    return nothing
                end
                """,
            )
            write(
                outer,
                """
                try
                    DistSSHRun.drive!(
                        $(repr(inner));
                        head_workers = 1,
                        project = $(repr(proj)),
                        enable_log = false,
                    )
                    write($(repr(touched)), "allowed")
                catch err
                    err isa ArgumentError || rethrow()
                    occursin("reuse_main=true", err.msg) || rethrow()
                end
                function main()
                    return nothing
                end
                """,
            )
            prev = DistSSHRun.kit_verbosity()
            try
                DistSSHRun.set_kit_verbosity!(:quiet)
                res = DistSSHRun.drive!(
                    outer; head_workers = 1,
                    project = proj,
                    enable_log = false,
                    reuse_main = true,
                )
                @test res.ok
                @test !isfile(touched)
            finally
                DistSSHRun.set_kit_verbosity!(prev)
            end
        end
    end

    @testset "reuse_main allows another in-process include" begin
        _mktemp_host() do proj
            _write_host_project!(proj, "DrvReuseOk")
            marker = joinpath(proj, "ran.txt")
            script = joinpath(proj, "reuse.jl")
            write(
                script,
                """
                function main()
                    write($(repr(marker)), "yes")
                    return nothing
                end
                """,
            )
            prev = DistSSHRun.kit_verbosity()
            try
                DistSSHRun.set_kit_verbosity!(:quiet)
                res = DistSSHRun.drive!(
                    script; head_workers = 1,
                    project = proj,
                    enable_log = false,
                    reuse_main = true
                )
                @test res.ok
                @test isfile(marker)
            finally
                DistSSHRun.set_kit_verbosity!(prev)
            end
        end
    end

    @testset "isolated=true does not define into parent Main" begin
        _mktemp_host() do proj
            _write_host_project!(proj, "DrvIsolated")
            marker = joinpath(proj, "iso.txt")
            script = joinpath(proj, "iso.jl")
            write(
                script,
                """
                const DISTSSH_TEST_ISO_LEAK = 99
                write($(repr(marker)), "child")
                function main()
                    return nothing
                end
                """,
            )
            prev = DistSSHRun.kit_verbosity()
            try
                DistSSHRun.set_kit_verbosity!(:quiet)
                res = DistSSHRun.drive!(
                    script; head_workers = 1,
                    project = proj,
                    enable_log = false,
                    isolated = true
                )
                @test res.ok
                @test res.output_dir === nothing
                @test isfile(marker)
                @test !isdefined(Main, :DISTSSH_TEST_ISO_LEAK)
            finally
                DistSSHRun.set_kit_verbosity!(prev)
            end
        end
    end

    @testset "CLI drive --isolated" begin
        _mktemp_host() do proj
            _write_host_project!(proj, "DrvCliIsolated")
            marker = joinpath(proj, "cli_iso.txt")
            script = joinpath(proj, "cli.jl")
            write(
                script,
                """
                write($(repr(marker)), "cli")
                function main()
                    return nothing
                end
                """,
            )
            proc, combined = _run_kit_drive(;
                script,
                host_root = proj,
                head_workers = 1,
                drive_flags = String["--isolated"],
                extra_env = Dict("DISTSSH_SKIP_GLOBAL_WORKER_PKILL" => "1"),
            )
            _assert_proc_ok(proc, combined; label = "drive --isolated")
            @test isfile(marker)
        end
    end
end
