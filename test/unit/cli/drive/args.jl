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

    @testset "rejected mistaken short flags" begin
        @test_throws ArgumentError parse_drive_args(["-p", "--head-workers", "1", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["-p4", "--head-workers", "1", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["-l", "--head-workers", "1", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["-L", "--head-workers", "1", "s.jl"])
        @test_throws ArgumentError parse_drive_args(["-L8080", "--head-workers", "1", "s.jl"])
        let err = try
                parse_drive_args(["-p", "auto", "--head-workers", "1", "s.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("unknown option -p", err.msg)
            @test occursin("--head-workers", err.msg)
            @test occursin("host:port", err.msg)
        end
        let err = try
                parse_drive_args(["-l", "user", "--head-workers", "1", "s.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("user@host", err.msg)
        end
        let err = try
                parse_drive_args(["-L", "8080:localhost:22", "--head-workers", "1", "s.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Port forwarding", err.msg)
        end
    end

    @testset "parse hosts and flags" begin
        @test DistSSHRun.split_worker_token("host-a") == ("host-a", nothing)
        @test DistSSHRun.split_worker_token("10*host-a") == ("host-a", 10)
        @test DistSSHRun.split_worker_token("host-a:22") == ("host-a:22", nothing)

        withenv("JULIA_DISTRIBUTED_EXE" => nothing) do
            let r = parse_drive_args(["--help"])
                @test r.help == true
            end
            let r = parse_drive_args(["-h"])
                @test r.help == true
            end
            let r = parse_drive_args(["--head-workers", "1", "s.jl"])
                @test r.hint_surface === :cli
                @test r.worker_include == false
                @test r.isolated == false
            end
            let r = parse_drive_args(["--isolated", "--head-workers", "1", "s.jl", "--", "1"])
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
                ["--output-dir", "--isolated", "--isolated", "s.jl"]
            )
            @test valued == ["--output-dir", "--isolated", "s.jl"]
            quieted = [
                "--output-dir", "--quiet", "result.jl", "--isolated", "--head-workers", "1",
                "driver.jl",
            ]
            @test DistSSHRun.parse_drive_args(quieted).script_path == "driver.jl"
            @test DistSSHRun.parse_drive_args(quieted).isolated
            child_args = DistSSHRun._drive_isolated_child_args(quieted)
            @test child_args == [
                "--output-dir", "--quiet", "result.jl", "--head-workers", "1", "driver.jl",
            ]
            @test !DistSSHRun.parse_drive_args(child_args).isolated
            uh_isolated = [
                "--unsafe-skip-env-digests", "--isolated", "--head-workers", "1", "job.jl",
            ]
            _, uh_peeled = DistSSHRun.peel_shared_cli_flags(uh_isolated)
            @test DistSSHRun._peeled_isolated_option(uh_peeled) !== nothing
            uh_child = DistSSHRun._drive_isolated_child_args(uh_isolated)
            @test uh_child == ["--unsafe-skip-env-digests", "--head-workers", "1", "job.jl"]
            @test !DistSSHRun.parse_drive_args(uh_child).isolated
            rooted = DistSSHRun._drive_isolated_cmd(
                ["--isolated", "--head-workers", "1", "s.jl"]; project_root = "/jobs/app"
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
            @test DistSSHRun._drive_child_status(0, -1) == 1
            @test DistSSHRun._drive_child_status(0, 0xFFFFFFFF) == 1
            @test DistSSHRun._drive_child_status(0, typemax(UInt64)) == 1
            @test DistSSHRun._drive_child_status(0, 128) == 1
            sleeper = run(
                ignorestatus(`$(Base.julia_cmd()) --startup-file=no -e "sleep(30)"`);
                wait = false
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
                ["--sync-script", "--sync-script", "s.jl"]
            )
            let r = parse_drive_args(["--worker-include", "--head-workers", "1", "s.jl"])
                @test r.worker_include == true
            end
            @test_throws ArgumentError parse_drive_args(["--worker-include", "--worker-include", "s.jl"])
            let r = parse_drive_args(["--head-workers", "4", "myscript.jl", "a", "b"])
                @test r.head_workers == 4
                @test r.script_path == "myscript.jl"
                @test r.script_args == ["a", "b"]
            end
            @test_throws ArgumentError parse_drive_args(["--parent", "4", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--parent:5", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--masterhost", "4", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--master-gb", "0.2", "s.jl"])
            let r = parse_drive_args(["--head-workers", "3", "2*host1", "s.jl"])
                @test r.head_workers == 3
                @test r.hosts == [("host1", 2)]
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["2*host1"]
            end
            let r = parse_drive_args(["--head-workers", "0", "1*host1", "s.jl"])
                @test r.head_workers == 0
                @test ("host1", 1) in r.hosts
            end
            @test_throws ArgumentError parse_drive_args(["--head-workers", "0", "s.jl"])
            let r = parse_drive_args(["--head-workers", "0", "1*host1", "s.jl"])
                @test r.head_workers == 0
                @test ("host1", 1) in r.hosts
            end
            @test_throws ArgumentError parse_drive_args(["--head-workers", "0", "s.jl"])
            let r = parse_drive_args(["--head-workers", "4", "1*host1", "2*host2", "s.jl"])
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["host1", "2*host2"]
            end
            @test_throws ArgumentError parse_drive_args(["--local", "4", "myscript.jl", "a", "b"])
            @test_throws ArgumentError parse_drive_args(["--local:5", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["-l:2", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["-l", "3", "s.jl"])
            let r = parse_drive_args(["--head-workers", "7", "1*host1", "s.jl"])
                @test r.head_workers == 7
                @test r.hosts == [("host1", 1)]
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["host1"]
            end
            @test_throws ArgumentError parse_drive_args(["-w:4", "1*host1", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--workers:7", "1*host1", "s.jl"])
            let r = parse_drive_args(["--head-workers", "3", "2*host1", "s.jl"])
                @test r.head_workers == 3
                @test r.hosts == [("host1", 2)]
                @test DistSSHRun.host_tokens(r; kind = :drive) == ["2*host1"]
            end
            let r = parse_drive_args(["4*localhost", "s.jl"])
                @test r.head_workers == 0
                @test r.hosts == [("localhost", 4)]
            end
            @test_throws ArgumentError parse_drive_args(["--local", "2", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--local:"])
            @test_throws ArgumentError parse_drive_args(["--workers", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--workers", "x", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--nope", "s.jl"])
            @test_throws ArgumentError parse_drive_args(["--julia"])
            @test_throws ArgumentError parse_drive_args(["--require-git", "--require-git", "s.jl"])

            let r = parse_drive_args(["--head-workers", "3", "1*host1", "5*host2", "s.jl"])
                @test r.head_workers == 3
                @test r.hosts == [("host1", 1), ("host2", 5)]
            end
            let r = parse_drive_args(["--julia", "/usr/bin/julia", "--head-workers", "1", "s.jl"])
                @test r.julia == "/usr/bin/julia"
            end
            let r = parse_drive_args(["--julia", "auto", "--head-workers", "1", "s.jl"])
                @test r.julia === nothing
            end
            let r = parse_drive_args(["--unsafe-skip-env-digests", "--head-workers", "1", "s.jl"])
                @test r.unsafe_skip_env_digests
            end
            err = try
                parse_drive_args(["--allow-mismatch", "--head-workers", "1", "s.jl"])
                nothing
            catch e
                e
            end
            err isa ArgumentError || error("expected ArgumentError")
            @test occursin("DSSH-E001", err.msg)
            @test occursin("--allow-mismatch was removed", err.msg)
            @test occursin("--unsafe-skip-env-digests", err.msg)
            let r = parse_drive_args(["--no-log", "--head-workers", "1", "s.jl"])
                @test r.enable_log == false
            end
            let r = parse_drive_args(["--log-dir", "/tmp/logs", "--output-dir", "/tmp/out", "--head-workers", "1", "s.jl"])
                @test r.log_dir == "/tmp/logs"
                @test r.output_dir == "/tmp/out"
            end
            let r = parse_drive_args(["--package", "MyPkg", "--head-workers", "1", "s.jl"])
                @test r.explicit_package == "MyPkg"
            end
            let r = parse_drive_args(["--package", "  ", "--head-workers", "1", "s.jl"])
                @test r.explicit_package === nothing
            end
            let r = parse_drive_args(["--version"])
                @test r.show_version == true
            end
            hosts_file = _sample_hosts_file()
            let r = parse_drive_args(["--hosts-file", hosts_file, "2*host-cli", "s.jl"])
                @test r.hosts == [("host-cli", 2), ("host-a", 1), ("host-b", 4)]
            end
            let r = parse_drive_args(["--hosts", "2*h-csv,h-csv-b", "s.jl"])
                @test r.hosts == [("h-csv", 2), ("h-csv-b", 1)]
            end
            let r = parse_drive_args(["--hosts", "2*h-csv,1*h-csv-b", "s.jl"])
                @test r.hosts == [("h-csv", 2), ("h-csv-b", 1)]
            end
            let r = parse_drive_args(["-q", "-y", "--head-workers", "1", "s.jl"])
                @test r.cli_session.quiet == true
                @test r.cli_session.yes == true
                DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags())
            end
            withenv("DISTSSH_HOSTS" => "3*env-host, 1*env-b") do
                let r = parse_drive_args(["--head-workers", "2", "s.jl"])
                    @test r.head_workers == 2
                    @test ("env-host", 3) in r.hosts
                    @test ("env-b", 1) in r.hosts
                end
            end
            let r = parse_drive_args(String[])
                @test r.script_path === nothing
            end
        end
        withenv("JULIA_DISTRIBUTED_EXE" => "/opt/custom/julia") do
            let r = parse_drive_args(["--head-workers", "1", "s.jl"])
                @test r.julia == "/opt/custom/julia"
            end
        end
    end

    @testset "transfer flags and git parity" begin
        let r = parse_drive_args(["--head-workers", "1", "s.jl"])
            @test r.skip_hash_check == true
        end
        for flag in ("--sync", "--git-sync", "--ship-tree", "--skip-git-guard")
            err = try
                parse_drive_args([flag, "1*host1", "s.jl"])
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
            parse_drive_args(["--allow-external-symlinks", "--head-workers", "1", "s.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_ext isa ArgumentError
        @test occursin("drive: --allow-external-symlinks was removed", err_ext.msg)
        let r = parse_drive_args(["--require-git", "1*host1", "s.jl"])
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
        @test_throws ArgumentError parse_drive_args(["host1", "--collect-missing", "out", "h1"])
        # Shared flags are peeled even after `--collect-missing` (not treated as HOST).
        let r = parse_drive_args(["--collect-missing", "out", "--quiet", "h1"])
            @test r.collect_hosts == ["h1"]
            @test r.cli_session.quiet
            DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags())
        end
        @test_throws ArgumentError parse_drive_args(["--collect-missing", "out", "--foo", "h1"])
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
        @test occursin("head-workers", txt)
        @test occursin("progress DIR", txt)
        @test occursin("--unsafe-skip-env-digests", txt)
        @test !occursin(r"--parent(?!-gb)", txt)
        @test !occursin(r"(^|\s)--local(?!-)", txt)
        @test !occursin("--mem-headroom", txt)
        @test !occursin("--parent-gb", txt)
        @test occursin("DISTSSH_JOBS", txt)
        @test !occursin("DISTSSH_REQUIRE_ALL_HOSTS", txt)
        @test !occursin("DISTSSH_BEST_EFFORT", txt)
        @test occursin("--best-effort", txt)
        @test !occursin("required after `setup --rsync`", txt)
        @test occursin("--deploy-root", txt)
        @test occursin("Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT", txt)
    end

    @testset "deploy-root" begin
        let r = parse_drive_args(["--deploy-root", "/tmp/my dir", "--head-workers", "1", "s.jl"])
            @test r.deploy_root == "/tmp/my dir"
            @test r.script_path == "s.jl"
        end
        let r = parse_drive_args(["--deploy-root", "/tmp/App", "--", "--head-workers", "1", "s.jl", "1"])
            @test r.deploy_root == "/tmp/App"
            @test r.script_args == ["1"]
        end
        let r = parse_drive_args(["--head-workers", "1", "s.jl", "--deploy-root", "/tmp/x"])
            @test r.deploy_root === nothing
            @test r.script_args == ["--deploy-root", "/tmp/x"]
        end
        let r = parse_drive_args(["--", "--head-workers", "1", "s.jl", "--ship-tree"])
            @test r.script_args == ["--ship-tree"]
        end
        let r = parse_drive_args(["--head-workers", "1", "s.jl", "--ship-tree"])
            @test r.script_args == ["--ship-tree"]
        end
        err_after = try
            parse_drive_args(["--", "--ship-tree", "--head-workers", "1", "s.jl"])
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

    @testset "best-effort" begin
        withenv(
            "DISTSSH_REQUIRE_ALL_HOSTS" => nothing,
            "DISTSSH_BEST_EFFORT" => nothing
        ) do
            @test !parse_drive_args(["--head-workers", "1", "s.jl"]).best_effort
            @test parse_drive_args(["--best-effort", "--head-workers", "1", "s.jl"]).best_effort
            @test_throws ArgumentError parse_drive_args(
                ["--require-all-hosts", "--head-workers", "1", "s.jl"]
            )
            @test_throws ArgumentError parse_drive_args(
                ["--best-effort", "--best-effort", "--head-workers", "1", "s.jl"]
            )
            let r = parse_drive_args(["--collect-missing", "out", "h1"])
                @test !r.best_effort
            end
            let r = parse_drive_args(["--best-effort", "--collect-missing", "out", "h1"])
                @test r.best_effort
            end
            @test_throws ArgumentError parse_drive_args(
                ["--collect-strict", "--collect-missing", "out", "h1"],
            )
        end
        withenv("DISTSSH_REQUIRE_ALL_HOSTS" => "1") do
            @test_throws ArgumentError parse_drive_args(["--head-workers", "1", "s.jl"])
        end
        withenv("DISTSSH_BEST_EFFORT" => "1") do
            @test_throws ArgumentError parse_drive_args(["--head-workers", "1", "s.jl"])
        end
    end
end
