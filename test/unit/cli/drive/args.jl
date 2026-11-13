using Test

@testset "drive args" begin
    parse_drive_args = DistSSHRun.parse_drive_args
    drive_help_text = DistSSHRun.drive_help_text

    @testset "collect modes" begin
        @test_throws ArgumentError parse_drive_args(["--collect", "h"])
        @test_throws ArgumentError parse_drive_args(["--collect-sync", "data/sweep", "host"])
        @test_throws ArgumentError parse_drive_args(["--collect-missing", "data/sweep"])

        let r = parse_drive_args(["--collect-missing", "data/sweep", "host-a", "host-b"])
            @test r.collect_root == abspath("data/sweep")
            @test r.collect_hosts == ["host-a", "host-b"]
            @test r.collect_overwrite == false
            @test r.script_path === nothing
        end
        let r = parse_drive_args(["--collect-overwrite", "data/sweep", "host-a"])
            @test r.collect_overwrite == true
            @test r.collect_hosts == ["host-a"]
        end
        DistSSHRun.set_kit_verbosity!(:progress)
        parse_drive_args(["-q", "--collect-missing", "data/sweep", "host-a"])
        @test DistSSHRun.kit_verbosity() === :quiet
        DistSSHRun.set_kit_verbosity!(:progress)
    end

    @testset "parse hosts and flags" begin
        @test DistSSHRun.split_worker_token("host-a") == ("host-a", nothing)
        @test DistSSHRun.split_worker_token("host-a:10") == ("host-a", 10)

        withenv("JULIA_DISTRIBUTED_EXE" => nothing) do
            let r = parse_drive_args(["--help"])
                @test r.help == true
            end
            let r = parse_drive_args(["-h"])
                @test r.help == true
            end
            let r = parse_drive_args(["s.jl"])
                @test r.hint_surface === :cli
                @test r.worker_include == false
                @test r.isolated == false
            end
            let r = parse_drive_args(["--isolated", "s.jl", "--", "1"])
                @test r.isolated
                @test r.script_path == "s.jl"
            end
            @test_throws ArgumentError parse_drive_args(["--isolated", "--isolated", "s.jl"])
            cmd = DistSSHRun._drive_isolated_cmd(["--isolated", "s.jl", "1"])
            text = join(cmd.exec, " ")
            @test occursin("DistSSHRun.run_drive_parsed!", text)
            @test !occursin("--isolated", text)
            kept = DistSSHRun._drive_isolated_cmd(["--isolated", "s.jl", "--isolated"])
            dash = findfirst(==("--"), kept.exec)
            @test dash isa Int
            dash isa Int || error("expected --")
            @test kept.exec[(dash + 1):end] == ["s.jl", "--isolated"]
            valued = DistSSHRun._drive_isolated_child_args(
                ["--output-dir", "--isolated", "--isolated", "s.jl"],
            )
            @test valued == ["--output-dir", "--isolated", "s.jl"]
            quieted = [
                "--output-dir", "--quiet", "result.jl", "--isolated", "driver.jl",
            ]
            @test DistSSHRun.parse_drive_args(quieted).script_path == "driver.jl"
            @test DistSSHRun.parse_drive_args(quieted).isolated
            child_args = DistSSHRun._drive_isolated_child_args(quieted)
            @test child_args == ["--output-dir", "--quiet", "result.jl", "driver.jl"]
            @test !DistSSHRun.parse_drive_args(child_args).isolated
            rooted = DistSSHRun._drive_isolated_cmd(
                ["--isolated", "s.jl"]; project_root = "/jobs/app",
            )
            env = something(rooted.env, String[])
            @test any(e -> startswith(e, "JULIA_LOAD_PATH="), env)
            @test "DISTRIBUTED_PROJECT_ROOT=/jobs/app" in env
            ap = Base.active_project()
            if ap !== nothing
                @test "--project=$(dirname(String(ap)))" in rooted.exec
            end
            @test DistSSHRun._drive_child_status(0, 9) == 137
            @test DistSSHRun._drive_child_status(2, 0) == 2
            @test DistSSHRun._drive_child_status(nothing, nothing) == 1
            @test DistSSHRun._drive_child_status(0xC0000005, 0) == 1
            sleeper = run(
                ignorestatus(`$(Base.julia_cmd()) --startup-file=no -e "sleep(30)"`);
                wait = false,
            )
            try
                DistSSHRun._forward_isolated_interrupt!(sleeper)
                @test process_exited(sleeper)
                @test DistSSHRun._drive_child_status(sleeper.exitcode, sleeper.termsignal) != 0
            finally
                process_running(sleeper) && kill(sleeper, Base.SIGKILL)
                try
                    wait(sleeper)
                catch
                end
            end
            let err_ss = try
                    parse_drive_args(["--sync-script", "s.jl"])
                    error("expected ArgumentError")
                catch e
                    e
                end
                @test err_ss isa ArgumentError
                @test occursin("drive --sync-script was removed", err_ss.msg)
                @test occursin("--worker-include", err_ss.msg)
            end
            @test_throws ArgumentError parse_drive_args(
                ["--sync-script", "--sync-script", "s.jl"],
            )
            let r = parse_drive_args(["--worker-include", "s.jl"])
                @test r.worker_include == true
            end
            @test_throws ArgumentError parse_drive_args(["--worker-include", "--worker-include", "s.jl"])
            let r = parse_drive_args(["parent:4", "myscript.jl", "a", "b"])
                @test r.parent_workers == 4
                @test r.script_path == "myscript.jl"
                @test r.script_args == ["a", "b"]
            end
            @test_throws ArgumentError parse_drive_args(["--parent", "4", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--parent:5", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--masterhost", "4", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--master-gb", "0.2", "s.jl"])
            let r = parse_drive_args(["parent:3", "child:host1:2", "s.jl"])
                @test r.parent_workers == 3
                @test r.hosts == [("host1", 2)]
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["parent:3", "child:host1:2"]
            end
            let r = parse_drive_args(["parent:4", "child:host1:1", "child:host2:2", "s.jl"])
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["parent:4", "child:host1:1", "child:host2:2"]
            end
            @test_throws ArgumentError parse_drive_args(["--local", "4", "myscript.jl", "a", "b"])
            @test_throws ArgumentError parse_drive_args(["--local:5", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["-l:2", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["-l", "3", "s.jl"])
            let r = parse_drive_args(["--workers:7", "child:host1:1", "s.jl"])
                @test r.default_workers == 7
                @test r.parent_workers == 7
                @test r.hosts == [("host1", 1)]
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["parent:7", "child:host1:1"]
            end
            let r = parse_drive_args(["-w:4", "child:host1:1", "s.jl"])
                @test r.default_workers == 4
                @test r.parent_workers == 4
            end
            let r = parse_drive_args(["child:local:3", "child:host1:2", "s.jl"])
                @test r.parent_workers == 0
                @test r.hosts == [("local", 3), ("host1", 2)]
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["child:local:3", "child:host1:2"]
            end
            let r = parse_drive_args(["child:localhost:4", "s.jl"])
                @test r.parent_workers == 0
                @test r.hosts == [("localhost", 4)]
            end
            @test_throws ArgumentError parse_drive_args(["--local", "2", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--local:"])
            @test_throws ArgumentError parse_drive_args(["--workers", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--workers", "x", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--nope", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--julia"])
            @test_throws ArgumentError parse_drive_args(["--require-git", "--require-git", "s.jl"])

            let r = parse_drive_args(["--workers", "3", "child:host1:1", "child:host2:5", "s.jl"])
                @test r.default_workers == 3
                @test r.parent_workers == 3
                @test r.hosts == [("host1", 1), ("host2", 5)]
            end
            let r = parse_drive_args(["--julia", "/usr/bin/julia", "s.jl"])
                @test r.julia == "/usr/bin/julia"
            end
            let r = parse_drive_args(["--julia", "auto", "s.jl"])
                @test r.julia === nothing
            end
            let r = parse_drive_args(["--allow-mismatch", "manifest", "s.jl"])
                @test r.allow_mismatch == [:manifest]
            end
            let r = parse_drive_args(["--no-log", "s.jl"])
                @test r.enable_log == false
            end
            let r = parse_drive_args(["--log-dir", "/tmp/logs", "--output-dir", "/tmp/out", "s.jl"])
                @test r.log_dir == "/tmp/logs"
                @test r.output_dir == "/tmp/out"
            end
            let r = parse_drive_args(["--package", "MyPkg", "s.jl"])
                @test r.explicit_package == "MyPkg"
            end
            let r = parse_drive_args(["--package", "  ", "s.jl"])
                @test r.explicit_package === nothing
            end
            let r = parse_drive_args(["--version"])
                @test r.show_version == true
            end
            hosts_file = _sample_hosts_file()
            let r = parse_drive_args(["--hosts-file", hosts_file, "child:host-cli:2", "s.jl"])
                @test r.hosts == [("host-cli", 2), ("host-a", 1), ("host-b", 4)]
            end
            @test_throws ArgumentError parse_drive_args(
                ["--hosts", "child:h-csv:2,child:h-csv-b", "s.jl"],
            )
            let r = parse_drive_args(["--hosts", "child:h-csv:2,child:h-csv-b:1", "s.jl"])
                @test r.hosts == [("h-csv", 2), ("h-csv-b", 1)]
            end
            let r = parse_drive_args(["-q", "-y", "s.jl"])
                @test r.cli_session.quiet == true
                @test r.cli_session.yes == true
                DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags())
            end
            withenv("DISTSSH_HOSTS" => "child:env-host:3, child:env-b:1") do
                let r = parse_drive_args(["parent:2", "s.jl"])
                    @test r.parent_workers == 2
                    @test ("env-host", 3) in r.hosts
                    @test ("env-b", 1) in r.hosts
                end
            end
            let r = parse_drive_args(String[])
                @test r.script_path === nothing
            end
        end
        withenv("JULIA_DISTRIBUTED_EXE" => "/opt/custom/julia") do
            let r = parse_drive_args(["s.jl"])
                @test r.julia == "/opt/custom/julia"
            end
        end
    end

    @testset "transfer flags and git parity" begin
        let r = parse_drive_args(["s.jl"])
            @test r.skip_hash_check == true
        end
        for flag in ("--sync", "--git-sync", "--ship-tree", "--skip-git-guard")
            err = try
                parse_drive_args([flag, "child:host1:1", "s.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("was removed", err.msg)
        end
        @test_throws ArgumentError parse_drive_args(["--mem-headroom", "0.5", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["--parent-gb", "0.2", "s.jl"])
        err_ext = try
            parse_drive_args(["--allow-external-symlinks", "s.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_ext isa ArgumentError
        @test occursin("drive: --allow-external-symlinks was removed", err_ext.msg)
        let r = parse_drive_args(["--require-git", "child:host1:1", "s.jl"])
            @test r.skip_hash_check == false
        end
        err = try
            parse_drive_args(["--require-git", "--rsync", "s.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test err.msg == DistSSHRun.RSYNC_REMOVED_MSG
        @test_throws ArgumentError parse_drive_args(["child:host1", "--collect-missing", "out", "child:h1"])
        # Shared flags are peeled even after `--collect-missing` (not treated as HOST).
        let r = parse_drive_args(["--collect-missing", "out", "--quiet", "h1"])
            @test r.collect_hosts == ["h1"]
            @test r.cli_session.quiet
            DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags())
        end
        @test_throws ArgumentError parse_drive_args(["--collect-missing", "out", "--foo", "child:h1"])
        @test_throws ArgumentError parse_drive_args(["--collect-overwrite"])
    end

    @testset "help smoke" begin
        txt = drive_help_text()
        @test occursin("Usage", txt)
        @test occursin("--collect-missing", txt)
        @test occursin("--quiet", txt)
        @test occursin("--hosts", txt)
        @test occursin("--require-git", txt)
        @test !occursin("--git-sync", txt)
        @test occursin("--worker-include", txt)
        @test !occursin("--sync-script", txt)
        @test !occursin("--ship-tree", txt)
        @test occursin("setup ship-tree", txt)
        @test occursin("--run-id", txt)
        @test occursin("runs/<ID>/src", txt)
        @test occursin("post-run-new", txt)
        @test occursin("Pull-back uses Tar", txt)
        @test occursin("off by default", lowercase(txt))
        @test occursin("parent:N", txt)
        @test occursin("progress DIR", txt)
        @test occursin("--allow-mismatch", txt)
        @test !occursin(r"--parent(?!-gb)", txt)
        @test !occursin("--local", txt)
        @test !occursin("--mem-headroom", txt)
        @test !occursin("--parent-gb", txt)
        @test occursin("DISTSSH_JOBS", txt)
        @test occursin("DISTSSH_REQUIRE_ALL_HOSTS", txt)
        @test occursin("DISTSSH_BEST_EFFORT", txt)
        @test occursin("--best-effort", txt)
        @test !occursin("required after `setup --rsync`", txt)
        @test occursin("--deploy-root", txt)
        @test occursin("Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT", txt)
    end

    @testset "deploy-root" begin
        let r = parse_drive_args(["--deploy-root", "/tmp/my dir", "parent:1", "s.jl"])
            @test r.deploy_root == "/tmp/my dir"
            @test r.script_path == "s.jl"
        end
        let r = parse_drive_args(["--deploy-root", "/tmp/App", "--", "parent:1", "s.jl", "1"])
            @test r.deploy_root == "/tmp/App"
            @test r.script_args == ["1"]
        end
        let r = parse_drive_args(["parent:1", "s.jl", "--deploy-root", "/tmp/x"])
            @test r.deploy_root === nothing
            @test r.script_args == ["--deploy-root", "/tmp/x"]
        end
        let r = parse_drive_args(["--", "parent:1", "s.jl", "--ship-tree"])
            @test r.script_args == ["--ship-tree"]
        end
        let r = parse_drive_args(["parent:1", "s.jl", "--ship-tree"])
            @test r.script_args == ["--ship-tree"]
        end
        err_after = try
            parse_drive_args(["--", "--ship-tree", "parent:1", "s.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_after isa ArgumentError
        @test occursin("unknown or incomplete drive option: --ship-tree", err_after.msg)
        @test !occursin("was removed", err_after.msg)
        @test_throws ArgumentError parse_drive_args(["--remote-path", "/tmp/App", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["--remote-path=/tmp/App", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["--deploy-root"])
    end

    @testset "require-all-hosts" begin
        withenv(
            "DISTSSH_REQUIRE_ALL_HOSTS" => nothing,
            "DISTSSH_BEST_EFFORT" => nothing,
        ) do
            @test parse_drive_args(["s.jl"]).require_all_hosts
            @test parse_drive_args(["--require-all-hosts", "s.jl"]).require_all_hosts
            @test !parse_drive_args(["--best-effort", "s.jl"]).require_all_hosts
            @test_throws ArgumentError parse_drive_args(
                ["--require-all-hosts", "--require-all-hosts", "s.jl"],
            )
            @test_throws ArgumentError parse_drive_args(
                ["--best-effort", "--best-effort", "s.jl"],
            )
            @test_throws ArgumentError parse_drive_args(
                ["--require-all-hosts", "--best-effort", "s.jl"],
            )
            let r = parse_drive_args(["--require-all-hosts", "--collect-missing", "out", "h1"])
                @test r.require_all_hosts
            end
        end
        withenv(
            "DISTSSH_REQUIRE_ALL_HOSTS" => "1",
            "DISTSSH_BEST_EFFORT" => nothing,
        ) do
            @test parse_drive_args(["s.jl"]).require_all_hosts
        end
        withenv(
            "DISTSSH_REQUIRE_ALL_HOSTS" => nothing,
            "DISTSSH_BEST_EFFORT" => "1",
        ) do
            @test !parse_drive_args(["s.jl"]).require_all_hosts
            @test parse_drive_args(["--require-all-hosts", "s.jl"]).require_all_hosts
        end
        withenv(
            "DISTSSH_REQUIRE_ALL_HOSTS" => "1",
            "DISTSSH_BEST_EFFORT" => "1",
        ) do
            @test_throws ArgumentError parse_drive_args(["s.jl"])
        end
    end
end
