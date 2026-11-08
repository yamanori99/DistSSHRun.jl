using Test
using TOML

const _SNAP_ID_OLD = "20260101T000000Z-aaaaaa"
const _SNAP_ID_NEW = "20260102T000000Z-bbbbbb"

function _snap_project!(dir::AbstractString)
    write(joinpath(dir, "Project.toml"), "name = \"SnapSel\"\n")
    write(
        joinpath(dir, "Manifest.toml"),
        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
    )
    write(joinpath(dir, "a.jl"), "1\n")
    return dir
end

function _workspace_member_layout!(root::AbstractString)
    write(joinpath(root, "Project.toml"), "[workspace]\nprojects = [\"pkg\"]\n")
    write(
        joinpath(root, "Manifest.toml"),
        "julia_version = \"1.13.0\"\nmanifest_format = \"2.0\"\n",
    )
    mkpath(joinpath(root, "pkg"))
    write(
        joinpath(root, "pkg", "Project.toml"),
        "name = \"Pkg\"\nuuid = \"11111111-1111-1111-1111-111111111111\"\n",
    )
    return joinpath(root, "pkg")
end

@testset "snapshot id validation" begin
    @test DistSSHRun.validate_snapshot_id(_SNAP_ID_OLD) == _SNAP_ID_OLD
    @test_throws ArgumentError DistSSHRun.validate_snapshot_id("../x")
    @test_throws ArgumentError DistSSHRun.validate_snapshot_id("a/b")
    @test_throws ArgumentError DistSSHRun.validate_snapshot_id("a\\b")
    @test_throws ArgumentError DistSSHRun.validate_snapshot_id(".")
    @test_throws ArgumentError DistSSHRun.validate_snapshot_id("..")
    @test_throws ArgumentError DistSSHRun.validate_snapshot_id("not-a-run-id")
end

@testset "local last-snapshot record" begin
    _with_tempdir() do tmp
        _snap_project!(tmp)
        DistSSHRun.clear_last_snapshot_record!(tmp)
        @test DistSSHRun.read_last_snapshot_record(tmp) === nothing
        DistSSHRun.write_last_snapshot_record!(
            tmp, "~/App/SnapSel", ["h2", "h1", "h1"], _SNAP_ID_OLD;
            content_tree_hash = "abc",
        )
        rec = something(DistSSHRun.read_last_snapshot_record(tmp))
        @test rec["snapshot_id"] == _SNAP_ID_OLD
        @test rec["deploy_root"] == "~/App/SnapSel"
        @test rec["hosts"] == ["h1", "h2"]
        @test rec["content_tree_hash"] == "abc"
        # Overwrite limitation: a later write replaces the convenience default.
        DistSSHRun.write_last_snapshot_record!(
            tmp, "~/App/SnapSel", ["h1"], _SNAP_ID_NEW,
        )
        rec2 = something(DistSSHRun.read_last_snapshot_record(tmp))
        @test rec2["snapshot_id"] == _SNAP_ID_NEW
        @test rec2["hosts"] == ["h1"]
    end
end

@testset "completion stamp toml keeps ownership" begin
    stamp = DistSSHRun._ship_run_leaf_stamp_toml()
    complete = DistSSHRun._ship_run_leaf_complete_toml("deadbeef")
    @test occursin("complete = true", complete)
    @test occursin("content_tree_hash", complete)
    @test DistSSHRun._kit_run_toml_owned(TOML.parse(stamp))
    @test DistSSHRun._kit_run_toml_owned(TOML.parse(complete))
end

@testset "setup --snapshot argv" begin
    p = DistSSHRun.parse_setup_args(
        String["--instantiate", "--snapshot", _SNAP_ID_OLD, "child:h1"],
    )
    @test p.snapshot_id == _SNAP_ID_OLD
    @test_throws ArgumentError DistSSHRun.parse_setup_args(
        String["--ship-tree", "--snapshot", _SNAP_ID_OLD, "child:h1"],
    )
    @test_throws ArgumentError DistSSHRun.parse_setup_args(
        String["--instantiate", "--snapshot", "../x", "child:h1"],
    )
