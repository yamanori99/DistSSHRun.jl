using Test
using TOML

@testset "deploy record build and parse" begin
    tmp = mktempdir()
    try
        write(joinpath(tmp, "Project.toml"), "name = \"Dep\"\n")
        write(joinpath(tmp, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        rec = DistSSHRun.build_deploy_record(
            tmp,
            :git_sync;
            deploy_id = "a"^40,
            commit_sha = "a"^40,
            dirty = false,
        )
        @test rec["schema"] == 1
        @test rec["mode"] == "git-sync"
        @test rec["deploy_id"] == "a"^40
        @test haskey(rec, "manifest_hash")
        body = sprint(TOML.print, rec)
        parsed = DistSSHRun._parse_deploy_record_body(body)
        @test parsed !== nothing
        @test parsed["mode"] == "git-sync"
    finally
        rm(tmp; force = true, recursive = true)
    end
end

@testset "deploy record equivalence" begin
    a = Dict("schema" => 1, "deploy_id" => "x", "mode" => "git-sync")
    b = Dict("schema" => 1, "deploy_id" => "x", "mode" => "git-sync")
    c = Dict("schema" => 1, "deploy_id" => "y", "mode" => "git-sync")
    @test DistSSHRun._deploy_records_equivalent(a, b)
    @test !DistSSHRun._deploy_records_equivalent(a, c)
end

@testset "deploy record logical path" begin
    p = DistSSHRun.deploy_record_logical_path("/remote/proj")
    @test p == "/remote/proj/.distssh/deploy.toml"
    p2 = DistSSHRun.deploy_record_logical_path("~/App/Proj")
    @test occursin(".distssh/deploy.toml", p2)
end

@testset "provenance deploy slice" begin
    rec = Dict(
        "schema" => 1,
        "mode" => "ship-tree",
        "deploy_id" => "20260101T000000Z-aaaaaa",
        "snapshot_id" => "20260101T000000Z-aaaaaa",
    )
    slice = DistSSHRun._deploy_record_for_provenance(rec)
    @test slice !== nothing
    @test slice["mode"] == "ship-tree"
    @test slice["snapshot_id"] == "20260101T000000Z-aaaaaa"
end
