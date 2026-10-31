using Test
using Distributed
using Pkg
using TOML

@testset "worker launch helper" begin
    flags = DistSSHRun.worker_exeflag_strings("/tmp/job"; local_cpu = false)
    @test "--project=/tmp/job" in flags
    @test "--startup-file=no" in flags
    @test "--history-file=no" in flags
    @test any(startswith(f, "--threads=") for f in flags)
    @test !any(startswith(f, "-C") for f in flags)

    env = Dict(DistSSHRun.worker_env_pairs("/tmp/job"))
    @test env["JULIA_LOAD_PATH"] == DistSSHRun.worker_load_path()
    @test DistSSHRun.worker_load_path(; ssh = true) == "@:@stdlib"
    @test startswith(DistSSHRun.worker_load_path(), "@:@stdlib")
    @test !occursin("@v#.#", DistSSHRun.worker_load_path())
    let ap = Base.active_project()
        ap === nothing || @test occursin(dirname(String(ap)), DistSSHRun.worker_load_path())
    end
    @test env["JULIA_PROJECT"] == "/tmp/job"
    @test haskey(env, "JULIA_NUM_THREADS")
    @test !haskey(env, "OPENBLAS_NUM_THREADS")
    withenv("DISTSSHKIT_BLAS_THREADS" => "1") do
        pinned = Dict(DistSSHRun.worker_env_pairs("/tmp/job"))
        @test pinned["OPENBLAS_NUM_THREADS"] == "1"
        @test pinned["OMP_NUM_THREADS"] == "1"
    end
    DistSSHRun.reset_worker_seeds!()
    a, b = withenv("DISTSSHKIT_JOB_SEED" => "11") do
        aa = Dict(DistSSHRun.worker_env_pairs("/tmp/job"; rank = DistSSHRun.take_worker_rank()))
        bb = Dict(DistSSHRun.worker_env_pairs("/tmp/job"; rank = DistSSHRun.take_worker_rank()))
        aa, bb
    end
    @test a["DISTSSHKIT_WORKER_RANK"] == "1"
    @test b["DISTSSHKIT_WORKER_RANK"] == "2"
    @test a["DISTSSHKIT_WORKER_SEED"] != b["DISTSSHKIT_WORKER_SEED"]
    @test DistSSHRun.worker_seed(11, 1) == parse(UInt64, a["DISTSSHKIT_WORKER_SEED"])
    @test DistSSHRun.worker_seed(11, 1) == DistSSHRun.worker_seed(11, 1)
    built = DistSSHRun._source_from_user(Dict{String, Any}("commit" => "abc", "nope" => "x"))
    @test built["commit"] == "abc"
    @test !haskey(built, "nope")
    DistSSHRun.reset_worker_seeds!()
    @test DistSSHRun.worker_pmap(identity, [10, 20]) == [10, 20]
    @test DistSSHRun._ITEM_MAP[(1, 1)] == 0
    @test DistSSHRun._ITEM_MAP[(1, 2)] == 0
    withenv("DISTSSHKIT_WORKER_RANK" => "4") do
        @test DistSSHRun.worker_pmap(identity, [10]) == [10]
    end
    @test DistSSHRun._ITEM_MAP[(1, 1)] == 0
    @test DistSSHRun._ITEM_MAP[(2, 1)] == 4
    items_only = DistSSHRun._seed_provenance()
    @test items_only isa AbstractDict
    items_only isa AbstractDict || error("expected item provenance")
    @test !haskey(items_only, "job")
    @test !haskey(items_only, "workers")
    item_rows = items_only["items"]
    @test item_rows isa Vector
    item_rows isa Vector || error("expected seed items")
    first_item = item_rows[1]
    @test first_item isa AbstractDict
    first_item isa AbstractDict || error("expected a seed item")
    @test first_item["call"] == 1
    @test first_item["item"] == 1
    @test first_item["rank"] == 0
    DistSSHRun.reset_worker_seeds!()
    withenv("DISTSSHKIT_JOB_SEED" => "11") do
        DistSSHRun.job_seed()
        DistSSHRun.take_worker_rank()
    end
    seeds = DistSSHRun._seed_provenance()
    @test seeds isa AbstractDict
    seeds isa AbstractDict || error("expected seed provenance")
    @test seeds["job"] == "11"
    workers = seeds["workers"]
    @test workers isa Vector
    workers isa Vector || error("expected seed workers")
    first_worker = workers[1]
    @test first_worker isa AbstractDict
    first_worker isa AbstractDict || error("expected a worker seed")
    @test first_worker["rank"] == 1
    slot = mktempdir()
    try
        snap_dir = joinpath(slot, ".distsshkit")
        mkpath(snap_dir)
        open(joinpath(snap_dir, "provenance-slot.toml"), "w") do io
            TOML.print(
                io, Dict(
                    "version" => "1.13.0",
                    "commit" => "abc",
                    "cpu" => "cpu",
                    "machine" => "aarch64",
                    "kernel" => "darwin",
                    "nthreads" => "1",
                    "blas" => "openblas",
                    "blas_threads" => "1",
                    "hostname" => "slot",
                )
            )
        end
        DistSSHRun.reset_worker_seeds!()
        withenv("DISTRIBUTED_OUTPUT_DIR" => slot, "DISTSSHKIT_WORKER_RANK" => "3") do
            @test DistSSHRun.worker_pmap(identity, [7]) == [7]
            DistSSHRun._flush_go_slot_pmap_items!()
        end
        DistSSHRun.reset_worker_seeds!()
        DistSSHRun.note_go_slot_provenance!("lab", slot)
        slot_seeds = DistSSHRun._seed_provenance()
        @test slot_seeds isa AbstractDict
        slot_seeds isa AbstractDict || error("expected slot seed provenance")
        slot_rows = slot_seeds["items"]
        @test slot_rows isa Vector
        slot_rows isa Vector || error("expected slot items")
        slot_row = slot_rows[1]
        @test slot_row isa AbstractDict
        slot_row isa AbstractDict || error("expected a slot item")
        @test slot_row["call"] == 1
        @test slot_row["item"] == 1
        @test slot_row["rank"] == 3
        @test slot_row["slot"] == "child:lab/" * basename(slot)
        snap = DistSSHRun._read_go_slot_snapshot(joinpath(snap_dir, "provenance-slot.toml"))
        @test snap["version"] == "1.13.0"
        @test !haskey(snap, "pmap_items")
    finally
        DistSSHRun._reset_run_provenance!(slot)
        DistSSHRun._PROVENANCE_AT_START[] = false
        DistSSHRun._PROVENANCE_GIT_TOOL[] = nothing
        rm(slot; force = true, recursive = true)
    end
    mktempdir() do tmp
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n")
        write(joinpath(tmp, "CondaPkg.toml"), "[deps]\n")
        prov = DistSSHRun._project_provenance(tmp)
        @test haskey(prov, "locks")
        @test haskey(prov["locks"], "CondaPkg.toml")
        whole = DistSSHRun.assemble_provenance(tmp)
        git = Sys.which("git")
        if git === nothing
            @test !haskey(whole, "tools")
        else
            @test haskey(whole, "tools")
            tools = whole["tools"]
            @test tools isa Vector
            tools isa Vector || error("expected tools")
            row = nothing
            for tool in tools
                tool isa AbstractDict || continue
                get(tool, "name", "") == "git" || continue
                row = tool
            end
            @test row isa AbstractDict
            row isa AbstractDict || error("expected git tool")
            @test row["path"] == git
            @test row["outside_manifest"] === true
        end
        try
            DistSSHRun._reset_run_provenance!(tmp)
            DistSSHRun._PROVENANCE_GIT_TOOL[] = Dict{String, Any}(
                "name" => "git",
                "path" => "/recorded/git",
                "outside_manifest" => true,
            )
            held = DistSSHRun.assemble_provenance(tmp)
            held_tools = held["tools"]
            @test held_tools isa Vector
            held_tools isa Vector || error("expected snapshotted tools")
            held_row = held_tools[1]
            @test held_row isa AbstractDict
            held_row isa AbstractDict || error("expected snapshotted git")
            @test held_row["path"] == "/recorded/git"
        finally
            DistSSHRun._PROVENANCE_AT_START[] = false
            DistSSHRun._PROVENANCE_GIT_TOOL[] = nothing
        end
    end

    names = DistSSHRun.launch_override_names(
        Dict("JULIA_PROJECT" => "/old", "JULIA_LOAD_PATH" => "@v1.13"),
    )
    @test "JULIA_PROJECT" in names
    @test "JULIA_LOAD_PATH" in names
    notice = DistSSHRun.launch_override_notice("lab", names)
    @test startswith(notice, "lab: launch overrides ")

    ssh_exe = DistSSHRun.ssh_worker_exename("/opt/julia")
    ssh_cmd = join(ssh_exe.exec, " ")
    @test ssh_exe.exec[1] == "env"
    @test "/opt/julia" in ssh_exe.exec
    @test "-u" in ssh_exe.exec
    @test "JULIA_PROJECT" in ssh_exe.exec
    @test "JULIA_LOAD_PATH=@:@stdlib" in ssh_exe.exec
    @test occursin("-u JULIA_PROJECT", ssh_cmd)
    @test occursin("JULIA_LOAD_PATH=@:@stdlib /opt/julia", ssh_cmd)
    @test !occursin("-u JULIA_LOAD_PATH", ssh_cmd)
    @test DistSSHRun.ssh_addprocs_bind_localhost("user@lab") == "user@lab 127.0.0.1"

    prefix = DistSSHRun.go_remote_julia_prefix("julia")
    @test occursin("env -u JULIA_PROJECT", prefix)
    @test occursin("-u OPENBLAS_NUM_THREADS", prefix)
    @test !occursin("OPENBLAS_NUM_THREADS=", prefix)
    @test occursin("JULIA_LOAD_PATH=", prefix)
    @test occursin("--project=.", prefix)
    capped = withenv("DISTSSHKIT_BLAS_THREADS" => "1") do
        DistSSHRun.go_remote_julia_prefix("julia"; blas = DistSSHRun._explicit_blas_threads())
    end
    unset_at = findfirst("-u OPENBLAS_NUM_THREADS", capped)
    set_at = findfirst("OPENBLAS_NUM_THREADS=", capped)
    @test unset_at !== nothing && set_at !== nothing && first(unset_at) < first(set_at)
    @test occursin("OMP_NUM_THREADS=", capped)

    @test DistSSHRun.parse_allow_mismatch("julia,distssh") == [:julia, :distssh]
    @test DistSSHRun.parse_allow_mismatch(" manifest ") == [:manifest]
    @test_throws ArgumentError DistSSHRun.parse_allow_mismatch("cpu")
    dest = Symbol[]
    DistSSHRun.merge_allow_mismatch!(dest, "julia")
    DistSSHRun.merge_allow_mismatch!(dest, "julia,manifest")
    @test dest == [:julia, :manifest]

    parent = Dict(
        "version" => "1.13.0",
        "commit" => "abc",
        "manifest" => "/job/Manifest.toml",
        "pkg.DistSSHRun" => "0.1.0",
    )
    worker = Dict(
        "version" => "1.13.1",
        "commit" => "abc",
        "manifest" => "/job/Manifest.toml",
        "pkg.DistSSHRun" => "0.1.0",
    )
    lines = DistSSHRun._identity_mismatch_lines(
        parent, worker;
        shipped_manifest = "/job/Manifest.toml",
    )
    @test any(occursin("julia version", l) for l in lines)
    allowed = DistSSHRun._identity_mismatch_lines(
        parent, worker;
        allow = [:julia],
        shipped_manifest = "/job/Manifest.toml",
    )
    @test isempty(allowed)

    @test DistSSHRun.allow_mismatch_argv([:julia, :manifest]) ==
        ["--allow-mismatch", "julia,manifest"]

    missing_man = Dict(
        "version" => "1.13.1",
        "commit" => "abc",
        "manifest" => "",
        "pkg.DistSSHRun" => "0.1.0",
    )
    miss = DistSSHRun._identity_mismatch_lines(
        parent, missing_man;
        shipped_manifest = "/remote/job/Manifest.toml",
    )
    @test any(occursin("manifest missing", l) for l in miss)
    waived_man = DistSSHRun._identity_mismatch_lines(
        parent, missing_man;
        allow = [:manifest],
        shipped_manifest = "/remote/job/Manifest.toml",
    )
    @test !any(occursin("manifest", l) for l in waived_man)

    julia_man = DistSSHRun._identity_mismatch_lines(
        parent,
        Dict(
            "version" => "1.13.1",
            "commit" => "abc",
            "manifest" => "/job/JuliaManifest.toml",
            "pkg.DistSSHRun" => "0.1.0",
        );
        shipped_manifest = "/job/Manifest.toml",
    )
    @test any(occursin("manifest path", l) for l in julia_man)

    none = DistSSHRun._identity_mismatch_lines(
        Dict(
            "version" => "1.13.1",
            "commit" => "abc",
            "manifest" => "",
            "pkg.DistSSHRun" => "0.1.0",
        ),
        Dict(
            "version" => "1.13.1",
            "commit" => "abc",
            "manifest" => "",
            "pkg.DistSSHRun" => "0.1.0",
        );
        shipped_manifest = "",
    )
    @test !any(occursin("manifest", l) for l in none)

    pin = DistSSHRun.pin_local_julia(nothing)
    @test isabspath(pin)
    @test isfile(pin) || islink(pin)

    cookie_before = Distributed.cluster_cookie()
    DistSSHRun.ensure_run_cluster_cookie!()
    @test length(Distributed.cluster_cookie()) == 16
    @test Distributed.cluster_cookie() == cookie_before || nprocs() == 1

    _with_tempdir() do proj
        man = joinpath(proj, "Manifest.toml")
        write(
            man, """
            # This file is machine-generated - editing it directly is not advised

            julia_version = "1.13.1"
            manifest_format = "2.0"
            project_hash = "0123456789abcdef0123456789abcdef01234567"

            [[deps.Artifacts]]
            uuid = "56c22d13-8852-41a3-930b-5e04c8691e1d"

            [[deps.DistSSHKit]]
            uuid = "ceec0504-c968-4be5-b215-667cae0e8f81"
            version = "0.9.0"

            [[deps.DistSSHRun]]
            uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            version = "0.1.16"
            """,
        )
        parsed = TOML.parsefile(man)
        @test parsed["manifest_format"] == "2.0"
        @test parsed["deps"]["DistSSHRun"] isa Vector
        vers = DistSSHRun._distssh_versions_from_manifest(man)
        @test vers["DistSSHRun"] == "0.1.16"
        @test vers["DistSSHKit"] == "0.9.0"
        write(joinpath(proj, "Project.toml"), "name = \"Fmt2Job\"\n")
        old = Base.active_project()
        try
            Pkg.activate(proj; io = devnull)
            snap = Core.eval(Main, DistSSHRun._worker_identity_expr())
            @test snap isa AbstractDict
            @test snap["pkg.DistSSHRun"] == "0.1.16"
            @test snap["pkg.DistSSHKit"] == "0.9.0"
        finally
            old === nothing || Pkg.activate(old; io = devnull)
        end
        slots = DistSSHRun.GoSlot[DistSSHRun.GoSlot(:parent, nothing, "parent")]
        DistSSHRun.verify_go_slots_match_job!(proj, slots)
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"VerMan\"\n")
        write(
            joinpath(proj, "Manifest.toml"), """
            julia_version = "1.12.0"
            manifest_format = "2.0"
            project_hash = "0123456789abcdef0123456789abcdef01234567"

            [[deps.DistSSHRun]]
            uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            version = "0.0.1"
            """
        )
        vman = joinpath(
            proj,
            "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
        )
        write(
            vman, """
            julia_version = "$(VERSION)"
            manifest_format = "2.0"
            project_hash = "0123456789abcdef0123456789abcdef01234567"

            [[deps.DistSSHRun]]
            uuid = "b568025c-2759-4ef1-8b14-17d00e2cd000"
            version = "0.1.16"
            """
        )
        @test DistSSHRun._existing_project_manifest(proj) == vman
        old = Base.active_project()
        try
            Pkg.activate(proj; io = devnull)
            snap = Core.eval(Main, DistSSHRun._worker_identity_expr())
            @test snap["manifest"] == vman
            @test snap["pkg.DistSSHRun"] == "0.1.16"
        finally
            old === nothing || Pkg.activate(old; io = devnull)
        end
    end
end