end

@testset "go/drive --snapshot argv" begin
    g = DistSSHRun.parse_go_args(
        String["--snapshot", _SNAP_ID_OLD, "parent:1", "job.jl"],
    )
    @test g.snapshot == _SNAP_ID_OLD
    d = DistSSHRun.parse_drive_args(
        String["--snapshot", _SNAP_ID_NEW, "parent:1", "job.jl"],
    )
    @test d.snapshot == _SNAP_ID_NEW
    @test_throws ArgumentError DistSSHRun.parse_go_args(
        String["--ship-tree", "--snapshot", _SNAP_ID_OLD, "parent:1", "job.jl"],
    )
    @test_throws ArgumentError DistSSHRun.parse_drive_args(
        String["--sync", "--snapshot", _SNAP_ID_OLD, "parent:1", "job.jl"],
    )
end

@testset "forget_last_snapshot_default clears matching record" begin
    _with_tempdir() do proj
        _snap_project!(proj)
        DistSSHRun.write_last_snapshot_record!(
            proj, "/deploy/a", ["h1"], _SNAP_ID_OLD,
        )
        DistSSHRun.forget_last_snapshot_default!(proj, "/deploy/b")
        @test DistSSHRun.read_last_snapshot_record(proj) !== nothing
        DistSSHRun.forget_last_snapshot_default!(proj, "/deploy/a")
        @test DistSSHRun.read_last_snapshot_record(proj) === nothing
    end
end

@testset "help no longer advertises lexical latest" begin
    text = DistSSHRun.setup_help_text()
    @test occursin("--snapshot", text)
    @test !occursin("latest runs/<run_id>/src", text)
end

@testset "workspace member ship root vs rehome (packaging mismatch)" begin
    _with_tempdir() do root
        member = _workspace_member_layout!(root)
        env = DistSSHRun.resolve_pkg_env(member)
        @test env.env_dir == DistSSHRun.canonical_local_path(root)
        @test env.project_dir == DistSSHRun.canonical_local_path(member)
        # Ship packs project_dir (member), not env_dir (workspace).
        ship_root = DistSSHRun._ship_tree_root(member)
        @test ship_root == DistSSHRun.canonical_local_path(member)
        # Selection rehomes member onto runs/<id>/src/<member-rel>.
        deploy = "/home/dev/app"
        wr = "/home/dev/app/runs/$_SNAP_ID_OLD/src"
        mapped = DistSSHRun.resolve_remote_project_root(
            member; cli_override = deploy,
        )
        @test mapped == "/home/dev/app/pkg"
        rehomed = DistSSHRun._rehome_under_work_root(mapped, deploy, wr)
        @test rehomed == "/home/dev/app/runs/$_SNAP_ID_OLD/src/pkg"
        # That path is wrong for a member-only archive whose Project.toml is at src/.
        # Supported layout: ship from env_dir (workspace root). Deferred archive widen.
        ws_root = DistSSHRun._ship_tree_root(root)
        @test ws_root == DistSSHRun.canonical_local_path(root)
    end
end

