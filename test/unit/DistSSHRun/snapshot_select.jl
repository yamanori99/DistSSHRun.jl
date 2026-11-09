using Test
using TOML

const _SNAP_ID_OLD = "20260101T000000Z-aaaaaa"
const _SNAP_ID_NEW = "20260102T000000Z-bbbbbb"
const _SNAP_HASH_OLD = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const _SNAP_HASH_NEW = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

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
    complete = DistSSHRun._ship_run_leaf_complete_toml(_SNAP_HASH_OLD)
    @test occursin("complete = true", complete)
    @test occursin("content_tree_hash", complete)
    @test DistSSHRun._kit_run_toml_owned(TOML.parse(stamp))
    @test DistSSHRun._kit_run_toml_owned(TOML.parse(complete))
end

@testset "setup --snapshot argv" begin
    p = DistSSHRun.parse_setup_args(
        String["instantiate", "--snapshot", _SNAP_ID_OLD, "child:h1"],
    )
    @test p.snapshot_id == _SNAP_ID_OLD
    ship = DistSSHRun.parse_setup_args(
        String["ship-tree", "--snapshot", _SNAP_ID_OLD, "child:h1"],
    )
    @test ship.snapshot_id == _SNAP_ID_OLD
    err_mode = try
        DistSSHRun.check_setup_options!(:ship_tree; snapshot = ship.snapshot_id)
        nothing
    catch e
        e
    end
    session = DistSSHRun.KitSession(workers = ["child:h1"], project = pwd(), yes = true)
    err_api = try
        DistSSHRun.setup!(session, :ship_tree; snapshot = ship.snapshot_id)
        nothing
    catch e
        e
    end
    @test err_mode isa ArgumentError
    @test err_api isa ArgumentError
    @test err_mode.msg == err_api.msg
    bad = DistSSHRun.parse_setup_args(
        String["instantiate", "--snapshot", "../x", "child:h1"],
    )
    @test bad.snapshot_id == "../x"
    err_id_api = try
        DistSSHRun.validate_snapshot_id(bad.snapshot_id)
        nothing
    catch e
        e
    end
    err_id = try
        DistSSHRun.setup!(session, :instantiate; snapshot = bad.snapshot_id)
        nothing
    catch e
        e
    end
    @test err_id_api isa ArgumentError
    @test err_id isa ArgumentError
    @test err_id.msg == err_id_api.msg
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
    err_combo = try
        DistSSHRun.parse_go_args(
            String["--ship-tree", "--snapshot", _SNAP_ID_OLD, "parent:1", "job.jl"],
        )
        nothing
    catch e
        e
    end
    @test err_combo isa ArgumentError
    @test occursin("go --ship-tree was removed", err_combo.msg)
    gsync = DistSSHRun.parse_go_args(
        String["--sync", "--snapshot", _SNAP_ID_OLD, "parent:1", "job.jl"],
    )
    @test gsync.snapshot == _SNAP_ID_OLD
    err_go = try
        DistSSHRun.go!("job.jl", ["parent:1"]; sync = :sync, snapshot = gsync.snapshot)
        nothing
    catch e
        e
    end
    @test err_go isa ArgumentError
    @test occursin("snapshot= cannot be combined with sync=:sync", err_go.msg)
    dsync = DistSSHRun.parse_drive_args(
        String["--sync", "--snapshot", _SNAP_ID_OLD, "parent:1", "job.jl"],
    )
    @test dsync.snapshot == _SNAP_ID_OLD
    err_drive = try
        DistSSHRun.drive!(
            "job.jl", ["parent:1"]; sync = :sync, snapshot = dsync.snapshot, yes = true,
        )
        nothing
    catch e
        e
    end
    @test err_drive isa ArgumentError
    @test occursin("snapshot= cannot be combined with sync=:sync", err_drive.msg)
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

