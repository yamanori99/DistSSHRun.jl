using Test

# Included from `test/runtests.jl` (support helpers already loaded). Standalone:
#   julia --project=. --startup-file=no -e 'using Test; using DistSSHRun; include("test/support.jl"); include("test/unit/DistSSHRun/infra/ship_dest.jl")'

const _FAKE_ARBITRARY_DEST_SHIP_SSH = joinpath(
    @__DIR__,
    "..",
    "..",
    "..",
    "..",
    "lib",
    "DistSSHBase",
    "test",
    "fixtures",
    "fake_arbitrary_dest_ship_ssh.jl",
)

function _fake_arbitrary_dest_ship_env(state_dir::AbstractString)
    return merge(
        _fake_setup_remote_env(state_dir),
        Dict(
            "DISTSSH_TEST_SSH" => abspath(_FAKE_ARBITRARY_DEST_SHIP_SSH),
            "DISTSSH_TEST_JULIA_WHICH" => "/usr/bin/julia",
        ),
    )
end

function _minimal_project!(dir::AbstractString)
    write(joinpath(dir, "Project.toml"), "name = \"StageShip\"\n")
    write(
        joinpath(dir, "Manifest.toml"),
        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
    )
    write(joinpath(dir, "keep.jl"), "1\n")
    return dir
end

@testset "ship dest public API" verbose = true begin
    @testset "names are public and not exported" begin
        for sym in (:pack_ship_tree, :pack_shipment, :ship_project_to_dest)
            @test sym in names(DistSSHRun)
            @test Base.ispublic(DistSSHRun, sym)
            @test !Base.isexported(DistSSHRun, sym)
        end
    end

    @testset "pack_ship_tree matches ship-tree pack rules" begin
        mktempdir() do tmp
            _minimal_project!(tmp)
            pack = DistSSHRun.pack_ship_tree(tmp)
            try
                @test pack isa DistSSHRun.DistSSHShip.Shipment
                @test isfile(pack.tar_path)
                @test pack.content_tree_hash == DistSSHRun.DistSSHShip.content_tree_hash(pack)
                listed = DistSSHRun.ship_send_list(tmp)
                @test "keep.jl" in listed
                @test "Project.toml" in listed
            finally
                rm(pack.directory; force = true, recursive = true)
            end
        end
    end

    @testset "missing Manifest is a hard error at pack" begin
        mktempdir() do tmp
            write(joinpath(tmp, "Project.toml"), "name = \"NoMan\"\n")
            @test_throws ArgumentError DistSSHRun.pack_ship_tree(tmp)
        end
    end

    @testset "gitignored Manifest is refused at pack" begin
        mktempdir() do tmp
            _minimal_project!(tmp)
            write(joinpath(tmp, ".gitignore"), "Manifest.toml\n")
            @test_throws ArgumentError DistSSHRun.pack_ship_tree(tmp)
        end
    end

    @testset "pack_shipment forwards transfer_id to the record builder" begin
        pack = DistSSHRun.DistSSHShip.Shipment(
            mktempdir(),
            joinpath(mktempdir(), "x.tar"),
            "a"^40,
            0,
            0,
            "",
            mktempdir(),
            ".",
            String[],
            String[],
        )
        rec = DistSSHRun.DistSSHShip.build_shipment_record(pack; complete = true, transfer_id = "stage-uuid")
        @test rec["transfer_id"] == "stage-uuid"
        rm(pack.directory; force = true, recursive = true)
    end

    @testset "ship_project_to_dest packs, ships, and removes the bundle" begin
        _with_tempdir() do state
            mktempdir() do proj
                _minimal_project!(proj)
                host = "host1"
                dest = "/home/distsshkit/.distsshqueue/stage/job-1"
                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!(host)
                withenv(_fake_arbitrary_dest_ship_env(state)...) do
                    pack = DistSSHRun.pack_ship_tree(proj)
                    withenv("DISTSSH_TEST_EXPECT_TREE_HASH" => pack.content_tree_hash) do
                        bundle = pack.directory
                        rm(pack.directory; force = true, recursive = true)
                        result = DistSSHRun.ship_project_to_dest(
                            proj, [host], dest;
                            write_record = false,
                            transfer_id = "job-1",
                        )
                        @test _test_shipment_receipt_ok(
                            result; label = "ship_project_to_dest",
                        )
                        @test !isdir(bundle)
                    end
                end
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!(host)
            end
        end
    end

    @testset "fake ssh pack_shipment extracts and verifies" begin
        _with_tempdir() do state
            mktempdir() do proj
                _minimal_project!(proj)
                host = "host1"
                pack = DistSSHRun.pack_ship_tree(proj)
                try
                    dest = "/home/distsshkit/.distsshqueue/stage/test-uuid"
                    DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!(host)
                    withenv(
                        merge(
                            _fake_arbitrary_dest_ship_env(state),
                            Dict("DISTSSH_TEST_EXPECT_TREE_HASH" => pack.content_tree_hash),
                        )...,
                    ) do
                        result = DistSSHRun.pack_shipment(
                            pack, [host], dest; write_record = false,
                        )
                        @test result isa DistSSHRun.DistSSHShip.ShipmentReceipt
                        @test _test_shipment_receipt_ok(result; label = "pack_shipment")
                        @test result.content_tree_hash == pack.content_tree_hash
                        @test length(result.hosts) == 1
                        @test _test_host_result_ok(result.hosts[1]; label = "pack_shipment")
                    end
                finally
                    rm(pack.directory; force = true, recursive = true)
                    DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                    DistSSHRun.DistSSHBase.clear_detect_julia_path_cache!(host)
                end
            end
        end
    end
end
