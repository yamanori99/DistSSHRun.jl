using Test

@testset "setup args" begin
    parse_setup_args = DistSSHRun.parse_setup_args

    @test parse_setup_args(["--help"]).show_help
    @test parse_setup_args(["-h"]).show_help

    let buf = IOBuffer()
        DistSSHRun.with_cli_entry(:DistSSHRun) do
            DistSSHRun.show_requirements(; io = buf)
        end
        text = String(take!(buf))
        @test occursin("Remote login shell must be POSIX", text)
        @test occursin("SHELL -c", text)
        @test occursin("sh -l -c", text)
        @test occursin("fish and csh are unsupported", text)
        @test occursin("backslashes inside single quotes", text)
        @test occursin("must not start with '-'", text)
        @test occursin("--snapshot", text)
        @test occursin("Lexical latest is not used", text)
        @test !occursin("latest runs/<run_id>/src", text)
        @test occursin("Ship creates a missing remote_root", text)
        @test occursin("setup remote-root still requires an absolute", text)
        @test occursin("--deploy-root", text)
        @test occursin("workspace Manifest", text)
        @test occursin("each .gitignore", text)
        @test occursin("case-sensitive", text)
        @test occursin("!LocalPreferences.toml", text)
        @test occursin("one warning", text)
        @test occursin("Declared inputs do not", text)
        @test occursin("DISTSSHKIT_SHIP_WARN_FILE_BYTES", text)
        @test occursin("DISTSSHKIT_SHIP_WARN_TOTAL_BYTES", text)
        @test occursin("256 MiB cap", text)
        @test !occursin("git work tree", text)
        @test occursin("common ancestor", text)
        @test occursin("--extra-file", text)
        @test occursin("_distsshrun_external", text)
        @test occursin("Pull-back touches extracted files", text)
        @test occursin("Ship keeps extract-time mtime", text)
        @test occursin("push_cache! uses Tar and a remote Julia", text)
        @test occursin("control character", text)
        @test !occursin("fish is refused", text)
        @test occursin("Omit for DISTRIBUTED_REMOTE_PROJECT_ROOT", text)
        @test !occursin("--remote-path PATH", text)
    end

    let r = parse_setup_args(["check", "child:host1"])
        @test r.ignore_julia_version == false
    end
    let r = parse_setup_args(["check", "--ignore-julia-version", "child:host1"])
        @test r.ignore_julia_version == true
    end

    let r = parse_setup_args(["runtest", "child:host1"])
        @test r.mode == :runtest
        @test r.hosts == ["host1"]
    end

    let r = parse_setup_args(["ship-tree", "child:host1", "child:host2"])
        @test r.mode == :ship_tree
        @test r.hosts == ["host1", "host2"]
    end

    for (name, mode) in (
            "git-clone" => :git_clone,
            "git-sync" => :git_sync,
            "git-pull" => :git_pull,
            "instantiate" => :instantiate,
            "cleanup" => :cleanup,
            "prune" => :prune,
            "delete" => :delete,
            "remote-root" => :remote_root,
            "requirements" => :requirements,
        )
        let r = parse_setup_args([name, "child:host1"])
            @test r.mode == mode
            @test r.hosts == ["host1"]
        end
    end

    for (name, repl) in (
            "clone" => "git-clone",
            "sync" => "git-sync",
            "pull" => "git-pull",
        )
        let err = try
                parse_setup_args([name, "child:host1"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("setup $(name) was removed", err.msg)
            @test occursin("setup $(repl)", err.msg)
            @test occursin("help setup", err.msg)
        end
    end
    for (flag, repl) in (
            "--clone" => "git-clone",
            "--sync" => "git-sync",
            "--pull" => "git-pull",
        )
        let err = try
                parse_setup_args([flag, "child:host1"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("setup $(flag) was removed", err.msg)
            @test occursin("setup $(repl)", err.msg)
        end
    end

    let err = try
            parse_setup_args(["check", "ship-tree", "--pull", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("more than one mode (check and ship-tree)", err.msg)
        @test occursin("help setup", err.msg)
        @test !occursin("--pull", err.msg)
        @test !occursin("--help", err.msg)
    end
    @test_throws ArgumentError parse_setup_args(["check", "check", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--help", "delete", "sync"])
    @test_throws ArgumentError parse_setup_args(["delete", "sync", "child:host1"])
    let r = parse_setup_args(["delete", "--help"])
        @test r.show_help
        @test r.mode == :delete
    end

    let r = parse_setup_args(["git-clone", "--repo", "git@ex/app.git", "child:host1"])
        @test r.repo_url == "git@ex/app.git"
        @test r.mode == :git_clone
    end
    let r = parse_setup_args(["check", "--deploy-root", "~/work/App.jl", "child:host1"])
        @test r.deploy_root == "~/work/App.jl"
    end
    let r = parse_setup_args(["check", "--deploy-root", "/tmp/my dir", "child:host1"])
        @test r.deploy_root == "/tmp/my dir"
    end
    let err = try
            parse_setup_args(["check", "--remote-dir", "/tmp/App.jl", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("setup --remote-dir was removed", err.msg)
        @test occursin("--deploy-root", err.msg)
        @test occursin("help setup", err.msg)
    end
    let err = try
            parse_setup_args(["check", "--remote-path", "~/work/App.jl", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("setup --remote-path was removed", err.msg)
        @test occursin("--deploy-root", err.msg)
        @test !occursin("deprecated", lowercase(err.msg))
    end
    let err = try
            parse_setup_args(["check", "--remote-path=~/work/App.jl", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("setup --remote-path was removed", err.msg)
        @test occursin("--deploy-root", err.msg)
    end
    let r = parse_setup_args(["check", "--deploy-root", " /tmp/App.jl ", "child:host1"])
        @test r.deploy_root == "/tmp/App.jl"
    end
    @test_throws ArgumentError parse_setup_args(
        ["remote-root", "--deploy-root", "/tmp/app\n", "child:host1"],
    )
    @test_throws ArgumentError parse_setup_args(["check", "--deploy-root"])
    let r = parse_setup_args(["check", "--julia", "/opt/julia/bin/julia", "child:host1"])
        @test r.julia_path == "/opt/julia/bin/julia"
    end
    let r = parse_setup_args(["--version", "check", "child:host1"])
        @test r.show_version
        @test r.mode == :check
    end
    let r = parse_setup_args(["prune", "--older-than", "7", "--id", "pi_file", "child:host1"])
        @test r.mode == :prune
        @test r.older_days == 7
        @test r.prune_id == "pi_file"
    end
    let r = parse_setup_args(["delete", "--confirm-path", "~/App", "child:host1"])
        @test r.mode == :delete
        @test r.confirm_paths == ["~/App"]
    end
    @test DistSSHRun._confirm_path_control_char("a\nb")
    @test DistSSHRun._confirm_path_control_char("a\rb")
    @test DistSSHRun._confirm_path_control_char("a\0b")
    @test !DistSSHRun._confirm_path_control_char(" ~/App ")
    @test_throws ArgumentError parse_setup_args(["delete", "--confirm-path", "a\nb", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["check", "--confirm-path", "~/App", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["check", "--older-than", "1", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["prune", "--older-than", "-1", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--julia"])
    @test_throws ArgumentError parse_setup_args(["check", "host1"])
    let err = try
            parse_setup_args(["check", "--not-a-flag", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("unknown setup option: --not-a-flag", err.msg)
        @test occursin("help setup", err.msg)
        @test !occursin("--help", err.msg)
    end
    let err = try
            parse_setup_args(["--help", "--not-a-flag"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("unknown setup option: --not-a-flag", err.msg)
        @test occursin("help setup", err.msg)
        @test !occursin("--help", err.msg)
    end

    let err = try
            parse_setup_args(["--juliaup", "parent", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("setup --juliaup was removed", err.msg)
        @test occursin("up add CHANNEL", err.msg)
        @test occursin("up default CHANNEL", err.msg)
        @test occursin("help up", err.msg)
    end
    let err = try
            parse_setup_args(["--juliaup-update", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("setup --juliaup-update was removed", err.msg)
        @test occursin("up update", err.msg)
        @test occursin("help up", err.msg)
    end
    for (flag, name) in (
            "--ship-tree" => "ship-tree",
            "--instantiate" => "instantiate",
            "--check" => "check",
            "--delete" => "delete",
            "--remote-root" => "remote-root",
            "--requirements" => "requirements",
        )
        let err = try
                parse_setup_args([flag, "child:host1"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("setup $(flag) was removed", err.msg)
            @test occursin("setup $(name)", err.msg)
        end
    end

    let r = parse_setup_args(["check", "child:update"])
        @test r.mode == :check
        @test r.hosts == ["update"]
    end
    @test_throws ArgumentError parse_setup_args(["update", "child:host1"])

    let r = parse_setup_args(["check", "--hosts-file", _sample_hosts_file(), "child:host-cli"])
        @test r.hosts == ["host-cli", "host-a", "host-b"]
    end

    let r = parse_setup_args(["check", "--hosts", "child:h1:9,child:h2", "child:host-cli"])
        @test r.hosts == ["host-cli", "h1", "h2"]
    end

    withenv("DISTSSHKIT_HOSTS" => "child:env-h:3") do
        let r = parse_setup_args(["check", "child:host-cli"])
            @test r.hosts == ["host-cli", "env-h"]
        end
    end

    let r = parse_setup_args(["check", "--", "child:host1"])
        @test r.mode == :check
        @test r.hosts == ["host1"]
    end
    let r = parse_setup_args(
            ["instantiate", "--deploy-root", "/tmp/App.jl", "--snapshot", "20260101T000000Z-aaaaaa", "child:h1"],
        )
        @test r.mode == :instantiate
        @test r.deploy_root == "/tmp/App.jl"
        @test r.snapshot_id == "20260101T000000Z-aaaaaa"
    end
    let r = parse_setup_args(["--deploy-root", "/tmp/App.jl", "check", "child:h1"])
        @test r.mode == :check
        @test r.deploy_root == "/tmp/App.jl"
    end

    @testset "help smoke (rsync-first)" begin
        txt = DistSSHRun.setup_help_text()
        @test occursin("prune", txt)
        @test occursin("remote-root", txt)
        @test occursin("run.toml stamp", txt)
        @test occursin("unowned Ship run.toml", txt)
        @test occursin("--confirm-path", txt)
        @test occursin("--older-than", txt)
        @test occursin("runtest", txt)
        @test !occursin("--juliaup", txt)
        @test !occursin("--remote-dir", txt)
        @test occursin("--hosts", txt)
        @test occursin("child:host1", txt)
        @test occursin("parent", txt)
        @test occursin("progress DIR", txt)
        @test occursin("Recommended:", txt)
        @test occursin("--require-git", txt)
        @test occursin("DISTSSHKIT_JOBS", txt)
        @test occursin("confirm unless -y", txt)
        @test occursin("does not authorize delete or prune", txt)
        @test occursin("except delete and prune", txt)
        @test !occursin("day-to-day default", lowercase(txt))
        @test !occursin("drive needs --skip-git-guard", lowercase(txt))
    end

    @testset "extra-file is collected and rejected by the API" begin
        one = parse_setup_args(["ship-tree", "--extra-file", "/tmp/job.jl", "child:h1"])
        @test one.extra_files == ["/tmp/job.jl"]
        two = parse_setup_args(
            [
                "ship-tree", "--extra-file", "/tmp/a.jl", "--extra-file", "/tmp/b.jl", "child:h1",
            ]
        )
        @test two.extra_files == ["/tmp/a.jl", "/tmp/b.jl"]
        other = parse_setup_args(["instantiate", "--extra-file", "/tmp/a.jl", "child:h1"])
        @test other.extra_files == ["/tmp/a.jl"]
        err_n = try
            DistSSHRun.check_setup_options!(:ship_tree; extra_files = two.extra_files)
            nothing
        catch e
            e
        end
        err_mode = try
            DistSSHRun.check_setup_options!(:instantiate; extra_files = other.extra_files)
            nothing
        catch e
            e
        end
        session = DistSSHRun.KitSession(workers = ["child:h1"], project = pwd(), yes = true)
        err_api = try
            DistSSHRun.setup!(session, :ship_tree; extra_files = two.extra_files)
            nothing
        catch e
            e
        end
        err_api_mode = try
            DistSSHRun.setup!(session, :instantiate; extra_files = other.extra_files)
            nothing
        catch e
            e
        end
        @test err_n isa ArgumentError
        @test err_api isa ArgumentError
        @test err_n.msg == err_api.msg
        @test err_n.msg == "more than one extra file is not yet supported"
        @test err_mode isa ArgumentError
        @test err_api_mode isa ArgumentError
        @test err_mode.msg == err_api_mode.msg
        snap = DistSSHRun.DistSSHShip.pack_tree
        err_ship = try
            snap(pwd(); extra_files = two.extra_files)
            nothing
        catch e
            e
        end
        @test err_ship isa ArgumentError
        @test err_ship.msg == err_n.msg
        err_sync = try
            DistSSHRun.sync!(session; mode = :sync, extra_files = other.extra_files)
            nothing
        catch e
            e
        end
        @test err_sync isa ArgumentError
        @test occursin("mode=:sync was removed", err_sync.msg)
    end
end
