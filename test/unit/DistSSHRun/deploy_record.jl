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

@testset "deploy record scp upload argv is local then remote" begin
    local_tmp = "/tmp/deploy-record-body.toml"
    remote_abs = "/home/user/proj/.distssh/deploy.toml.tmp"
    argv = DistSSHRun._deploy_record_scp_upload_argv("child-1", remote_abs, local_tmp)
    @test argv[1:(end - 2)] == DistSSHRun.ssh_opts()
    @test argv[end - 1] == local_tmp
    @test argv[end] == "child-1:$remote_abs"
    @test length(argv) == length(DistSSHRun.ssh_opts()) + 2
end

@testset "deploy record tmp path and atomic install script" begin
    abs = "/home/user/App/.distssh/deploy.toml"
    tmp = DistSSHRun._deploy_record_tmp_path(abs, "20260101T000000Z-aaaaaa")
    @test tmp != abs
    @test endswith(tmp, ".tmp")
    @test occursin("deploy.toml.", tmp)
    sh = DistSSHRun._deploy_record_atomic_install_script(abs, tmp)
    @test occursin("mv -f", sh)
    @test occursin("deploy.toml", sh)
end

@testset "deploy record tmp path unique for same deploy_id" begin
    abs = "/home/user/App/.distssh/deploy.toml"
    same_id = "a"^40
    p1 = DistSSHRun._deploy_record_tmp_path(abs, same_id)
    p2 = DistSSHRun._deploy_record_tmp_path(abs, same_id)
    @test p1 != p2
end

@testset "deploy record scp host vs path validation" begin
    remote = "/home/a@-b/project/.distssh/deploy.toml.x.tmp"
    argv = DistSSHRun._deploy_record_scp_upload_argv("child-1", remote, "/tmp/body.toml")
    @test argv[end] == "child-1:$remote"
end

@testset "deploy record staleness warns on ship-tree hash mismatch" begin
    _with_tempdir() do log_root
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"WarnDep\"\n")
            write(joinpath(proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
            snap = DistSSHRun.snapshot(proj)
            rm(DistSSHRun.snapshot_directory(snap); recursive = true, force = true)
            rec = Dict(
                "schema" => 1,
                "mode" => "ship-tree",
                "deploy_id" => "rid",
                "content_tree_hash" => "f"^40,
            )
            write(joinpath(proj, "extra.txt"), "change\n")
            log_path = DistSSHRun.init_log_file(log_root; prefix = "deploy_warn")
            try
                DistSSHRun._warn_deploy_staleness!(proj, rec)
            finally
                DistSSHRun.close_log_file()
            end
            body = read(log_path, String)
            @test occursin("ship-tree hash", body)
        end
    end
end

@testset "deploy record write failure warns per host" begin
    _with_tempdir() do log_root
        _with_tempdir() do state_dir
            withenv(merge(_fake_setup_remote_env(state_dir), Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))...) do
                log_path = DistSSHRun.init_log_file(log_root; prefix = "deploy_write")
                try
                    DistSSHRun.write_deploy_record_to_hosts!(
                        ["host1"],
                        "/remote/proj",
                        pwd(),
                        :git_sync;
                        deploy_id = "a"^40,
                        commit_sha = "a"^40,
                    )
                finally
                    DistSSHRun.close_log_file()
                end
                body = read(log_path, String)
                @test occursin("Deploy record write failed on host1", body)
                @test occursin("Deploy record was not written on any host", body)
            end
        end
    end
end

@testset "deploy record read on host (injected file)" begin
    double = abspath(joinpath(@__DIR__, "..", "..", "fixtures", "fake_snapshot_ssh.jl"))
    _with_tempdir() do state
        remote = joinpath(state, "remote")
        body = sprint(
            TOML.print, Dict(
                "schema" => 1,
                "deploy_id" => "a"^40,
                "mode" => "git-sync",
                "commit_sha" => "a"^40,
            )
        )
        deploy_dir = joinpath(remote, ".distssh")
        mkpath(deploy_dir)
        write(joinpath(deploy_dir, "deploy.toml"), body)
        _with_tempdir() do proj
            write(joinpath(proj, "Project.toml"), "name = \"ReadDep\"\n")
            try
                withenv(
                    "DISTSSHKIT_TEST" => "1",
                    "DISTSSHKIT_TEST_SSH" => double,
                    "DISTSSHKIT_TEST_REMOTE_HOME" => "/home/distsshkit",
                ) do
                    rec = DistSSHRun.read_deploy_record_on_host("child-1", remote)
                    @test rec !== nothing
                    @test rec["mode"] == "git-sync"
                    @test rec["deploy_id"] == "a"^40
                    active = DistSSHRun.record_deploy_status_for_run!(
                        ["child-1"], remote, proj,
                    )
                    @test active !== nothing
                    if active !== nothing
                        @test active["mode"] == "git-sync"
                        stored = DistSSHRun.active_deploy_record()
                        @test stored !== nothing
                        if stored !== nothing
                            @test stored["mode"] == active["mode"]
                        end
                    end
                end
            finally
                DistSSHRun.DistSSHBase._clear_remote_posix_shell_cache!()
                DistSSHRun._clear_active_deploy_record!()
            end
        end
    end
end
