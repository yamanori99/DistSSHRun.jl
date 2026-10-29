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
        @test occursin("--remote-path <that runs/<run_id>/src/>", text)
        @test occursin("control character", text)
        @test !occursin("fish is refused", text)
    end

    let r = parse_setup_args(["--check", "child:host1"])
        @test r.ignore_julia_version == false
    end
    let r = parse_setup_args(["--check", "--ignore-julia-version", "child:host1"])
        @test r.ignore_julia_version == true
    end

    let r = parse_setup_args(["--runtest", "child:host1"])
        @test r.mode == :runtest
        @test r.hosts == ["host1"]
    end

    let r = parse_setup_args(["--ship-tree", "child:host1", "child:host2"])
        @test r.mode == :ship_tree
        @test r.hosts == ["host1", "host2"]
    end

    for (flag, mode) in (
            "--clone" => :clone,
            "--sync" => :sync,
            "--pull" => :pull,
            "--instantiate" => :instantiate,
            "--cleanup" => :cleanup,
            "--prune" => :prune,
            "--delete" => :delete,
            "--requirements" => :requirements,
        )
        let r = parse_setup_args([flag, "child:host1"])
            @test r.mode == mode
            @test r.hosts == ["host1"]
        end
    end

    # The second mode flag fails immediately. Later flags are not applied.
    let err = try
            parse_setup_args(["--check", "--ship-tree", "--pull", "child:host1"])
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("more than one mode (--check and --ship-tree)", err.msg)
        @test occursin("help setup", err.msg)
        @test !occursin("--pull", err.msg)
        @test !occursin("--help", err.msg)
    end
    @test_throws ArgumentError parse_setup_args(["--check", "--check", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--help", "--delete", "--sync"])
    let r = parse_setup_args(["--delete", "--help"])
        @test r.show_help
        @test r.mode == :delete
    end

    let r = parse_setup_args(["--clone", "--repo", "git@ex/app.git", "child:host1"])
        @test r.repo_url == "git@ex/app.git"
        @test r.mode == :clone
    end
    let r = parse_setup_args(["--check", "--remote-path", "~/work/App.jl", "child:host1"])
        @test r.remote_path_override == "~/work/App.jl"
    end
    let r = parse_setup_args(["--check", "--remote-dir", "/tmp/App.jl", "child:host1"])
        @test r.remote_path_override == "/tmp/App.jl"
    end
    let r = parse_setup_args(["--check", "--julia", "/opt/julia/bin/julia", "child:host1"])
        @test r.julia_path == "/opt/julia/bin/julia"
    end
    let r = parse_setup_args(["--version", "--check", "child:host1"])
        @test r.show_version
        @test r.mode == :check
    end
    let r = parse_setup_args(["--prune", "--older-than", "7", "--id", "pi_file", "child:host1"])
        @test r.mode == :prune
        @test r.older_days == 7
        @test r.prune_id == "pi_file"
    end
    let r = parse_setup_args(["--delete", "--confirm-path", "~/App", "child:host1"])
        @test r.mode == :delete
        @test r.confirm_paths == ["~/App"]
    end
    @test DistSSHRun._confirm_path_control_char("a\nb")
    @test DistSSHRun._confirm_path_control_char("a\rb")
    @test DistSSHRun._confirm_path_control_char("a\0b")
    @test !DistSSHRun._confirm_path_control_char(" ~/App ")
    @test_throws ArgumentError parse_setup_args(["--delete", "--confirm-path", "a\nb", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--check", "--confirm-path", "~/App", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--check", "--older-than", "1", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--prune", "--older-than", "-1", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--julia"])
    @test_throws ArgumentError parse_setup_args(["--check", "host1"])
    let err = try
            parse_setup_args(["--check", "--not-a-flag", "child:host1"])
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

    let r = parse_setup_args(["--juliaup", "parent", "child:host1"])
        @test r.mode == :juliaup
        @test r.hosts == ["parent", "host1"]
    end
    let r = parse_setup_args(["--juliaup-update", "child:host1"])
        @test r.mode == :juliaup_update
        @test r.hosts == ["host1"]
    end
    let r = parse_setup_args(["--check", "child:update"])
        @test r.mode == :check
        @test r.hosts == ["update"]
    end
    @test_throws ArgumentError parse_setup_args(["update", "child:host1"])
    @test_throws ArgumentError parse_setup_args(["--juliaup", "child:host1", "update"])

    let r = parse_setup_args(["--check", "--hosts-file", _sample_hosts_file(), "child:host-cli"])
        @test r.hosts == ["host-cli", "host-a", "host-b"]
    end

    let r = parse_setup_args(["--check", "--hosts", "child:h1:9,child:h2", "child:host-cli"])
        @test r.hosts == ["host-cli", "h1", "h2"]
    end

    withenv("DISTSSHKIT_HOSTS" => "child:env-h:3") do
        let r = parse_setup_args(["--check", "child:host-cli"])
            @test r.hosts == ["host-cli", "env-h"]
        end
    end

    @testset "help smoke (rsync-first)" begin
        txt = DistSSHRun.setup_help_text()
        @test occursin("--prune", txt)
        @test occursin("--confirm-path", txt)
        @test occursin("--older-than", txt)
        @test occursin("--runtest", txt)
        @test !occursin("--juliaup", txt)
        @test occursin("--hosts", txt)
        @test occursin("child:host1", txt)
        @test occursin("parent", txt)
        @test occursin("progress DIR", txt)
        @test occursin("Recommended:", txt)
        @test occursin("--require-git", txt)
        @test occursin("DISTSSHKIT_JOBS", txt)
        @test occursin("confirm unless -y", txt)
        @test occursin("does not authorize --delete or --prune", txt)
        @test occursin("except --delete and --prune", txt)
        @test !occursin("day-to-day default", lowercase(txt))
        @test !occursin("drive needs --skip-git-guard", lowercase(txt))
    end
end
