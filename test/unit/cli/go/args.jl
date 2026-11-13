using Test

@testset "go args" begin
    parse_go_args = DistSSHRun.parse_go_args

    @testset "help flags" begin
        @test parse_go_args(["--help"]).help
        @test parse_go_args(["-h"]).help
        err_help = try
            parse_go_args(
                [
                    "--julia", "/opt/julia/bin/julia",
                    "--output-dir", "my_runs",
                    "--git-sync", "child:h1",
                    "--help",
                ],
            )
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_help isa ArgumentError
        @test occursin("go: --git-sync was removed", err_help.msg)
        let r = parse_go_args(
                [
                    "--julia", "/opt/julia/bin/julia",
                    "--output-dir", "my_runs",
                    "--help",
                ],
            )
            @test r.help
            @test r.julia == "/opt/julia/bin/julia"
            @test r.output_dir == "my_runs"
        end
    end

    @testset "script and hosts" begin
        let r = parse_go_args(["demos/foo.jl", "8"])
            @test r.script_path == "demos/foo.jl"
            @test r.script_args == ["8"]
            @test isempty(r.hosts)
        end
        let r = parse_go_args(["child:user@lab:1", "job.jl"])
            @test r.script_path == "job.jl"
            @test r.hosts == ["child:user@lab:1"]
        end
        let r = parse_go_args(["--hosts", "child:host-a:1,child:host-b:2", "job.jl"])
            @test r.hosts == ["child:host-a:1", "child:host-b:2"]
            @test r.script_path == "job.jl"
        end
        @test_throws ArgumentError parse_go_args(["user@lab", "job.jl"])
        @test_throws ArgumentError parse_go_args(["parent", "job.jl"])
        @test_throws ArgumentError parse_go_args(["child:host1", "job.jl"])
        let r = parse_go_args(["parent:4", "child:host1:1", "child:host2:2", "job.jl"])
            @test DistSSHRun.host_tokens(r; kind = :go) == ["parent:4", "child:host1:1", "child:host2:2"]
        end
        let r = parse_go_args(["child:local:2", "child:h1:1", "job.jl", "4"])
            @test r.hosts == ["child:local:2", "child:h1:1"]
            @test DistSSHRun.host_tokens(r; kind = :go) == ["child:local:2", "child:h1:1"]
            @test DistSSHRun.host_tokens(r.hosts) == ["child:local:2", "child:h1:1"]
            @test_throws ArgumentError DistSSHRun.host_tokens(r; kind = :pipeline)
            @test r.script_path == "job.jl"
            @test r.script_args == ["4"]
        end
        let r = parse_go_args(["--output-dir", "my_runs", "job.jl"])
            @test r.output_dir == "my_runs"
            @test r.script_path == "job.jl"
        end
        let r = parse_go_args(["--julia", "/opt/julia/bin/julia", "job.jl"])
            @test r.julia == "/opt/julia/bin/julia"
            @test r.script_path == "job.jl"
        end
        let r = parse_go_args(["--julia", "auto", "job.jl"])
            @test r.julia === nothing
        end
        let r = parse_go_args(["--unsafe-heterogeneous", "parent:1", "job.jl"])
            @test r.unsafe_heterogeneous
        end
        @test_throws ArgumentError parse_go_args(["--allow-mismatch", "julia", "job.jl"])
        withenv("JULIA_DISTRIBUTED_EXE" => "/env/julia") do
            let r = parse_go_args(["job.jl"])
                @test r.julia == "/env/julia"
            end
            let r = parse_go_args(["--julia", "auto", "job.jl"])
                @test r.julia === nothing
            end
        end
    end

    @testset "sync flags" begin
        let r = parse_go_args(["child:local:2", "child:h1:1", "job.jl"])
            @test r.script_path == "job.jl"
        end
        let err_sync = try
                parse_go_args(["--sync", "child:h1:1", "job.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err_sync isa ArgumentError
            @test occursin("go: --sync was removed", err_sync.msg)
            @test occursin("setup git-sync", err_sync.msg)
        end
        let err_git = try
                parse_go_args(["--git-sync", "child:h1:1", "job.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err_git isa ArgumentError
            @test occursin("go: --git-sync was removed", err_git.msg)
        end
        err_ship = try
            parse_go_args(["--ship-tree", "child:h1:1", "job.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_ship isa ArgumentError
        @test occursin("go: --ship-tree was removed", err_ship.msg)
        @test occursin("setup ship-tree", err_ship.msg)
        @test occursin("--run-id", err_ship.msg)
        DistSSHRun.DistSSHBase.with_cli_entry(:DistSSHQueue) do
            qerr = try
                parse_go_args(["--ship-tree", "child:h1:1", "job.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test qerr isa ArgumentError
            @test occursin("julia -m DistSSHKit setup ship-tree", qerr.msg)
            @test !occursin("DistSSHQueue setup ship-tree", qerr.msg)
        end
        err_ext = try
            parse_go_args(["--allow-external-symlinks", "child:h1:1", "job.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_ext isa ArgumentError
        @test occursin("go: --allow-external-symlinks was removed", err_ext.msg)
        @test occursin("setup ship-tree", err_ext.msg)
        let err_skip = try
                parse_go_args(["--skip-sync", "child:local:1", "child:h1:2", "job.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err_skip isa ArgumentError
            @test occursin("go: --skip-sync was removed", err_skip.msg)
            @test occursin("no pre-run sync", err_skip.msg)
        end
        let err_skip = try
                parse_go_args(["--skip-git-sync", "child:local:1", "child:h1:2", "job.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err_skip isa ArgumentError
            @test occursin("go: --skip-git-sync was removed", err_skip.msg)
        end
        let err_guard = try
                parse_go_args(["--skip-git-guard", "child:h1:1", "job.jl"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err_guard isa ArgumentError
            @test occursin("go: --skip-git-guard was removed", err_guard.msg)
        end
        err = try
            parse_go_args(["--skip-git-sync", "--rsync", "job.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("go: --skip-git-sync was removed", err.msg)
        @test_throws ArgumentError parse_go_args(["--git-sync", "job.jl"])
        err2 = try
            parse_go_args(["--git-sync", "--rsync", "job.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err2 isa ArgumentError
        @test occursin("go: --git-sync was removed", err2.msg)
    end

    @testset "version, quiet, and hosts env" begin
        let r = parse_go_args(["--version"])
            @test r.show_version
        end
        let r = parse_go_args(["-q", "-y", "job.jl"])
            @test r.cli_session.quiet
            @test r.cli_session.yes
            DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession())
        end
        withenv("DISTSSH_HOSTS" => "child:env-a:2,child:env-b:1") do
            let r = parse_go_args(["job.jl"])
                @test r.hosts == ["child:env-a:2", "child:env-b:1"]
            end
        end
        @test_throws ArgumentError parse_go_args(
            ["--gb-per-worker", "1.5", "parent", "job.jl"],
        )
        @test_throws ArgumentError parse_go_args(["--julia"])
    end

    @testset "--repeat" begin
        let r = parse_go_args(["--repeat", "100", "job.jl"])
            @test r.repeat == 100
            @test r.script_path == "job.jl"
            @test isempty(r.hosts)
        end
        @test_throws ArgumentError parse_go_args(["--repeat", "0", "job.jl"])
        @test_throws ArgumentError parse_go_args(["--repeat", "x", "job.jl"])
        @test_throws ArgumentError parse_go_args(["--repeat", "2", "--repeat", "3", "job.jl"])
    end

    @testset "help smoke" begin
        txt = sprint(io -> DistSSHRun.show_go_usage(; io = io))
        @test occursin("Usage", txt)
        @test occursin("--output-dir", txt)
        @test !occursin("--git-sync", txt)
        @test !occursin("--skip-sync", txt)
        @test !occursin("--ship-tree", txt)
        @test occursin("setup ship-tree", txt)
        @test occursin("--run-id", txt)
        @test occursin("runs/<ID>/src", txt)
        @test occursin("--hosts", txt)
        @test occursin("--repeat", txt)
        @test occursin("--unsafe-heterogeneous", txt)
        @test occursin("parent", txt)
        @test occursin("progress DIR", txt)
        @test occursin("slot pull-back uses Tar", txt)
        @test occursin("--deploy-root", txt)
        @test occursin("Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT", txt)
        @test !occursin("--remote-path PATH", txt)
    end

    @testset "deploy-root" begin
        let r = parse_go_args(["--deploy-root", "/tmp/my dir", "parent:1", "job.jl"])
            @test r.deploy_root == "/tmp/my dir"
            @test r.script_path == "job.jl"
        end
        let r = parse_go_args(["--deploy-root", "/tmp/App", "--", "parent:1", "job.jl", "--n", "1"])
            @test r.deploy_root == "/tmp/App"
            @test r.script_args == ["--n", "1"]
        end
        let r = parse_go_args(["parent:1", "job.jl", "--deploy-root", "/tmp/swallowed"])
            @test r.deploy_root === nothing
            @test r.script_args == ["--deploy-root", "/tmp/swallowed"]
        end
        let r = parse_go_args(["--", "parent:1", "job.jl", "--ship-tree"])
            @test r.script_args == ["--ship-tree"]
        end
        let r = parse_go_args(["parent:1", "job.jl", "--ship-tree"])
            @test r.script_args == ["--ship-tree"]
        end
        err_after = try
            parse_go_args(["--", "--ship-tree", "parent:1", "job.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err_after isa ArgumentError
        @test occursin("unknown go option: --ship-tree", err_after.msg)
        @test !occursin("was removed", err_after.msg)
        err = try
            parse_go_args(["--remote-path", "/tmp/App", "parent:1", "job.jl"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("go --remote-path was removed", err.msg)
        @test occursin("--deploy-root", err.msg)
        @test_throws ArgumentError parse_go_args(["--remote-path=/tmp/App", "parent:1", "job.jl"])
        @test_throws ArgumentError parse_go_args(["--deploy-root"])
    end

    @testset "unknown option and missing script" begin
        @test_throws ArgumentError parse_go_args(["--nope"])
        let r = parse_go_args(["child:h1"])
            @test r.script_path === nothing
            @test r.hosts == ["child:h1"]
            @test !r.help
        end
        mktemp() do path, io
            code = withenv("DISTSSH_CLI_SUBCOMMAND_DONE" => "") do
                redirect_stderr(devnull) do
                    redirect_stdout(io) do
                        DistSSHRun.go(String[])
                    end
                end
            end
            flush(io)
            @test code == 0
            @test occursin("SCRIPT.jl", read(path, String))
        end
        mktemp() do out_path, out_io
            mktemp() do err_path, err_io
                code = withenv("DISTSSH_CLI_SUBCOMMAND_DONE" => "") do
                    redirect_stdin(devnull) do
                        redirect_stdout(out_io) do
                            redirect_stderr(err_io) do
                                DistSSHRun.go(["--ship-tree", "child:h1:1", "job.jl"])
                            end
                        end
                    end
                end
                flush(out_io)
                flush(err_io)
                shown = read(out_path, String) * read(err_path, String)
                @test code == 1
                @test occursin("go: --ship-tree was removed", shown)
                @test occursin("setup ship-tree", shown)
                @test !occursin("SSH preflight", shown)
                @test !occursin("cannot SSH", shown)
            end
        end
    end

    @testset "--hosts-file keeps host:N" begin
        hosts_file = _sample_hosts_file()
        withenv("DISTSSH_HOSTS" => nothing, "DISTSSH_HOSTS_FILE" => nothing) do
            let r = parse_go_args(["--hosts-file", hosts_file, "job.jl"])
                @test r.hosts == ["child:host-a:1", "child:host-b:4"]
                @test r.script_path == "job.jl"
            end
        end
    end
end
