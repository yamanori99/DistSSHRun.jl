using Test
using DistSSHRun

function _bind_err(f)
    try
        f()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    error("expected ArgumentError")
end

@testset "strict bind contract (#503)" begin
    @testset "accept loopback and canonicalize" begin
        lit = DistSSHRun.parse_bind_ipv4_literal("127.0.0.1")
        @test lit.canonical == "127.0.0.1"
        @test lit.loopback
        @test !lit.all_interfaces
        @test_throws ArgumentError DistSSHRun.parse_bind_ipv4_literal("127.1")
    end

    @testset "accept non-loopback with unsafe opt-in" begin
        msg = _bind_err(() -> DistSSHRun.validate_host_launch_plan("h", "10.0.0.5"))
        @test msg == join(
            [
                "\"h\": non-loopback bind \"10.0.0.5\"",
                "Hint: pass --unsafe-expose-port to expose the worker port beyond loopback",
            ],
            "\n",
        )
        plan = DistSSHRun.validate_host_launch_plan(
            "h",
            "10.0.0.5";
            unsafe_expose_port = true,
        )
        @test plan.bind == "10.0.0.5"
    end

    @testset "0.0.0.0 display and gates" begin
        lit = DistSSHRun.parse_bind_ipv4_literal("0.0.0.0")
        @test lit.all_interfaces
        @test DistSSHRun.bind_dry_run_display(lit) == "0.0.0.0 (all interfaces)"
        msg = _bind_err(
            () ->
            DistSSHRun.validate_host_launch_plan("h", "0.0.0.0"; tunnel = false, unsafe_expose_port = true)
        )
        @test occursin("0.0.0.0 requires --unsafe-expose-port and SSH tunnel enabled", msg)
    end

    @testset "reject multicast reserved broadcast" begin
        for bad in ("224.0.0.1", "240.0.0.1", "255.255.255.255")
            msg = _bind_err(() -> DistSSHRun.parse_bind_ipv4_literal(bad))
            @test occursin("multicast", msg) || occursin("reserved", msg) || occursin("broadcast", msg)
        end
    end

    @testset "reject short form leading zero sign range" begin
        for bad in ("127.1", "127.01.0.1", "300.0.0.1", "1.2.3.4.5", "-1.0.0.1")
            @test_throws ArgumentError DistSSHRun.parse_bind_ipv4_literal(bad)
        end
        @test _bind_err(() -> DistSSHRun.parse_bind_ipv4_literal("127.01.0.1")) ==
            "bind \"127.01.0.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (must not use leading zeros); fix: bind = \"127.0.0.1\""
    end

    @testset "reject IPv6 host names port whitespace empty" begin
        @test _bind_err(() -> DistSSHRun.parse_bind_ipv4_literal("localhost")) ==
            "bind \"localhost\" is not an IPv4 address; checked: dotted-quad IPv4 literal (names are not resolved); fix: bind = \"127.0.0.1\""
        _with_tempdir() do tmp
            path = joinpath(tmp, "hosts.toml")
            write(
                path,
                """
                [[hosts]]
                name = "alice@mac-b"
                bind = "localhost"
                """,
            )
            msg = _bind_err(
                () ->
                DistSSHRun.resolve_launch_bind_overrides(;
                    hosts_file = path,
                    planned_hosts = ["alice@mac-b"],
                )
            )
            @test occursin("hosts[1] (alice@mac-b)", msg)
            @test occursin("localhost", msg)
            @test occursin("names are not resolved", msg)
        end
        for bad in ("::1", "[::1]", "::ffff:127.0.0.1", "10.0.0.1:8080", " 10.0.0.1", "10.0.0.1 ")
            @test_throws ArgumentError DistSSHRun.parse_bind_ipv4_literal(bad)
        end
        @test _bind_err(() -> DistSSHRun.parse_bind_ipv4_literal("")) ==
            "bind is empty; checked: dotted-quad IPv4 literal; fix: bind = \"127.0.0.1\""
    end

    @testset "dry-run and validate_all_host_launch_plans agree" begin
        overrides = Dict("lab" => "10.0.0.2")
        dry_plan = DistSSHRun.validate_host_launch_plan(
            "lab",
            DistSSHRun.resolved_bind_address("lab", overrides);
            unsafe_expose_port = true,
        )
        batch = DistSSHRun.validate_all_host_launch_plans!(
            ["lab"],
            overrides;
            unsafe_expose_port = true,
        )
        @test length(batch) == 1
        @test DistSSHRun.format_host_launch_plan_line(dry_plan) ==
            DistSSHRun.format_host_launch_plan_line(batch[1])
    end
end
