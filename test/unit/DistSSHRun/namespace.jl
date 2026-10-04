using Test

@testset "namespace" begin
    @test DistSSHRun.cache_remote_dir("/remote/App") == joinpath(
        "/remote/App", ".distsshkit", "cache", "sha256",
    )

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"CachePush\"\n")
        session = DistSSHRun.KitSession(project = proj, workers = ["parent:1"])
        @test_throws ArgumentError DistSSHRun.push_cache!(session)
        empty = DistSSHRun.KitSession(project = proj, workers = ["child:host1"])
        result = DistSSHRun.push_cache!(empty)
        @test result.ok
        @test isempty(result.hosts)
        src = joinpath(proj, "blob.bin")
        write(src, "cache-bytes")
        h = DistSSHRun.file_sha256(DistSSHRun.cache_file(src; project = proj))
        @test_throws ArgumentError DistSSHRun.push_cache!(
            DistSSHRun.KitSession(project = proj, workers = ["child:host1"]);
            hashes = ["not-a-hash"],
        )
        @test_throws ArgumentError DistSSHRun.push_cache!(
            DistSSHRun.KitSession(project = proj, workers = ["child:host1"]);
            hashes = ["a"^64],
        )
        _with_tempdir() do state_dir
            env = merge(
                _fake_setup_remote_env(state_dir),
                Dict(
                    "DISTRIBUTED_PROJECT_ROOT" => proj,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/fake/remote/CachePush",
                ),
            )
            withenv(env...) do
                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = true, yes = true))
                sess = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "/fake/remote/CachePush",
                )
                ok = DistSSHRun.push_cache!(sess)
                @test ok.ok
                @test length(ok.hosts) == 1
                @test ok.hosts[1].ok
                subset = DistSSHRun.push_cache!(sess; hashes = [h])
                @test subset.ok
                withenv("DISTSSHKIT_TEST_RSYNC_FAIL" => "1") do
                    fail = DistSSHRun.push_cache!(sess)
                    @test !fail.ok
                    @test !fail.hosts[1].ok
                end
            end
        end
    end
end
