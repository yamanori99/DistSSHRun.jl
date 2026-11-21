using Test
using TOML
using Distributed
using Pkg
using Dates

@testset "job environment" begin
    @testset "worker_load_path is @:@stdlib for local and ssh" begin
        @test DistSSHRun.worker_load_path() == DistSSHRun._LAUNCH_LOAD_PATH
        @test DistSSHRun.worker_load_path(; ssh = true) == "@:@stdlib"
        env = Dict(DistSSHRun.worker_env_pairs("/tmp/job"))
        @test env["JULIA_LOAD_PATH"] == "@:@stdlib"
        ap = mktempdir()
        try
            write(joinpath(ap, "Project.toml"), "name = \"LpJob\"\n")
            @test !occursin(ap, DistSSHRun.worker_load_path())
        finally
            rm(ap; force = true, recursive = true)
        end
    end

    @testset "restrict_job_load_path!" begin
        prev = copy(LOAD_PATH)
        try
            push!(LOAD_PATH, mktempdir())
            DistSSHRun.restrict_job_load_path!()
            @test LOAD_PATH == ["@", "@stdlib"]
        finally
            empty!(LOAD_PATH)
            append!(LOAD_PATH, prev)
        end
    end

    @testset "package collision what/where/why/fix" begin
        job = mktempdir()
        try
            write(joinpath(job, "Project.toml"), "name = \"Collide\"\n")
            pkg = Base.PkgId(Dates)
            rid = lowercase(string(something(pkg.uuid, "")))
            loaded_ver = string(Base.pkgversion(Dates))
            open(joinpath(job, "Manifest.toml"), "w") do io
                println(io, "julia_version = \"$(VERSION)\"")
                println(io, "manifest_format = \"2.0\"")
                println(io, "project_hash = \"0123456789abcdef0123456789abcdef01234567\"")
                println(
                    io,
                    "deps = {Dates = [{uuid = \"$(rid)\", version = \"9.9.9\"}]}",
                )
            end
            err = ""
            @test_throws ErrorException DistSSHRun.assert_job_package_collisions!(job)
            try
                DistSSHRun.assert_job_package_collisions!(job)
            catch e
                err = e isa ErrorException ? e.msg : sprint(showerror, e)
            end
            @test occursin("what:", err)
            @test occursin("where:", err)
            @test occursin("why:", err)
            @test occursin("fix:", err)
            @test occursin("Dates", err)

            open(joinpath(job, "Manifest.toml"), "w") do io
                println(io, "julia_version = \"$(VERSION)\"")
                println(io, "manifest_format = \"2.0\"")
                println(io, "project_hash = \"0123456789abcdef0123456789abcdef01234567\"")
                println(
                    io,
                    "deps = {Dates = [{uuid = \"$(rid)\", version = \"$(loaded_ver)\"}]}",
                )
            end
            DistSSHRun.assert_job_package_collisions!(job)
        finally
            rm(job; force = true, recursive = true)
        end
    end

    @testset "instantiate digest gate" begin
        job = mktempdir()
        try
            write(joinpath(job, "Project.toml"), "name = \"InstGate\"\n")
            _sync_test_project_manifest!(job)
            pf = joinpath(job, "Project.toml")
            good = lowercase(DistSSHRun.file_sha256(joinpath(job, "Manifest.toml")))
            mkpath(joinpath(job, ".distssh"))
            write(
                joinpath(job, ".distssh", "deploy.toml"),
                sprint(TOML.print, Dict("manifest_hash" => good)),
            )
            called = Ref(false)
            Base.set_active_project(pf)
            DistSSHRun.instantiate_job_manifest!(
                job;
                instantiate = _ -> (called[] = true),
            )
            @test called[]

            bad = lowercase(DistSSHRun.file_sha256(joinpath(job, "Manifest.toml")))
            write(
                joinpath(job, ".distssh", "deploy.toml"),
                sprint(TOML.print, Dict("manifest_hash" => ("f"^length(bad)))),
            )
            called[] = false
            @test_throws ErrorException DistSSHRun.instantiate_job_manifest!(
                job;
                instantiate = _ -> (called[] = true),
            )
            @test !called[]
        finally
            rm(job; force = true, recursive = true)
        end
    end

    @testset "deploy record instantiated flag" begin
        job = mktempdir()
        try
            write(joinpath(job, "Project.toml"), "name = \"DepInst\"\n")
            _sync_test_project_manifest!(job)
            rec = DistSSHRun.build_deploy_record(job, :ship_tree; deploy_id = "run-test")
            @test get(rec, "instantiated", missing) === false
            a = Dict("instantiated" => false, "deploy_id" => "a", "mode" => "ship-tree", "writer" => rec["writer"])
            b = Dict("instantiated" => true, "deploy_id" => "a", "mode" => "ship-tree", "writer" => rec["writer"])
            @test !DistSSHRun._deploy_records_equivalent(a, b)
        finally
            rm(job; force = true, recursive = true)
        end
    end

    @testset "update_deploy_record_instantiated" begin
        job = mktempdir()
        try
            write(joinpath(job, "Project.toml"), "name = \"UpdInst\"\n")
            _sync_test_project_manifest!(job)
            mh = DistSSHRun._deploy_record_manifest_hash(job)
            rec = Dict{String, Any}(
                "writer" => DistSSHRun.run_record_writer(),
                "deploy_id" => "x",
                "mode" => "ship-tree",
                "manifest_hash" => mh,
                "instantiated" => false,
            )
            DistSSHRun._set_active_deploy_record!(rec)
            out = DistSSHRun.update_deploy_record_instantiated!(String[], job, job)
            @test out isa Dict
            @test get(out, "instantiated", false) == true
            rec2 = Dict{String, Any}(rec)
            rec2["manifest_hash"] = "f"^64
            DistSSHRun._set_active_deploy_record!(rec2)
            @test DistSSHRun.update_deploy_record_instantiated!(String[], job, job) === nothing
            DistSSHRun._set_active_deploy_record!(rec)
            DistSSHRun.update_deploy_record_instantiated!(String[], job, job)
            active = DistSSHRun.active_deploy_record()
            @test active !== nothing
            @test get(active, "instantiated", false) == true
        finally
            DistSSHRun._clear_active_deploy_record!()
            rm(job; force = true, recursive = true)
        end
    end
end