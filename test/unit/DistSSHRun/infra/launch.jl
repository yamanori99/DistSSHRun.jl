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
    withenv("DISTSSH_BLAS_THREADS" => "1") do
        pinned = Dict(DistSSHRun.worker_env_pairs("/tmp/job"))
        @test pinned["OPENBLAS_NUM_THREADS"] == "1"
        @test pinned["OMP_NUM_THREADS"] == "1"
    end
    DistSSHRun.reset_worker_seeds!()
    a, b = withenv("DISTSSH_JOB_SEED" => "11") do
        aa = Dict(DistSSHRun.worker_env_pairs("/tmp/job"; rank = DistSSHRun.take_worker_rank()))
        bb = Dict(DistSSHRun.worker_env_pairs("/tmp/job"; rank = DistSSHRun.take_worker_rank()))
        aa, bb
    end
    @test a["DISTSSH_WORKER_RANK"] == "1"
    @test b["DISTSSH_WORKER_RANK"] == "2"
    @test a["DISTSSH_WORKER_SEED"] != b["DISTSSH_WORKER_SEED"]
    @test DistSSHRun.worker_seed(11, 1) == parse(UInt64, a["DISTSSH_WORKER_SEED"])
    @test DistSSHRun.worker_seed(11, 1) == DistSSHRun.worker_seed(11, 1)
    built = DistSSHRun._source_from_user(Dict{String, Any}("commit" => "abc", "nope" => "x"))
    @test built["commit"] == "abc"
    @test !haskey(built, "nope")
    DistSSHRun.reset_worker_seeds!()
    @test DistSSHRun.worker_pmap(identity, [10, 20]) == [10, 20]
    @test DistSSHRun._ITEM_MAP[(1, 1)] == 0
    @test DistSSHRun._ITEM_MAP[(1, 2)] == 0
    withenv("DISTSSH_WORKER_RANK" => "4") do
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
    withenv("DISTSSH_JOB_SEED" => "11") do
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
        snap_dir = joinpath(slot, ".distssh")
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
        withenv("DISTRIBUTED_OUTPUT_DIR" => slot, "DISTSSH_WORKER_RANK" => "3") do
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
    capped = withenv("DISTSSH_BLAS_THREADS" => "1") do
        DistSSHRun.go_remote_julia_prefix("julia"; blas = DistSSHRun._explicit_blas_threads())
    end
    unset_at = findfirst("-u OPENBLAS_NUM_THREADS", capped)
    set_at = findfirst("OPENBLAS_NUM_THREADS=", capped)
    @test unset_at !== nothing && set_at !== nothing && first(unset_at) < first(set_at)
    @test occursin("OMP_NUM_THREADS=", capped)

    @test DistSSHRun.unsafe_heterogeneous_argv(false) == String[]
    @test DistSSHRun.unsafe_heterogeneous_argv(true) == ["--unsafe-heterogeneous"]

    parent = Dict(
        "version" => string(VERSION),
        "commit" => string(Base.GIT_VERSION_INFO.commit),
        "manifest.sha256" => "a"^64,
        "project.sha256" => "b"^64,
        "pkg.DistSSHRun" => "0.1.0",
    )
    worker = Dict(
        "version" => string(VERSION),
        "commit" => string(Base.GIT_VERSION_INFO.commit),
        "manifest.sha256" => "a"^64,
        "project.sha256" => "b"^64,
        "pkg.DistSSHRun" => "0.1.0",
    )
    @test isempty(DistSSHRun.identity_mismatches(parent, worker))

    sha_miss = DistSSHRun.identity_mismatches(
        parent,
        Dict(
            "version" => string(VERSION),
            "commit" => string(Base.GIT_VERSION_INFO.commit),
            "manifest.sha256" => "c"^64,
            "project.sha256" => "b"^64,
        ),
    )
    @test any(occursin("manifest.sha256", l) for l in sha_miss)

    same_path_diff = DistSSHRun.identity_mismatches(
        Dict(
            "version" => "1",
            "commit" => "a",
            "manifest.sha256" => "d"^64,
            "project.sha256" => "e"^64,
        ),
        Dict(
            "version" => "1",
            "commit" => "a",
            "manifest" => "/job/Manifest.toml",
            "manifest.sha256" => "f"^64,
            "project.sha256" => "e"^64,
        ),
    )
    want_d = "d"^64
    @test any(occursin("manifest.sha256 parent=$(want_d)", l) for l in same_path_diff)

    missing_snap = DistSSHRun.identity_mismatches(
        parent,
        Dict("version" => "1", "commit" => "a", "manifest.sha256" => "", "project.sha256" => ""),
    )
    @test any(occursin("manifest.sha256 missing", l) for l in missing_snap)

    @test isempty(DistSSHRun.identity_mismatches(parent, worker; unsafe_heterogeneous = true))

    julia_lines = DistSSHRun.identity_mismatches(
        parent,
        Dict(
            "version" => "1.9.0",
            "commit" => parent["commit"],
            "manifest.sha256" => parent["manifest.sha256"],
            "project.sha256" => parent["project.sha256"],
        ),
    )
    @test any(occursin("julia version", l) for l in julia_lines)

    combo_mismatch = DistSSHRun.identity_mismatches(
        parent,
        Dict(
            "version" => "1.9.0",
            "commit" => "0000000000000000000000000000000000000000",
            "manifest.sha256" => "c"^64,
            "project.sha256" => parent["project.sha256"],
        ),
    )
    @test any(occursin("julia version", l) for l in combo_mismatch)
    @test any(occursin("commit", l) for l in combo_mismatch)
    @test any(occursin("manifest.sha256", l) for l in combo_mismatch)
    @test isempty(
        DistSSHRun.identity_mismatches(
            parent,
            Dict(
                "version" => "1.9.0",
                "commit" => "0000000000000000000000000000000000000000",
                "manifest.sha256" => "c"^64,
                "project.sha256" => parent["project.sha256"],
            ),
            unsafe_heterogeneous = true,
        ),
    )

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"VerifyGate\"\n")
        write(joinpath(proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        ident = DistSSHRun.run_identity(proj)
        @test !isempty(ident["manifest.sha256"])
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"ShaJob\"\n")
        write(joinpath(proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        ident = DistSSHRun.run_identity(proj)
        @test ident["manifest.sha256"] == DistSSHRun.file_sha256(joinpath(proj, "Manifest.toml"))
        @test ident["project.sha256"] == DistSSHRun.file_sha256(joinpath(proj, "Project.toml"))
        alt = joinpath(proj, "Manifest.toml")
        write(alt, "manifest_format = \"2.0\"\n# stale\n")
        worker_sha = DistSSHRun.file_sha256(alt)
        @test worker_sha != ident["manifest.sha256"]
        lines = DistSSHRun.identity_mismatches(
            ident,
            Dict(
                "version" => ident["version"],
                "commit" => ident["commit"],
                "manifest.sha256" => worker_sha,
                "project.sha256" => ident["project.sha256"],
            ),
        )
        @test any(occursin("manifest.sha256", l) for l in lines)
    end

    pin = DistSSHRun.pin_local_julia(nothing)
    @test isabspath(pin)
    @test isfile(pin) || islink(pin)

    DistSSHRun.ensure_run_cluster_cookie!()
    raw = strip(Distributed.cluster_cookie())
    @test length(raw) >= 16

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
            rid = DistSSHRun.run_identity(proj)
            @test snap["manifest.sha256"] == rid["manifest.sha256"]
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
        ident = DistSSHRun.run_identity(proj)
        @test ident["manifest"] == vman
        @test ident["manifest.sha256"] == DistSSHRun.file_sha256(vman)
        @test ident["pkg.DistSSHRun"] == "0.1.16"
        @test ident["version"] == string(VERSION)
        @test ident["commit"] == string(Base.GIT_VERSION_INFO.commit)
        @test ident["julia"] == joinpath(Sys.BINDIR, "julia")
        @test !haskey(ident, "pkg.DistSSHKit")
        old = Base.active_project()
        try
            Pkg.activate(proj; io = devnull)
            snap = Core.eval(Main, DistSSHRun._worker_identity_expr())
            @test snap["manifest"] == vman
            @test snap["manifest.sha256"] == ident["manifest.sha256"]
            @test snap["pkg.DistSSHRun"] == "0.1.16"
        finally
            old === nothing || Pkg.activate(old; io = devnull)
        end
    end

    @testset "cluster cookie (subprocess)" begin
        DistSSHRun.verify_distributed_init_probe!()

        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        proj = if isdefined(Main, :TEST_PROJECT)
            String(TEST_PROJECT)
        else
            String(something(Base.active_project(), pkgdir(DistSSHRun)))
        end
        cmd = code -> `$julia --startup-file=no --history-file=no --project=$proj -e $code`

        rng_snapshot_code = raw"""
        using Random, Distributed, DistSSHRun
        function baseline_next()
            Random.seed!(7)
            return rand(Random.default_rng(), 1:1000, 8)
        end
        ref = baseline_next()
        Random.seed!(7)
        r = Random.default_rng()
        before = copy(r)
        DistSSHRun.preserve_task_local_default_rng() do
            DistSSHRun.ensure_run_cluster_cookie!()
        end
        after = copy(r)
        got = rand(r, 1:1000, 8)
        print((before == after && got == ref) ? "ok" : "fail")
        """
        @test strip(String(read(cmd(rng_snapshot_code)))) == "ok"

        keep_code = raw"""
        using Distributed, DistSSHRun
        mine = "usercookie123456"
        Distributed.cluster_cookie(mine)
        DistSSHRun.preserve_task_local_default_rng() do
            DistSSHRun.ensure_run_cluster_cookie!()
        end
        print(strip(Distributed.cluster_cookie()) == mine ? "ok" : "fail")
        """
        @test strip(String(read(cmd(keep_code)))) == "ok"

        preinit_keep_code = raw"""
        using Distributed, DistSSHRun
        mine = "usercookie123456"
        Distributed.cluster_cookie(mine)
        DistSSHRun.preserve_task_local_default_rng() do
            DistSSHRun.preserve_task_local_default_rng() do
                DistSSHRun.ensure_run_cluster_cookie!()
            end
        end
        print(strip(Distributed.cluster_cookie()) == mine ? "ok" : "fail")
        """
        @test strip(String(read(cmd(preinit_keep_code)))) == "ok"

        no_touch_rng_code = raw"""
        using Random, Distributed, DistSSHRun
        Random.seed!(7)
        r = Random.default_rng()
        ref = rand(r, 1:1000, 8)
        Random.seed!(7)
        DistSSHRun.preserve_task_local_default_rng() do
            Distributed.cluster_cookie("usercookie123456")
            DistSSHRun.ensure_run_cluster_cookie!()
        end
        got = rand(r, 1:1000, 8)
        print(got == ref ? "ok" : "fail")
        """
        @test strip(String(read(cmd(no_touch_rng_code)))) == "ok"

        rng_code = raw"""
        using Random, Distributed, DistSSHRun
        function baseline()
            Random.seed!(7)
            r = Random.default_rng()
            p = rand(r, 1:1000, 8)
            s = fetch(Threads.@spawn rand(1:1000, 8))
            return (p, s)
        end
        ref_p, ref_s = baseline()
        Random.seed!(7)
        r = Random.default_rng()
        DistSSHRun.preserve_task_local_default_rng() do
            DistSSHRun.ensure_run_cluster_cookie!()
            before = Set(workers())
            addprocs(1; exeflags=`--startup-file=no`)
            left = setdiff(Set(workers()), before)
            isempty(left) || rmprocs(collect(left); waitfor = 30)
        end
        got_p = rand(r, 1:1000, 8)
        got_s = fetch(Threads.@spawn rand(1:1000, 8))
        print((ref_p == got_p && ref_s == got_s) ? "ok" : "fail")
        """
        @test strip(String(read(cmd(rng_code)))) == "ok"

        nested_preserve_code = raw"""
        using Random, Distributed, DistSSHRun
        function first_eight()
            Random.seed!(7)
            return rand(Random.default_rng(), 1:1000, 8)
        end
        ref = first_eight()
        Random.seed!(7)
        r = Random.default_rng()
        DistSSHRun.preserve_task_local_default_rng() do
            DistSSHRun.preserve_task_local_default_rng() do
                DistSSHRun.ensure_run_cluster_cookie!()
            end
        end
        got = rand(r, 1:1000, 8)
        print(got == ref ? "ok" : "fail")
        """
        @test strip(String(read(cmd(nested_preserve_code)))) == "ok"
    end
end
