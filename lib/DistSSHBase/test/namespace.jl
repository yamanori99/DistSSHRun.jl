using Test

@testset "namespace" begin
    _with_tempdir() do tmp
        src = joinpath(tmp, "a.bin")
        write(src, "hello ns")
        h = DistSSHBase.file_sha256(src)
        @test length(h) == 64
        @test h == DistSSHBase.file_sha256(src)
        @test_throws ArgumentError DistSSHBase.file_sha256(joinpath(tmp, "missing"))

        dest = DistSSHBase.cache_file(src; project = tmp)
        @test dest == DistSSHBase.cache_path(h; project = tmp)
        @test isfile(dest)
        @test DistSSHBase.file_sha256(dest) == h
        dest2 = DistSSHBase.cache_file(src; project = tmp)
        @test dest2 == dest
        other = joinpath(tmp, "b.bin")
        write(other, "hello ns")
        @test DistSSHBase.cache_file(other; project = tmp) == dest
        @test DistSSHBase.cache_relpath(h) == joinpath(".distsshkit", "cache", "sha256", h)
        @test_throws ArgumentError DistSSHBase.cache_relpath("zz")

        withenv("DISTRIBUTED_OUTPUT_DIR" => nothing) do
            @test DistSSHBase.stored_path("a.bin"; project = tmp) == joinpath(
                DistSSHBase.canonical_local_path(tmp), "a.bin",
            )
            @test DistSSHBase.stored_path(src; project = tmp) == DistSSHBase.canonical_local_path(src)
        end
        out = joinpath(tmp, "slot")
        mkpath(out)
        write(joinpath(out, "a.bin"), "from slot")
        withenv("DISTRIBUTED_OUTPUT_DIR" => out) do
            @test DistSSHBase.stored_path("a.bin"; project = tmp) == joinpath(
                DistSSHBase.canonical_local_path(out), "a.bin",
            )
            @test DistSSHBase.stored_path("new.csv"; project = tmp) == joinpath(
                DistSSHBase.canonical_local_path(out), "new.csv",
            )
            only_proj = joinpath(tmp, "only.txt")
            write(only_proj, "proj")
            @test DistSSHBase.stored_path("only.txt"; project = tmp) ==
                DistSSHBase.canonical_local_path(only_proj)
            @test DistSSHBase.stored_path(src; project = tmp) == DistSSHBase.canonical_local_path(src)
            @test DistSSHBase.stored_path("a.bin"; project = tmp, output = joinpath(tmp, "other")) ==
                joinpath(DistSSHBase.canonical_local_path(tmp), "a.bin")
        end
    end
end
