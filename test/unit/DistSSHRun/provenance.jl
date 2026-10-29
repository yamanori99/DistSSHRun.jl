using Test
using Distributed

const _PROV_ENV_OFF = (
    "DISTSSHKIT_SOURCE_COMMIT" => nothing,
    "DISTSSHKIT_SOURCE_DIRTY" => nothing,
    "DISTSSHKIT_SOURCE_DIFF_SHA256" => nothing,
    "DISTSSHKIT_SOURCE_CAPTURED" => nothing,
    "DISTSSHKIT_SOURCE_UNTRACKED" => nothing,
)

function _prov_snap(;
        version::String = "1.13.2",
        commit::String = "abc",
        blas::String = "not loaded",
    )::Dict{String, String}
    return Dict{String, String}(
        "version" => version,
        "commit" => commit,
        "cpu" => "cpu",
        "machine" => "aarch64",
        "kernel" => "Darwin",
        "nthreads" => "2",
        "blas" => blas,
        "blas_threads" => blas == "not loaded" ? "not loaded" : "4",
        "hostname" => "box",
    )
end

function _prov_git!(dir::String)
    run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.email "test@example.com"`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir config user.name "Test"`; stdout = devnull, stderr = devnull))
    write(joinpath(dir, "f.txt"), "hi\n")
    run(pipeline(`git -C $dir add f.txt`; stdout = devnull, stderr = devnull))
    run(pipeline(`git -C $dir -c commit.gpgsign=false commit -q -m init`; stdout = devnull, stderr = devnull))
    return nothing
end

function _prov_clear_modules!(ex::Expr)
    if ex.head === :for
        ex.args[1].args[2] = :(())
    end
    for arg in ex.args
        arg isa Expr && _prov_clear_modules!(arg)
    end
    return ex
end

function _prov_require(raw)::AbstractDict
    raw isa AbstractDict || error("run.toml missing")
    return raw
end

function _prov_run_toml(root::String)::String
    found = String[]
    for (dir, _, files) in walkdir(root)
        if "run.toml" in files
            push!(found, joinpath(dir, "run.toml"))
        end
    end
    return only(found)
end