@testset "forget_last_snapshot_default treats trailing slash as same root" begin
    _with_tempdir() do proj
        _snap_project!(proj)
        DistSSHRun.write_last_snapshot_record!(
            proj, "/deploy/a/", ["h1"], _SNAP_ID_OLD,
        )
        rec = something(DistSSHRun.read_last_snapshot_record(proj))
        @test rec["deploy_root"] == "/deploy/a"
        DistSSHRun.forget_last_snapshot_default!(proj, "/deploy/a")
        @test DistSSHRun.read_last_snapshot_record(proj) === nothing
        DistSSHRun.write_last_snapshot_record!(
            proj, "/deploy/a", ["h1"], _SNAP_ID_OLD,
        )
        DistSSHRun.forget_last_snapshot_default!(proj, "/deploy/a/")
        @test DistSSHRun.read_last_snapshot_record(proj) === nothing
    end
end

@testset "record for another deploy root does not block git" begin
    double = abspath(
        joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"),
    )
    _with_tempdir() do state
        remote_a = joinpath(state, "remote_a")
        remote_b = joinpath(state, "remote_b")
        mkpath(remote_b)
        write(joinpath(remote_b, "Project.toml"), "name = \"GitB\"\n")
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.write_last_snapshot_record!(
                proj, remote_a, ["child-1"], _SNAP_ID_OLD,
            )
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
                        ["child-1"], remote_b, proj,
                    )
                    @test sel.source_kind === :git
                    @test sel.work_root == remote_b
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            end
        end
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
        for (leaf, hash) in ((old_leaf, _SNAP_HASH_OLD), (new_leaf, _SNAP_HASH_NEW))
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
                    @test sel.content_tree_hash == _SNAP_HASH_OLD

                    # Host order does not change the selected id.
                    sel2 = DistSSHRun.resolve_snapshot_selection(
                        ["child-2", "child-1"], remote, proj;
                        snapshot = _SNAP_ID_OLD,
                    )
                    @test sel2.snapshot_id == _SNAP_ID_OLD

                    # Local record default.
                    DistSSHRun.write_last_snapshot_record!(
                        proj, remote, ["child-1", "child-2"], _SNAP_ID_OLD;
                        content_tree_hash = _SNAP_HASH_OLD,
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

function _snap_ssh_env(double::AbstractString)
    return Dict{String, String}(
        "DISTSSHKIT_TEST" => "1",
        "DISTSSHKIT_TEST_SSH" => double,
        "DISTSSHKIT_TEST_POSIX_SHELL" => "1",
        "DISTSSHKIT_TEST_REMOTE_HOME" => "/home/distsshkit",
    )
end

function _write_complete_leaf!(root, id, hash)
    leaf = joinpath(root, "runs", String(id))
    mkpath(joinpath(leaf, "src"))
    write(joinpath(leaf, "src", "Project.toml"), "name = \"SnapSel\"\n")
    write(joinpath(leaf, "run.toml"), DistSSHRun._ship_run_leaf_complete_toml(hash))
    return leaf
end

@testset "complete=true without required stamp fields is not selectable" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        leaf = joinpath(remote, "runs", _SNAP_ID_OLD)
        mkpath(joinpath(leaf, "src"))
        write(joinpath(leaf, "src", "Project.toml"), "name = \"SnapSel\"\n")
        write(
            joinpath(leaf, "run.toml"),
            DistSSHRun._ship_run_leaf_stamp_toml() * "complete = true\n",
        )
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.clear_last_snapshot_record!(proj)
            DistSSHRun._clear_last_ship!()
            try
                withenv(_snap_ssh_env(double)...) do
                    err = try
                        DistSSHRun.resolve_snapshot_selection(
                            ["child-1"], remote, proj; snapshot = _SNAP_ID_OLD,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("stamp", sprint(showerror, err))
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            end
        end
    end
end

@testset "heterogeneous hosts: missing hash and hash mismatch fail closed" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    logical = "/__dsr_logical__"
    _with_tempdir() do state
        roots = joinpath(state, "hosts")
        h1 = joinpath(roots, "child-1")
        h2 = joinpath(roots, "child-2")
        _write_complete_leaf!(h1, _SNAP_ID_OLD, _SNAP_HASH_OLD)
        _write_complete_leaf!(h2, _SNAP_ID_OLD, _SNAP_HASH_NEW)
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.clear_last_snapshot_record!(proj)
            DistSSHRun._clear_last_ship!()
            env = merge(
                _snap_ssh_env(double),
                Dict(
                    "DISTSSHKIT_TEST_SSH_LOGICAL_ROOT" => logical,
                    "DISTSSHKIT_TEST_SSH_HOST_ROOTS" => roots,
                ),
            )
            try
                withenv(env...) do
                    err = try
                        DistSSHRun.resolve_snapshot_selection(
                            ["child-1", "child-2"], logical, proj;
                            snapshot = _SNAP_ID_OLD,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("content_tree_hash", sprint(showerror, err))
                    leaf2 = joinpath(h2, "runs", _SNAP_ID_OLD)
                    write(
                        joinpath(leaf2, "run.toml"),
                        DistSSHRun._ship_run_leaf_stamp_toml() * "complete = true\n",
                    )
                    err2 = try
                        DistSSHRun.resolve_snapshot_selection(
                            ["child-1", "child-2"], logical, proj;
                            snapshot = _SNAP_ID_OLD,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err2 isa ArgumentError
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            end
        end
    end
end

@testset "local-record missing content hash fails closed" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        _write_complete_leaf!(remote, _SNAP_ID_OLD, _SNAP_HASH_OLD)
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.write_last_snapshot_record!(
                proj, remote, ["child-1"], _SNAP_ID_OLD,
            )
            DistSSHRun._clear_last_ship!()
            try
                withenv(_snap_ssh_env(double)...) do
                    err = try
                        DistSSHRun.resolve_snapshot_selection(
                            ["child-1"], remote, proj,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("no content_tree_hash", sprint(showerror, err))
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_last_ship!()
            end
        end
    end
end

@testset "local-record content hash mismatch fails closed" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        _write_complete_leaf!(remote, _SNAP_ID_OLD, _SNAP_HASH_OLD)
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.write_last_snapshot_record!(
                proj, remote, ["child-1"], _SNAP_ID_OLD;
                content_tree_hash = _SNAP_HASH_NEW,
            )
            DistSSHRun._clear_last_ship!()
            try
                withenv(_snap_ssh_env(double)...) do
                    err = try
                        DistSSHRun.resolve_snapshot_selection(
                            ["child-1"], remote, proj,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("last-snapshot record content_tree_hash", sprint(showerror, err))
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_last_ship!()
            end
        end
    end
end

@testset "ENV work root is not treated as deploy root for instantiate" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        _write_complete_leaf!(remote, _SNAP_ID_OLD, _SNAP_HASH_OLD)
        work = joinpath(remote, "runs", _SNAP_ID_OLD, "src")
        nested = joinpath(work, "runs", _SNAP_ID_OLD, "src")
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.clear_last_snapshot_record!(proj)
            DistSSHRun._clear_last_ship!()
            try
                withenv(_snap_ssh_env(double)...) do
                    wr1 = DistSSHRun._project_work_root(
                        ["child-1"], proj;
                        cli_override = remote, snapshot = _SNAP_ID_OLD,
                    )
                    @test wr1 == work
                    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => wr1) do
                        wr2 = DistSSHRun._project_work_root(
                            ["child-1"], proj;
                            cli_override = nothing, snapshot = _SNAP_ID_OLD,
                        )
                        @test wr2 == work
                        @test wr2 != nested
                    end
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_last_ship!()
            end
        end
    end
end

@testset "old execution collect recovery does not follow last-snapshot B" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        _write_complete_leaf!(remote, _SNAP_ID_OLD, _SNAP_HASH_OLD)
        _write_complete_leaf!(remote, _SNAP_ID_NEW, _SNAP_HASH_NEW)
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.write_last_snapshot_record!(
                proj, remote, ["child-1"], _SNAP_ID_NEW;
                content_tree_hash = _SNAP_HASH_NEW,
            )
            DistSSHRun._clear_last_ship!()
            run_dir = joinpath(state, "runA")
            mkpath(run_dir)
            DistSSHRun.write_kit_run_toml!(
                run_dir;
                kind = :drive,
                project_root = proj,
                provenance = Dict{String, Any}(
                    "schema" => 1,
                    "writer" => "DistSSHRun test",
                    "shipped" => Dict{String, Any}(
                        "source_kind" => "snapshot",
                        "run_id" => _SNAP_ID_OLD,
                        "deploy_root" => remote,
                        "work_root" => joinpath(remote, "runs", _SNAP_ID_OLD, "src"),
                        "content_tree_hash" => _SNAP_HASH_OLD,
                        "algorithm" => "git-sha1",
                    ),
                ),
            )
            out = joinpath(proj, "out")
            mkpath(out)
            try
                withenv(
                    _snap_ssh_env(double)...,
                    DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => run_dir,
                ) do
                    got = DistSSHRun._remote_work_layout_path(
                        out, proj, ["child-1"],
                    )
                    @test got == joinpath(remote, "runs", _SNAP_ID_OLD, "src", "out")
                    @test !occursin(_SNAP_ID_NEW, got)
                end
                legacy = joinpath(state, "runLegacy")
                mkpath(legacy)
                DistSSHRun.write_kit_run_toml!(legacy; kind = :drive, project_root = proj)
                withenv(
                    _snap_ssh_env(double)...,
                    DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => legacy,
                ) do
                    err = try
                        DistSSHRun._remote_work_layout_path(out, proj, ["child-1"])
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("legacy", sprint(showerror, err))
                end
                mismatch = joinpath(state, "runMismatch")
                mkpath(mismatch)
                DistSSHRun.write_kit_run_toml!(
                    mismatch;
                    kind = :drive,
                    project_root = proj,
                    provenance = Dict{String, Any}(
                        "schema" => 1,
                        "writer" => "DistSSHRun test",
                        "shipped" => Dict{String, Any}(
                            "source_kind" => "snapshot",
                            "run_id" => _SNAP_ID_OLD,
                            "deploy_root" => remote,
                            "work_root" => joinpath(remote, "runs", _SNAP_ID_OLD, "src"),
                            "content_tree_hash" => _SNAP_HASH_NEW,
                            "algorithm" => "git-sha1",
                        ),
                    ),
                )
                withenv(
                    _snap_ssh_env(double)...,
                    DistSSHRun.DISTSSHKIT_RUN_DIR_ENV => mismatch,
                ) do
                    errh = try
                        DistSSHRun._remote_work_layout_path(out, proj, ["child-1"])
                        nothing
                    catch e
                        e
                    end
                    @test errh isa ArgumentError
                    @test occursin("content_tree_hash", sprint(showerror, errh))
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_last_ship!()
            end
        end
    end
end

@testset "skip_local_record ignores _LAST_SHIP" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        _write_complete_leaf!(remote, _SNAP_ID_OLD, _SNAP_HASH_OLD)
        _write_complete_leaf!(remote, _SNAP_ID_NEW, _SNAP_HASH_NEW)
        previous = DistSSHRun._LAST_SHIP[]
        DistSSHRun._LAST_SHIP[] = Dict{String, Any}(
            "src" => joinpath(remote, "runs", _SNAP_ID_NEW, "src"),
            "run_id" => _SNAP_ID_NEW,
            "hosts" => String["child-1"],
            "remote_root" => remote,
        )
        DistSSHRun._SHIP_LAYOUT_ACTIVE[] = true
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.clear_last_snapshot_record!(proj)
            write(joinpath(remote, "Project.toml"), "name = \"GitRoot\"\n")
            try
                withenv(_snap_ssh_env(double)...) do
                    used_last = DistSSHRun.resolve_snapshot_selection(
                        ["child-1"], remote, proj,
                    )
                    @test used_last.snapshot_id == _SNAP_ID_NEW
                    sel2 = DistSSHRun.resolve_snapshot_selection(
                        ["child-1"], remote, proj; skip_local_record = true,
                    )
                    @test sel2.source_kind === :git
                    @test sel2.snapshot_id === nothing
                end
            finally
                DistSSHRun._LAST_SHIP[] = previous
                DistSSHRun._SHIP_LAYOUT_ACTIVE[] = false
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
            end
        end
    end
end

@testset "setup --check does not claim success on incomplete snapshot" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        roots = joinpath(state, "hosts")
        h1 = joinpath(roots, "child-1")
        mkpath(h1)
        write(joinpath(h1, "Project.toml"), "name = \"GitRoot\"\n")
        leaf = joinpath(h1, "runs", _SNAP_ID_OLD)
        mkpath(joinpath(leaf, "src"))
        write(joinpath(leaf, "src", "Project.toml"), "name = \"SnapSel\"\n")
        write(
            joinpath(leaf, "run.toml"),
            DistSSHRun._ship_run_leaf_stamp_toml() * "complete = true\n",
        )
        _with_tempdir() do proj
            _snap_project!(proj)
            DistSSHRun.clear_last_snapshot_record!(proj)
            DistSSHRun._clear_last_ship!()
            env = merge(
                _snap_ssh_env(double),
                Dict(
                    "DISTSSHKIT_TEST_SSH_LOGICAL_ROOT" => "/__dsr_logical__",
                    "DISTSSHKIT_TEST_SSH_HOST_ROOTS" => roots,
                    "DISTSSHKIT_CLI_SUBCOMMAND_DONE" => "",
                    "DISTSSHKIT_YES" => nothing,
                ),
            )
            try
                withenv(env...) do
                    mktemp() do out_path, out_io
                        mktemp() do err_path, err_io
                            code = redirect_stdin(devnull) do
                                redirect_stdout(out_io) do
                                    redirect_stderr(err_io) do
                                        DistSSHRun.setup(
                                            [
                                                "check",
                                                "--snapshot", _SNAP_ID_OLD,
                                                "--deploy-root", "/__dsr_logical__",
                                                "child:child-1",
                                            ],
                                        )
                                    end
                                end
                            end
                            flush(out_io)
                            flush(err_io)
                            shown = read(out_path, String) * read(err_path, String)
                            @test code == 1
                            @test !occursin("All prerequisites met", shown)
                        end
                    end
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_last_ship!()
            end
        end
    end
end

@testset "snapshot selection uses project_rel under src" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        leaf = joinpath(remote, "runs", _SNAP_ID_OLD)
        mkpath(joinpath(leaf, "src", "app"))
        write(joinpath(leaf, "src", "app", "Project.toml"), "name = \"Nested\"\n")
        write(
            joinpath(leaf, "run.toml"),
            DistSSHRun._ship_run_leaf_complete_toml(_SNAP_HASH_OLD; project_rel = "app"),
        )
        _with_tempdir() do proj
            _snap_project!(proj)
            withenv(
                "DISTSSHKIT_TEST" => "1",
                "DISTSSHKIT_TEST_SSH" => double,
                "DISTSSHKIT_TEST_POSIX_SHELL" => "1",
                "DISTSSHKIT_TEST_REMOTE_HOME" => "/home/distsshkit",
            ) do
                DistSSHRun.clear_last_snapshot_record!(proj)
                sel = DistSSHRun.resolve_snapshot_selection(
                    ["child-1"], remote, proj; snapshot = _SNAP_ID_OLD,
                )
                @test endswith(sel.work_root, "/runs/$_SNAP_ID_OLD/src/app")
                DistSSHRun.write_last_snapshot_record!(
                    proj, remote, ["child-1"], _SNAP_ID_OLD;
                    content_tree_hash = _SNAP_HASH_OLD, project_rel = "app",
                )
                sel2 = DistSSHRun.resolve_snapshot_selection(["child-1"], remote, proj)
                @test sel2.work_root == sel.work_root
            end
        end
    end
end
