using Test
using Distributed
using TOML
using DistSSHRun

function _loaded_identity_repo_root()::String
    return abspath(joinpath(@__DIR__, "..", "..", "..", ".."))
end

function _component_id_matches_project!(mod::Module, project_file::AbstractString)
    id = getfield(mod, :COMPONENT_ID)
    proj = TOML.parsefile(String(project_file))
    @test String(getproperty(id, :name)) == string(proj["name"])
    @test getproperty(id, :uuid) == Base.UUID(string(proj["uuid"]))
    @test String(getproperty(id, :version)) == string(proj["version"])
    @test Int(getproperty(id, :schema)) == 1
    dig = String(getproperty(id, :digest))
    @test !isempty(dig)
    @test length(dig) == 64
    return nothing
end

function _with_one_loaded_worker(f::Function)
    before = Set(workers())
    project = TEST_PROJECT
    flags = `--startup-file=no --project=$(project)`
    addprocs(1; exeflags = flags, topology = :master_worker)
    w = only(setdiff(workers(), before))
    DistSSHRun._mark_workers_launched!(Int[w], project)
    try
        return f(w)
    finally
        rmprocs(w; waitfor = 30)
    end
end

@testset "loaded_identity" begin
    root = _loaded_identity_repo_root()

    @testset "COMPONENT_ID literals match Project.toml" begin
        @test Base.ispublic(DistSSHRun.DistSSHBase, :src_component_digest)
        @test !Base.isexported(DistSSHRun.DistSSHBase, :src_component_digest)
        _component_id_matches_project!(DistSSHRun, joinpath(root, "Project.toml"))
        _component_id_matches_project!(DistSSHRun.DistSSHBase, joinpath(root, "lib", "DistSSHBase", "Project.toml"))
        run_root = joinpath(root, "src")
        @test DistSSHRun.COMPONENT_ID.digest ==
            DistSSHRun.DistSSHBase.src_component_digest(run_root, DistSSHRun._RUN_SRC_FILES)
        base_root = joinpath(root, "lib", "DistSSHBase", "src")
        @test DistSSHRun.DistSSHBase.COMPONENT_ID.digest ==
            DistSSHRun.DistSSHBase.src_component_digest(base_root, DistSSHRun.DistSSHBase._SRC_FILES)
    end

    @testset "wire encode/decode" begin
        slots = DistSSHRun.LoadedSlotReport[
            DistSSHRun.LoadedSlotReport(
                :DistSSHRun,
                :Loaded,
                "0.2.0-DEV",
                Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"),
                "",
                :top_level,
                ""),
            DistSSHRun.LoadedSlotReport(
                :DistSSHBase,
                :Loaded,
                "0.2.0-DEV",
                Base.UUID("f0a69307-14e5-4272-8c28-20680d05bac8"),
                "",
                :bundled,
                ""),
        ]
        wire = DistSSHRun.encode_loaded_wire_report(slots)
        schema, back = DistSSHRun.decode_loaded_wire_report(wire)
        @test schema == 1
        @test length(back) == 2
        DistSSHRun.verify_loaded_slots_match!(slots, back, "test")
    end

    @testset "component_id mismatch" begin
        good = DistSSHRun.LoadedSlotReport(
            :DistSSHRun,
            :Loaded,
            "0.2.0-DEV",
            Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"),
            "",
            :top_level,
            "")
        bad = DistSSHRun.LoadedSlotReport(
            :DistSSHRun,
            :Loaded,
            "0.1.0",
            Base.UUID("b568025c-2759-4ef1-8b14-17d00e2cd000"),
            "",
            :top_level,
            "")
        @test_throws DistSSHRun.LoadedCodeMismatchError DistSSHRun.verify_loaded_slots_match!(
            DistSSHRun.LoadedSlotReport[good],
            DistSSHRun.LoadedSlotReport[bad],
            "DistributedWorker rank=1 pid=2")
    end

    @testset "schema skew" begin
        wire = "schema=99\ncomponent=DistSSHRun\nstate=Loaded\nversion=\nuuid=b568025c-2759-4ef1-8b14-17d00e2cd000\ndigest=\nlayout=top_level\nprobe_error=\n---\n"
        schema, _ = DistSSHRun.decode_loaded_wire_report(wire)
        @test schema == 99
    end

    @testset "controller assert" begin
        DistSSHRun.assert_controller_loaded_identity!()
        @test DistSSHRun.loaded_launch_mode() == :worker_job
        @test DistSSHRun.required_loaded_components(:worker_job) == [:DistSSHBase, :DistSSHRun]
    end

    @testset "worker reporter" begin
        _with_one_loaded_worker() do w
            names_before = remotecall_fetch(() -> String.(names(Main)), w)
            wire = DistSSHRun._fetch_worker_loaded_wire(w)
            names_after = remotecall_fetch(() -> String.(names(Main)), w)
            @test names_before == names_after
            @test !("DistSSHRun" in names_after)
            schema, slots = DistSSHRun.decode_loaded_wire_report(wire)
            @test schema == 1
            @test any(s -> s.component == :DistSSHRun && s.state == :Loaded, slots)
            @test any(s -> s.component == :DistSSHBase && s.state == :Loaded && s.layout == :bundled, slots)
        end
    end

    @testset "loaded mismatch not waived" begin
        _with_one_loaded_worker() do w
            good = DistSSHRun._fetch_worker_loaded_wire(w)
            DistSSHRun._WORKER_LOADED_IDENTITY_OVERRIDE[] = _ -> replace(good, "0.2.0-DEV" => "0.0.1", count = 1)
            try
                @test_throws DistSSHRun.LoadedCodeMismatchError DistSSHRun.verify_workers_loaded_identity!()
            finally
                DistSSHRun._WORKER_LOADED_IDENTITY_OVERRIDE[] = nothing
            end
        end
    end

    @testset "assert_loaded_verified_worker_set!" begin
        before_rm = Set(workers())
        addprocs(1; exeflags = `--startup-file=no --project=$(TEST_PROJECT)`, topology = :master_worker)
        w_rm = only(setdiff(workers(), before_rm))
        DistSSHRun._mark_workers_launched!(Int[w_rm], TEST_PROJECT)
        try
            DistSSHRun.verify_workers_loaded_identity!()
            DistSSHRun.assert_loaded_verified_worker_set!()
            rmprocs(w_rm; waitfor = 30)
            DistSSHRun.assert_loaded_verified_worker_set!()
        finally
            DistSSHRun._LOADED_VERIFIED_WORKER_IDS[] = nothing
            w_rm in workers() && rmprocs(w_rm; waitfor = 30)
        end
        before = Set(workers())
        addprocs(1; exeflags = `--startup-file=no --project=$(TEST_PROJECT)`, topology = :master_worker)
        w = only(setdiff(workers(), before))
        DistSSHRun._mark_workers_launched!(Int[w], TEST_PROJECT)
        try
            DistSSHRun.verify_workers_loaded_identity!()
            DistSSHRun.assert_loaded_verified_worker_set!()
            extra_before = Set(workers())
            addprocs(1; exeflags = `--startup-file=no --project=$(TEST_PROJECT)`, topology = :master_worker)
            extra = only(setdiff(workers(), extra_before))
            DistSSHRun._mark_workers_launched!(Int[extra], TEST_PROJECT)
            @test_throws DistSSHRun.LoadedCodeMismatchError DistSSHRun.assert_loaded_verified_worker_set!()
            rmprocs(extra; waitfor = 30)
        finally
            DistSSHRun._LOADED_VERIFIED_WORKER_IDS[] = nothing
            w in workers() && rmprocs(w; waitfor = 30)
        end
    end
end
