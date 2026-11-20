using Test

@testset "hosts helpers" begin
    @testset "is_parent_host_name" begin
        @test DistSSHBase.is_parent_host_name("parent")
        @test !DistSSHBase.is_parent_host_name("local")
        @test !DistSSHBase.is_parent_host_name("localhost")
        @test !DistSSHBase.is_parent_host_name("l")
        @test !DistSSHBase.is_parent_host_name("root@192.0.2.10")
        @test !DistSSHBase.is_parent_host_name("worker-node-a")
        @test DistSSHBase.parse_placement_token("4*user@h1") ==
            (role = :child, name = "user@h1", n = 4)
        @test DistSSHBase.parse_placement_token("user@h1") ==
            (role = :child, name = "user@h1", n = 1)
        @test DistSSHBase.format_placement_token(:child, "user@h1", 4) == "4*user@h1"
        @test_throws ArgumentError DistSSHBase.parse_placement_token("parent:2")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("parenthost:2")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("4*parent")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("4*parent:22")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("-oBatchMode=yes")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("user@-h")
        @test_throws ArgumentError DistSSHBase.parse_placement_token("h\nname")
        @test DistSSHBase.validate_ssh_host("user@host:/tmp/a b") == "user@host:/tmp/a b"
        @test DistSSHBase.validate_ssh_host("alice@h") == "alice@h"
    end

    @testset "IPv6 message quoting and host:path" begin
        function _catch_ipv6(f)
            try
                f()
                return nothing
            catch e
                e
            end
        end
        v_err = _catch_ipv6(() -> DistSSHBase.validate_ssh_host("::1"))
        e_err = _catch_ipv6(() -> DistSSHBase.parse_ssh_endpoint("::1"))
        @test v_err isa ArgumentError && e_err isa ArgumentError
        v_msg = sprint(showerror, v_err)
        e_msg = sprint(showerror, e_err)
        @test v_msg == e_msg
        @test startswith(v_msg, "ArgumentError: \"::1\": IPv6 literals are not supported")
        @test !occursin("\"\\\"::1\\\"\"", v_msg)

        @test DistSSHBase.validate_ssh_host("host:/a:b") == "host:/a:b"
        @test DistSSHBase.validate_ssh_host("user@host:/tmp/x:y") == "user@host:/tmp/x:y"

        for bad in ("::1", "[::1]", "user@[::1]:22", "fe80::1%eth0")
            @test _catch_ipv6(() -> DistSSHBase.validate_ssh_host(bad)) isa ArgumentError
            @test occursin(
                "IPv6 literals are not supported",
                sprint(showerror, _catch_ipv6(() -> DistSSHBase.validate_ssh_host(bad))),
            )
        end
    end

    @testset "looks_like_path_host / script" begin
        @test DistSSHBase.looks_like_script_host("script.jl")
        @test DistSSHBase.looks_like_script_host("demos/foo.JL")
        @test DistSSHBase.looks_like_path_host("demos/orchestration/my_sim.jl")
        @test DistSSHBase.looks_like_path_host("relative/path")
        @test !DistSSHBase.looks_like_path_host("root@192.0.2.10")
        @test !DistSSHBase.looks_like_path_host("user@host:22")
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

    @testset "machine SSH port" begin
        ep = DistSSHBase.parse_machine_token("2*alice@lab:2222")
        @test DistSSHBase.machine_ssh_endpoint(ep) == "alice@lab:2222"
        @test DistSSHBase.split_worker_token("alice@lab:2222") == ("alice@lab:2222", nothing)
        @test DistSSHBase.parse_placement_token("alice@lab:2222").name == "alice@lab:2222"
        @test DistSSHBase.parse_ssh_endpoint("alice@lab:2222") == ("alice@lab", 2222)
        @test DistSSHBase.parse_ssh_endpoint("lab") == ("lab", nothing)
        a = DistSSHBase.parse_machine_token("host-a:22")
        b = DistSSHBase.parse_machine_token("host-a:2222")
        @test DistSSHBase.machine_ssh_label(a) != DistSSHBase.machine_ssh_label(b)
        @test DistSSHBase.machine_ssh_label(a) == DistSSHBase.machine_ssh_endpoint(a)
        alice = DistSSHBase.parse_machine_token("alice@lab:2222")
        bob = DistSSHBase.parse_machine_token("bob@lab:2222")
        @test DistSSHBase.machine_ssh_label(alice) != DistSSHBase.machine_ssh_label(bob)
        @test DistSSHBase.parse_placement_token("host-a:22").name == "host-a:22"
        josé_ep = "josé@lab:2222"
        @test DistSSHBase.parse_ssh_endpoint(josé_ep) == ("josé@lab", 2222)
        @test DistSSHBase.parse_machine_token(josé_ep).dest == "josé@lab"
    end

    @testset "toml distinct users same host port" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "lab"
                user = "alice"
                port = 2222
                workers = 1

                [[hosts]]
                name = "lab"
                user = "bob"
                port = 2222
                workers = 1
                """,
            )
            entries = DistSSHBase.read_toml_host_entries(path)
            @test length(entries) == 2
            @test DistSSHBase.toml_host_ssh_dest(entries[1]) == "alice@lab:2222"
            @test DistSSHBase.toml_host_ssh_dest(entries[2]) == "bob@lab:2222"
        end
    end

    @testset "host_tokens" begin
        @test DistSSHBase.host_tokens(["1*h1"]) == ["1*h1"]
        @test DistSSHBase.host_tokens(Tuple{String, Union{Int, Nothing}}[("h1", 2)]) == ["2*h1"]
        go = (hosts = ["4*user@h1"],)
        @test DistSSHBase.host_tokens(go; kind = :go) == ["4*user@h1"]
        drive = (
            hosts = Tuple{String, Union{Int, Nothing}}[("h1", 1)],
            head_workers = 7,
        )
        @test DistSSHBase.host_tokens(drive; kind = :drive) == ["h1"]
        @test_throws ArgumentError DistSSHBase.host_tokens(go; kind = :pipeline)
    end

    @testset "hosts file" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts")
            write(path, "# lab hosts\n1*host-a\n4*host-b\n")
            @test DistSSHBase.read_hosts_file_lines(path) == ["1*host-a", "4*host-b"]
            @test DistSSHBase.split_worker_token("4*host-b") == ("host-b", 4)
            @test DistSSHBase.parse_placement_token("4*host-b") ==
                (role = :child, name = "host-b", n = 4)
            @test DistSSHBase.split_hosts_csv(" 1*a, ,b ") == ["1*a", "b"]
        end
    end

    @testset "toml hosts bind" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "lab-a"

                [[hosts]]
                name = "lab-b"
                bind = "10.0.0.5"
                user = "alice"
                """,
            )
            overrides = DistSSHBase.read_toml_host_bind_overrides(path)
            @test overrides == Dict("alice@lab-b" => "10.0.0.5")
            @test !isempty(overrides)
            bad = joinpath(tmp, "bad.toml")
            write(
                bad,
                """
                [[hosts]]
                name = "x"
                bind = ""
                """,
            )
            @test_throws ArgumentError DistSSHBase.read_toml_host_bind_overrides(bad)
        end
    end
end