@testset "fake-ssh complete snapshot selection" begin
    double = abspath(
        joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"),
    )
    @test isfile(double)
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        old_leaf = joinpath(remote, "runs", _SNAP_ID_OLD)
        new_leaf = joinpath(remote, "runs", _SNAP_ID_NEW)
        for (leaf, hash) in ((old_leaf, "oldhash"), (new_leaf, "newhash"))
            mkpath(joinpath(leaf, "src"))
            write(joinpath(leaf, "src", "Project.toml"), "name = \"SnapSel\"\n")
            write(joinpath(leaf, "run.toml"), DistSSHRun._ship_run_leaf_complete_toml(hash))
        end
        # Legacy incomplete leaf (ownership only).
        legacy = joinpath(remote, "runs", "20260103T000000Z-cccccc")
        mkpath(joinpath(legacy, "src"))
        write(joinpath(legacy, "src", "Project.toml"), "name = \"SnapSel\"\n")
        write(joinpath(legacy, "run.toml"), DistSSHRun._ship_run_leaf_stamp_toml())

        _with_tempdir() do proj
            _snap_project!(proj)
            env = Dict{String, String}(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => double,
                "DISTSSHKIT_TEST_POSIX_SHELL" => "1",
                "DISTSSHKIT_TEST_REMOTE_HOME" => "/home/distsshkit",
            )
            try
                withenv(env...) do
                    DistSSHRun.clear_last_snapshot_record!(proj)
                    DistSSHRun._clear_last_ship!()
                    # Explicit old id after a newer leaf exists.
                    sel = DistSSHRun.resolve_snapshot_selection(
                        ["child-1", "child-2"], remote, proj;
                        snapshot = _SNAP_ID_OLD,
                    )
                    @test sel.source_kind === :snapshot
                    @test sel.snapshot_id == _SNAP_ID_OLD
                    @test endswith(sel.work_root, "/runs/$_SNAP_ID_OLD/src")
                    @test sel.content_tree_hash == "oldhash"

                    # Host order does not change the selected id.
                    sel2 = DistSSHRun.resolve_snapshot_selection(
                        ["child-2", "child-1"], remote, proj;
                        snapshot = _SNAP_ID_OLD,
                    )
                    @test sel2.snapshot_id == _SNAP_ID_OLD

                    # Local record default.
                    DistSSHRun.write_last_snapshot_record!(
                        proj, remote, ["child-1", "child-2"], _SNAP_ID_OLD;
                        content_tree_hash = "oldhash",
                    )
                    sel3 = DistSSHRun.resolve_snapshot_selection(
                        ["child-1", "child-2"], remote, proj,
                    )
                    @test sel3.snapshot_id == _SNAP_ID_OLD

                    # Explicit overrides record pointing at newer.
                    DistSSHRun.write_last_snapshot_record!(
                        proj, remote, ["child-1", "child-2"], _SNAP_ID_NEW,
                    )
                    sel4 = DistSSHRun.resolve_snapshot_selection(
                        ["child-1"], remote, proj; snapshot = _SNAP_ID_OLD,
                    )
                    @test sel4.snapshot_id == _SNAP_ID_OLD

                    # Incomplete / legacy is not selectable.
                    @test_throws ArgumentError DistSSHRun.resolve_snapshot_selection(
                        ["child-1"], remote, proj;
                        snapshot = "20260103T000000Z-cccccc",
                    )

                    # Host set not covered by record fails (no latest fallback).
                    DistSSHRun.write_last_snapshot_record!(
                        proj, remote, ["child-1"], _SNAP_ID_OLD,
                    )
                    @test_throws ArgumentError DistSSHRun.resolve_snapshot_selection(
                        ["child-1", "child-2"], remote, proj,
                    )

                    # Missing snapshot on one host.
                    rm(joinpath(old_leaf, "src", "Project.toml"); force = true)
                    @test_throws ArgumentError DistSSHRun.resolve_snapshot_selection(
                        ["child-1"], remote, proj; snapshot = _SNAP_ID_OLD,
                    )
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_last_ship!()
            end
        end
    end
end

@testset "git checkout remains selectable without snapshot" begin
    double = abspath(
        joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"),
    )
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        mkpath(remote)
        write(joinpath(remote, "Project.toml"), "name = \"GitRoot\"\n")
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.clear_last_snapshot_record!(proj)
            DistSSHRun._clear_last_ship!()
            env = Dict{String, String}(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => double,
                "DISTSSHKIT_TEST_POSIX_SHELL" => "1",
                "DISTSSHKIT_TEST_REMOTE_HOME" => "/home/distsshkit",
            )
            try
                withenv(env...) do
                    sel = DistSSHRun.resolve_snapshot_selection(
                        ["child-1"], remote, proj,
                    )
                    @test sel.source_kind === :git
                    @test sel.snapshot_id === nothing
                    @test sel.work_root == remote
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            end
        end
    end
end