@testset "provenance" begin
    @testset "groups" begin
        same = DistSSHRun._group_snapshots([_prov_snap(), _prov_snap()])
        @test length(same) == 1
        @test same[1]["n"] == 2
        split_v = DistSSHRun._group_snapshots(
            [
                _prov_snap(),
                _prov_snap(; version = "1.14.0-alpha1"),
            ]
        )
        @test length(split_v) == 2
        @test all(g -> g["n"] == 1, split_v)
        failed = DistSSHRun._group_snapshots(
            [
                Dict{String, String}("error" => "gone"),
            ]
        )
        @test failed[1]["error"] == "gone"
        @test failed[1]["n"] == 1
        @test DistSSHRun._provenance_token("parent") == "parent"
        @test DistSSHRun._provenance_token("box") == "child:box"
        plain = _prov_snap()
        opt = _prov_snap()
        opt["install"] = "julia-1.14.0-alpha1+0.aarch64.apple.darwin14.opt"
        split_install = DistSSHRun._group_snapshots([plain, opt])
        @test length(split_install) == 2
        @test all(g -> g["n"] == 1, split_install)
        @test !haskey(split_install[1], "install")
        @test split_install[2]["install"] == opt["install"]
        @test !haskey(failed[1], "install")
        blank = _prov_snap()
        blank["install"] = ""
        @test length(DistSSHRun._group_snapshots([plain, blank])) == 1
        @test !haskey(DistSSHRun._group_body(blank), "install")
        incomplete = _prov_snap()
        delete!(incomplete, "commit")
        @test_throws KeyError DistSSHRun._group_key(incomplete)
    end

    @testset "install name" begin
        mac_plain = joinpath(
            "/Users/x/.julia/juliaup",
            "julia-1.14.0-alpha1+0.aarch64.apple.darwin14",
            "Julia-1.14.app", "Contents", "Resources", "julia", "bin",
        )
        mac_opt = joinpath(
            "/Users/x/.julia/juliaup",
            "julia-1.14.0-alpha1+0.aarch64.apple.darwin14.opt",
            "Julia-1.14-opt.app", "Contents", "Resources", "julia", "bin",
        )
        @test basename(dirname(mac_plain)) == "julia"
        @test basename(dirname(mac_opt)) == "julia"
        @test DistSSHRun._julia_install_name(mac_plain) ==
            "julia-1.14.0-alpha1+0.aarch64.apple.darwin14"
        @test DistSSHRun._julia_install_name(mac_opt) ==
            "julia-1.14.0-alpha1+0.aarch64.apple.darwin14.opt"
        linux = "/home/x/.julia/juliaup/julia-1.14.0-alpha1+0.x86_64-linux-gnu/bin"
        linux_assert = "/home/x/.julia/juliaup/julia-1.14.0-alpha1+0.x86_64-linux-gnu.assert/bin"
        @test DistSSHRun._julia_install_name(linux) ==
            "julia-1.14.0-alpha1+0.x86_64-linux-gnu"
        @test DistSSHRun._julia_install_name(linux_assert) ==
            "julia-1.14.0-alpha1+0.x86_64-linux-gnu.assert"
        @test DistSSHRun._julia_install_name("/home/x/.julia/juliaup/julia-nightly+assert/bin") ==
            "julia-nightly+assert"
        @test DistSSHRun._julia_install_name("/home/x/.julia/juliaup/julia-nightly+nogpl/bin") ==
            "julia-nightly+nogpl"
        @test DistSSHRun._julia_install_name("/home/x/.julia/juliaup/julia-nightly+assert+opt/bin") ==
            "julia-nightly+assert+opt"
        @test DistSSHRun._julia_install_name("/home/x/.julia/juliaup/julia-nightly~x64/bin") ==
            "julia-nightly~x64"
        @test DistSSHRun._julia_install_name("/opt/julia-outer/julia-inner/bin") == "julia-inner"
        @test DistSSHRun._julia_install_name("/usr/bin") === nothing
        @test DistSSHRun._julia_install_name("") === nothing
        @test DistSSHRun._julia_install_name("julia-1.14/bin") === nothing
        julia, machine = DistSSHRun._parent_sections(_prov_snap())
        @test julia == Dict("version" => "1.13.2", "commit" => "abc")
        @test !haskey(machine, "install")
        with_install = _prov_snap()
        with_install["install"] = "julia-nightly+nogpl"
        julia_named, _ = DistSSHRun._parent_sections(with_install)
        @test julia_named["install"] == "julia-nightly+nogpl"
        @test julia_named["version"] == "1.13.2"
        err_julia, err_machine = DistSSHRun._parent_sections(
            Dict{String, String}("error" => "gone"),
        )
        @test err_julia == Dict("error" => "gone")
        @test isempty(err_machine)
        live = DistSSHRun._local_process_snapshot()
        @test live["version"] == string(VERSION)
        @test haskey(live, "commit")
        expected = DistSSHRun._julia_install_name(Sys.BINDIR)
        if expected === nothing
            @test !haskey(live, "install")
        else
            @test live["install"] == expected
            @test !occursin('/', live["install"])
        end
        parent_live, _ = DistSSHRun._parent_sections(live)
        @test parent_live["version"] == string(VERSION)
        @test haskey(parent_live, "commit")
        if expected === nothing
            @test !haskey(parent_live, "install")
        else
            @test parent_live["install"] == expected
        end
        _with_tempdir() do tmp
            script = DistSSHRun.write_go_slot_loader(tmp)
            @test script !== nothing
            run(
                addenv(
                    `$(Base.julia_cmd()) --startup-file=no $script`,
                    "DISTRIBUTED_OUTPUT_DIR" => tmp,
                )
            )
            slot = DistSSHRun._read_go_slot_snapshot(
                joinpath(tmp, ".distsshkit", "provenance-slot.toml"),
            )
            @test slot["version"] == string(VERSION)
            @test haskey(slot, "commit")
            @test !haskey(slot, "error")
            if expected === nothing
                @test !haskey(slot, "install")
            else
                @test slot["install"] == expected
            end
        end
    end

    @testset "worker fetch does not throw" begin
        bad = DistSSHRun._fetch_process_snapshot(typemax(Int))
        @test haskey(bad, "error")
        pids = addprocs(1; exeflags = `--startup-file=no`)
        try
            snap = DistSSHRun._fetch_process_snapshot(only(pids))
            @test snap["version"] == string(VERSION)
            @test !isempty(snap["blas"])
            @test !haskey(snap, "error")
            fetched_install = DistSSHRun._julia_install_name(Sys.BINDIR)
            if fetched_install === nothing
                @test !haskey(snap, "install")
            else
                @test snap["install"] == fetched_install
            end
            bare = Core.eval(Main, _prov_clear_modules!(DistSSHRun._process_snapshot_expr()))
            @test bare["blas"] == "not loaded"
            @test bare["blas_threads"] == "not loaded"
        finally
            rmprocs(pids)
        end
    end

    @testset "diff flags" begin
        @test collect(DistSSHRun._GIT_DIFF_FLAGS) == [
            "-c", "core.quotepath=off",
            "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", "HEAD",
        ]
    end

    @testset "write" begin
        _with_tempdir() do tmp
            out = joinpath(tmp, "out")
            mkpath(out)
            prov = Dict{String, Any}(
                "julia" => Dict{String, Any}(
                    "parent" => Dict{String, Any}(
                        "version" => "1.13.2",
                        "commit" => "abc",
                    ),
                ),
                "machine" => Dict{String, Any}(
                    "parent" => Dict{String, Any}("hostname" => "box", "blas" => "not loaded"),
                ),
                "workers" => Any[],
                "project" => Dict{String, Any}("manifest" => "absent"),
                "source" => Dict{String, Any}(
                    "commit" => "abc",
                    "dirty" => false,
                    "diff_sha256" => "e3b0",
                    "captured" => "run",
                    "untracked" => 0,
                ),
            )
            DistSSHRun.write_kit_run_toml!(
                tmp;
                kind = :go,
                output_dir = out,
                result = nothing,
                provenance = prov,
            )
            raw = _prov_require(DistSSHRun.read_kit_run_toml(tmp))
            @test raw["schema"] == 1
            @test startswith(String(raw["writer"]), "DistSSHRun ")
            @test raw["kind"] == "go"
            @test haskey(raw, "run_dir")
            @test raw["provenance"]["project"]["manifest"] == "absent"
            @test raw["provenance"]["workers"] == []
            @test raw["provenance"]["julia"]["parent"]["version"] == "1.13.2"
            side = DistSSHRun.TOML.parsefile(joinpath(out, ".distsshkit", "provenance.toml"))
            @test side == raw["provenance"]
            grouped = Dict{String, Any}(
                "child:box" => [
                    Dict{String, Any}(
                        "version" => "1.13.2",
                        "commit" => "abc",
                        "n" => 2,
                        "blas" => "not loaded",
                    ),
                ],
            )
            prov["workers"] = grouped
            DistSSHRun.write_kit_run_toml!(
                tmp;
                kind = :go,
                output_dir = out,
                provenance = prov,
            )
            grouped_raw = _prov_require(DistSSHRun.read_kit_run_toml(tmp))
            @test grouped_raw["schema"] == 1
            @test grouped_raw["provenance"]["workers"]["child:box"][1]["n"] == 2
            grouped_side = DistSSHRun.TOML.parsefile(joinpath(out, ".distsshkit", "provenance.toml"))
            @test grouped_side == grouped_raw["provenance"]
            DistSSHRun.write_kit_run_toml!(tmp; kind = :go, output_dir = out)
            again = _prov_require(DistSSHRun.read_kit_run_toml(tmp))
            @test again["schema"] == 1
            @test !haskey(again, "provenance")
        end
    end

    @testset "assemble" begin
        withenv(_PROV_ENV_OFF...) do
            DistSSHRun._set_provenance_source!(nothing)
            _with_tempdir() do tmp
                prov = DistSSHRun.assemble_provenance(tmp)
                @test prov["project"]["manifest"] == "absent"
                @test prov["workers"] == []
                @test prov["julia"]["parent"]["version"] == string(VERSION)
                @test haskey(prov["julia"]["parent"], "commit")
                @test haskey(prov["machine"]["parent"], "hostname")
                @test haskey(prov["machine"]["parent"], "blas")
                @test !haskey(prov, "source")
                write(joinpath(tmp, "Project.toml"), "name = \"T\"\n")
                write(
                    joinpath(tmp, "Manifest.toml"),
                    "julia_version = \"1.13.2\"\nmanifest_format = \"2.0\"\n",
                )
                with_manifest = DistSSHRun.assemble_provenance(tmp)
                @test with_manifest["project"]["manifest"] == DistSSHRun._sha256_hex(
                    read(joinpath(tmp, "Manifest.toml")),
                )
                @test with_manifest["project"]["julia_version"] == "1.13.2"
                versioned = joinpath(tmp, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
                write(versioned, "julia_version = \"9.9.9\"\n")
                picked = DistSSHRun.assemble_provenance(tmp)
                @test picked["project"]["manifest"] == DistSSHRun._sha256_hex(read(versioned))
                @test picked["project"]["julia_version"] == "9.9.9"
            end
            if Sys.which("git") !== nothing
                _with_tempdir() do repo
                    _prov_git!(repo)
                    clean = DistSSHRun.assemble_provenance(repo)
                    @test clean["source"]["dirty"] == false
                    @test clean["source"]["untracked"] == 0
                    @test clean["source"]["captured"] == "run"
                    @test !haskey(clean["source"], "diff_sha256")
                    @test haskey(clean, "writer")
                    @test startswith(clean["writer"], "DistSSHRun ")
                    @test clean["schema"] == 1
                    head = readchomp(`git -C $repo rev-parse HEAD`)
                    @test clean["source"]["commit"] == head
                    snap = DistSSHRun.git_source_snapshot(repo)
                    @test snap isa AbstractDict
                    snap = snap::AbstractDict
                    @test snap["commit"] == head
                    @test snap["captured"] == "run"
                    @test haskey(snap, "diff_sha256")
                    @test Base.ispublic(DistSSHRun, :git_source_snapshot)
                    @test !Base.isexported(DistSSHRun, :git_source_snapshot)
                    write(joinpath(repo, "f.txt"), "changed\n")
                    dirty = DistSSHRun.assemble_provenance(repo)
                    @test dirty["source"]["dirty"] == true
                    @test dirty["source"]["untracked"] == 0
                    @test !haskey(dirty["source"], "diff_sha256")
                    write(joinpath(repo, "f.txt"), "hi\n")
                    write(joinpath(repo, "extra.txt"), "x\n")
                    only_new = DistSSHRun.assemble_provenance(repo)
                    @test only_new["source"]["dirty"] == true
                    @test only_new["source"]["untracked"] >= 1
                    @test !haskey(only_new["source"], "diff_sha256")
                    mkpath(joinpath(repo, ".distsshkit"))
                    write(joinpath(repo, ".distsshkit", "provenance.toml"), "x\n")
                    rm(joinpath(repo, "extra.txt"))
                    kit_only = DistSSHRun.assemble_provenance(repo)
                    @test kit_only["source"]["dirty"] == false
                    @test kit_only["source"]["untracked"] == 0
                    mkpath(joinpath(repo, ".distsshqueue", "tickets"))
                    write(joinpath(repo, ".distsshqueue", "tickets", "j"), "t\n")
                    queue_only = DistSSHRun.assemble_provenance(repo)
                    @test queue_only["source"]["dirty"] == false
                    @test queue_only["source"]["untracked"] == 0
                    DistSSHRun._reset_run_provenance!(repo)
                    write(joinpath(repo, "later.txt"), "after\n")
                    held = DistSSHRun.assemble_provenance(repo)
                    @test held["source"]["dirty"] == false
                    @test held["source"]["commit"] == head
                    DistSSHRun._PROVENANCE_AT_START[] = false
                    passed = Dict{String, Any}(
                        "commit" => "passed",
                        "dirty" => true,
                        "diff_sha256" => "abc",
                        "captured" => "submit:client",
                        "untracked" => 3,
                    )
                    DistSSHRun._set_provenance_source!(passed)
                    try
                        chosen = DistSSHRun.assemble_provenance(repo)
                        @test chosen["source"]["commit"] == "passed"
                        @test chosen["source"]["captured"] == "submit:client"
                        @test chosen["source"]["untracked"] == 3
                    finally
                        DistSSHRun._set_provenance_source!(nothing)
                    end
                end
            end
        end
    end

    @testset "detached source env" begin
        env = DistSSHRun._provenance_source_env(
            Dict(
                "commit" => "abc",
                "dirty" => false,
                "captured" => "submit:client",
                "untracked" => 0,
            ),
        )
        @test env["DISTSSHKIT_SOURCE_COMMIT"] == "abc"
        @test env["DISTSSHKIT_SOURCE_DIRTY"] == "false"
        @test !haskey(env, "DISTSSHKIT_SOURCE_DIFF_SHA256")
        @test env["DISTSSHKIT_SOURCE_CAPTURED"] == "submit:client"
        @test env["DISTSSHKIT_SOURCE_UNTRACKED"] == "0"
        inherited = Dict{String, String}(
            "DISTSSHKIT_SOURCE_COMMIT" => "new",
            "DISTSSHKIT_SOURCE_DIRTY" => "true",
            "OTHER" => "keep",
        )
        DistSSHRun._drop_unspecified_source_env!(
            inherited,
            Dict("commit" => "new"),
            Dict{String, String}("DISTSSHKIT_SOURCE_COMMIT" => "new"),
        )
        @test inherited["DISTSSHKIT_SOURCE_COMMIT"] == "new"
        @test !haskey(inherited, "DISTSSHKIT_SOURCE_DIRTY")
        @test inherited["OTHER"] == "keep"
        kept = Dict{String, String}("DISTSSHKIT_SOURCE_DIRTY" => "true")
        DistSSHRun._drop_unspecified_source_env!(kept, nothing, Dict{String, String}())
        @test kept["DISTSSHKIT_SOURCE_DIRTY"] == "true"
        @test isempty(DistSSHRun._provenance_source_env(nothing))
        for kind in (:go, :ride, :drive)
            @test DistSSHRun.execute_detached_accepts(:source; kind = kind)
        end
        withenv(
            "DISTSSHKIT_SOURCE_COMMIT" => "from-env",
            "DISTSSHKIT_SOURCE_DIRTY" => "true",
            "DISTSSHKIT_SOURCE_DIFF_SHA256" => "abc",
            "DISTSSHKIT_SOURCE_CAPTURED" => "submit:client",
            "DISTSSHKIT_SOURCE_UNTRACKED" => "2",
        ) do
            DistSSHRun._set_provenance_source!(nothing)
            _with_tempdir() do tmp
                got = DistSSHRun.assemble_provenance(tmp)
                @test got["source"]["commit"] == "from-env"
                @test got["source"]["dirty"] == true
                @test got["source"]["untracked"] == 2
            end
        end
    end

    @testset "git status -z" begin
        arrow = DistSSHRun._git_status_records(Vector{UInt8}("?? file -> name\0"))
        @test arrow == [("??", "file -> name")]
        renamed = DistSSHRun._git_status_records(Vector{UInt8}("R  new name\0old\0"))
        @test renamed == [("R ", "new name")]
        @test DistSSHRun._git_status_is_kit(".distsshqueue/tickets/a")
        @test DistSSHRun._git_status_is_kit("out/.distsshkit/provenance.toml")
        @test !DistSSHRun._git_status_is_kit("src/job.jl")
    end

    @testset "leftover workers keep their host" begin
        saved = copy(DistSSHRun.DRIVE_HOST_WORKER_IDS)
        try
            empty!(DistSSHRun.DRIVE_HOST_WORKER_IDS)
            DistSSHRun._register_drive_host_worker_ids!(DistSSHRun.PARENT_HOST_NAME, [2, 3])
            DistSSHRun._register_leftover_workers!([99])
            @test DistSSHRun.DRIVE_HOST_WORKER_IDS[DistSSHRun.PARENT_HOST_NAME] == [2, 3]
            @test DistSSHRun.DRIVE_HOST_WORKER_IDS["unknown"] == [99]
        finally
            empty!(DistSSHRun.DRIVE_HOST_WORKER_IDS)
            for (k, v) in saved
                DistSSHRun.DRIVE_HOST_WORKER_IDS[k] = v
            end
        end
    end

    @testset "failed script still records provenance" begin
        withenv(_PROV_ENV_OFF...) do
            DistSSHRun._set_provenance_source!(nothing)
            _with_tempdir() do proj
                script = joinpath(proj, "job.jl")
                write(script, "error(\"boom\")\n")
                result = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        return DistSSHRun.go!(
                            script, ["parent:1"];
                            project = proj, quiet = true, yes = true,
                        )
                    end
                end
                @test !result.ok
                raw = _prov_require(DistSSHRun.read_kit_run_toml(_prov_run_toml(proj)))
                @test raw["schema"] == 1
                @test raw["kind"] == "go"
                @test haskey(raw, "output_dir")
                @test raw["provenance"]["project"]["manifest"] == "absent"
                workers = raw["provenance"]["workers"]
                @test haskey(workers, "parent")
                @test workers["parent"][1]["version"] == string(VERSION)
                @test workers["parent"][1]["n"] == 1
                @test raw["provenance"]["julia"]["parent"]["version"] == string(VERSION)
                od = String(raw["output_dir"])
                side_root = isabspath(od) ? od : joinpath(proj, od)
                side = DistSSHRun.TOML.parsefile(
                    joinpath(side_root, ".distsshkit", "provenance.toml"),
                )
                @test side == raw["provenance"]
            end
        end
    end

    @testset "a bad project file does not fail the record" begin
        withenv(_PROV_ENV_OFF...) do
            DistSSHRun._set_provenance_source!(nothing)
            _with_tempdir() do proj
                write(joinpath(proj, "Project.toml"), "name = [\n")
                try
                    DistSSHRun._reset_run_provenance!(proj)
                    @test DistSSHRun._PROVENANCE_PROJECT_SNAP[] ==
                        Dict{String, Any}("manifest" => "absent")
                    @test DistSSHRun._PROVENANCE_AT_START[]
                finally
                    DistSSHRun._PROVENANCE_AT_START[] = false
                    DistSSHRun._PROVENANCE_PROJECT_SNAP[] = nothing
                    DistSSHRun._PROVENANCE_SOURCE_SNAP[] = nothing
                end
            end
        end
    end
end
