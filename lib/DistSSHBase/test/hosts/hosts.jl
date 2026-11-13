using Test

@testset "hosts helpers" begin
    @testset "is_parent_host_name" begin
        @test DistSSHBase.is_parent_host_name("parent")
        @test !DistSSHBase.is_parent_host_name("local")
        @test !DistSSHBase.is_parent_host_name("localhost")
        @test !DistSSHBase.is_parent_host_name("l")
        @test !DistSSHBase.is_parent_host_name("root@192.0.2.10")
        @test !DistSSHBase.is_parent_host_name("worker-node-a")
        @test DistSSHBase.parse_placement_token("parent:2") ==
            (role = :parent, name = "parent", n = 2)
        @test DistSSHBase.parse_placement_token("child:user@h1:4") ==
            (role = :child, name = "user@h1", n = 4)
        @test DistSSHBase.format_placement_token(:child, "user@h1", 4) == "child:user@h1:4"
        @test_throws ArgumentError DistSSHBase.parse_placement_token("user@h1")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("parenthost:2")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("child:parent")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("child:-oBatchMode=yes")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("child:user@-h")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("child:h\nname")
        @test DistSSHBase.validate_ssh_host("user@host:/tmp/a b") == "user@host:/tmp/a b"
        @test DistSSHBase.validate_ssh_host("alice@h") == "alice@h"
    end

    @testset "looks_like_path_host / script" begin
        @test DistSSHBase.looks_like_script_host("script.jl")
        @test DistSSHBase.looks_like_script_host("demos/foo.JL")
        @test DistSSHBase.looks_like_path_host("demos/orchestration/my_sim.jl")
        @test DistSSHBase.looks_like_path_host("relative/path")
        @test !DistSSHBase.looks_like_path_host("root@192.0.2.10")
        @test !DistSSHBase.looks_like_path_host("user@host:22")  # colon ok; @ present
        @test !DistSSHBase.looks_like_path_host("worker-node-a")
        _with_tempdir() do tmp
            cd(tmp) do
                write("worker-node-a", "")
                @test DistSSHBase.looks_like_path_host("worker-node-a")
            end
        end
    end

    @testset "summarize_ssh_error" begin
        usekey = ErrorException("/Users/x/.ssh/config: line 27: Bad configuration option: usekeychain")
        msg = DistSSHBase.summarize_ssh_error(usekey)
        @test occursin("UseKeychain", msg)
        @test occursin("IgnoreUnknown", msg)

        auth = ErrorException("Permission denied (publickey).")
        @test occursin("ssh-copy-id", DistSSHBase.summarize_ssh_error(auth))

        dns = ErrorException("Could not resolve hostname foo: nodename nor servname provided")
        @test occursin("not found", DistSSHBase.summarize_ssh_error(dns))

        timed = ErrorException("Connection timed out")
        @test occursin("timeout", DistSSHBase.summarize_ssh_error(timed))

        via_stderr = DistSSHBase.summarize_ssh_error(
            ErrorException("failed process"),
            stderr = "Bad configuration option: usekeychain\nterminating",
        )
        @test occursin("IgnoreUnknown", via_stderr)

        short = DistSSHBase.summarize_ssh_error(
            ErrorException("x");
            stderr = "only stderr line",
        )
        @test short == "only stderr line"
    end

    @testset "host_tokens" begin
        @test DistSSHBase.host_tokens(["child:h1:1"]) == ["child:h1:1"]
        @test DistSSHBase.host_tokens(Tuple{String, Union{Int, Nothing}}[("h1", 2)]; parent_workers = 3) ==
            ["parent:3", "child:h1:2"]
        go = (hosts = ["parent:4", "child:h1:1"],)
        @test DistSSHBase.host_tokens(go; kind = :go) == ["parent:4", "child:h1:1"]
        drive = (
            hosts = Tuple{String, Union{Int, Nothing}}[("h1", 1)],
            parent_workers = 7,
        )
        @test DistSSHBase.host_tokens(drive; kind = :drive) == ["parent:7", "child:h1:1"]
        @test_throws ArgumentError DistSSHBase.host_tokens(go; kind = :pipeline)
    end

    @testset "hosts file" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts")
            write(path, "# lab hosts\nchild:host-a:1\nchild:host-b:4\n")
            @test DistSSHBase.read_hosts_file_lines(path) == ["child:host-a:1", "child:host-b:4"]
            @test DistSSHBase.split_worker_token("host-b:4") == ("host-b", 4)
            @test DistSSHBase.parse_placement_token("child:host-b:4") ==
                (role = :child, name = "host-b", n = 4)
            @test DistSSHBase.split_hosts_csv(" child:a:1, ,child:b ") == ["child:a:1", "child:b"]
        end
    end
end
