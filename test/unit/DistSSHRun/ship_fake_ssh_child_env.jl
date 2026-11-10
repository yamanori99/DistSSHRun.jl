using Test

# Pkg.test leaves a narrow JULIA_LOAD_PATH and an active project. Fake-SSH
# grandchildren must still load stdlib Tar (regression for registry CI).

const _FAKE_ARBITRARY_DEST_SHIP_SSH = joinpath(
    @__DIR__,
    "..",
    "..",
    "..",
    "lib",
    "DistSSHBase",
    "test",
    "fixtures",
    "fake_arbitrary_dest_ship_ssh.jl",
)

@testset "fake ssh child env under Pkg.test-like parent" begin
    @testset "grandchild loads Tar with sandbox load path only" begin
        mktempdir() do narrow
            active = TEST_PROJECT
            withenv(
                "JULIA_LOAD_PATH" => "@:$narrow",
                "JULIA_PROJECT" => active,
            ) do
                _with_tempdir() do state
                    env = merge(
                        _fake_setup_remote_env(state),
                        Dict(
                            "DISTSSH_TEST_SSH" => abspath(_FAKE_ARBITRARY_DEST_SHIP_SSH),
                            "DISTSSH_TEST_JULIA_WHICH" => "/usr/bin/julia",
                        ),
                    )
                    withenv(env...) do
                        cmd = DistSSHRun.DistSSHBase._host_sync_remote_shell_cmd("host1", "true")
                        out = IOBuffer()
                        err = IOBuffer()
                        proc = run(
                            pipeline(ignorestatus(cmd); stdout = out, stderr = err);
                            wait = true,
                        )
                        @test something(proc.exitcode, 1) == 0
                        @test occursin("ok", String(take!(out)))
                    end
                end
            end
        end
    end

    @testset "prepare dest failure message includes stderr" begin
        mktempdir() do state
            env = merge(
                _fake_setup_remote_env(state),
                Dict(
                    "DISTSSH_TEST_SSH" => abspath(_FAKE_ARBITRARY_DEST_SHIP_SSH),
                    "DISTSSH_TEST_STATE_ROOT" => "",
                    "DISTSSH_TEST_JULIA_WHICH" => "/usr/bin/julia",
                ),
            )
            withenv(env...) do
                code, out, err = DistSSHRun.DistSSHBase._remote_shell_status_parts("host1", "true")
                @test code == 1
                detail = DistSSHRun.DistSSHBase.shell_status_failure_message(out, err, code)
                @test occursin("DISTSSH_TEST_STATE_ROOT is empty", detail)
                @test occursin("exit 1", detail)
                mktempdir() do proj
                    write(joinpath(proj, "Project.toml"), "name = \"Pkg\"\n")
                    write(
                        joinpath(proj, "Manifest.toml"),
                        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
                    )
                    write(joinpath(proj, "keep.jl"), "1\n")
                    host = "host1"
                    dest = "/home/distsshkit/.distsshqueue/stage/empty-root"
                    DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!(host)
                    DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                    pack = DistSSHRun.pack_ship_tree(proj)
                    try
                        result = DistSSHRun.ship_pack(
                            pack, [host], dest; write_record = false,
                        )
                        @test !result.ok
                        @test length(result.hosts) == 1
                        msg = result.hosts[1].message
                        @test occursin("DISTSSH_TEST_STATE_ROOT is empty", msg)
                        @test occursin("could not prepare dest on host1:", msg)
                    finally
                        rm(pack.directory; force = true, recursive = true)
                    end
                end
            end
        end
    end
end
