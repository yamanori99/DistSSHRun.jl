using Test
using DistSSHRun

function _parse_bind_err(raw)
    try
        DistSSHRun.parse_bind_ipv4_literal(raw)
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    error("expected ArgumentError for $(repr(raw))")
end

function _gate_err(f)
    try
        f()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    error("expected ArgumentError")
end

const _FIX = "bind = \"127.0.0.1\""

@testset "bind contract table (#503 exact messages)" begin
    cases = [
        ("127.0.0.1", :accept, "127.0.0.1"),
        ("127.0.0.2", :gate_tunnel, ""),
        ("10.0.0.5", :gate_unsafe, ""),
        ("0.0.0.0", :accept, "0.0.0.0"),
        ("224.0.0.1", :reject, "bind \"224.0.0.1\" is a multicast address; checked: dotted-quad IPv4 unicast literal; fix: $_FIX"),
        ("240.0.0.1", :reject, "bind \"240.0.0.1\" is a reserved address; checked: dotted-quad IPv4 unicast literal; fix: $_FIX"),
        ("255.1.1.1", :reject, "bind \"255.1.1.1\" is a reserved address; checked: dotted-quad IPv4 unicast literal; fix: $_FIX"),
        ("0.1.2.3", :reject, "bind \"0.1.2.3\" is in 0.0.0.0/8; checked: dotted-quad IPv4 unicast literal; fix: $_FIX"),
        ("255.255.255.255", :reject, "bind \"255.255.255.255\" is a broadcast address; checked: dotted-quad IPv4 unicast literal; fix: $_FIX"),
        ("127.1", :reject, "bind \"127.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (need four decimal parts); fix: $_FIX"),
        ("127.01.0.1", :reject, "bind \"127.01.0.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (must not use leading zeros); fix: $_FIX"),
        ("-1.0.0.1", :reject, "bind \"-1.0.0.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (must not contain a sign); fix: $_FIX"),
        ("300.0.0.1", :reject, "bind \"300.0.0.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (exceeds 255); fix: $_FIX"),
        ("99999999999999999999.0.0.1", :reject, "bind \"99999999999999999999.0.0.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (exceeds 255); fix: $_FIX"),
        ("::1", :reject, "bind \"::1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (IPv6 is not supported); fix: $_FIX"),
        ("[::1]", :reject, "bind \"[::1]\" is not an IPv4 address; checked: dotted-quad IPv4 literal (IPv6 is not supported); fix: $_FIX"),
        ("fe80::1%eth0", :reject, "bind \"fe80::1%eth0\" is not an IPv4 address; checked: dotted-quad IPv4 literal (IPv6 and zone IDs are not supported); fix: $_FIX"),
        ("localhost", :reject, "bind \"localhost\" is not an IPv4 address; checked: dotted-quad IPv4 literal (names are not resolved); fix: $_FIX"),
        ("127.evil.example", :reject, "bind \"127.evil.example\" is not an IPv4 address; checked: dotted-quad IPv4 literal (names are not resolved); fix: $_FIX"),
        ("127.0.0.1:8080", :reject, "bind \"127.0.0.1:8080\" is not an IPv4 address; checked: dotted-quad IPv4 literal (ports are not allowed); fix: $_FIX"),
        (" 127.0.0.1", :reject, "bind \" 127.0.0.1\" must not contain leading or trailing whitespace; checked: dotted-quad IPv4 literal; fix: $_FIX"),
        ("", :reject, "bind is empty; checked: dotted-quad IPv4 literal; fix: $_FIX"),
        ("1..2.3", :reject, "bind \"1..2.3\" is not an IPv4 address; checked: dotted-quad IPv4 literal (need four decimal parts); fix: $_FIX"),
        ("0x7f.0.0.1", :reject, "bind \"0x7f.0.0.1\" is not an IPv4 address; checked: dotted-quad IPv4 literal (must use decimal digits only); fix: $_FIX"),
    ]
    for (raw, kind, expect) in cases
        @testset "$raw" begin
            if kind === :accept
                lit = DistSSHRun.parse_bind_ipv4_literal(raw)
                @test lit.canonical == expect
            elseif kind === :reject
                @test _parse_bind_err(raw) == expect
            elseif kind === :gate_tunnel
                msg = _gate_err(
                    () -> DistSSHRun.validate_host_launch_plan("h", "127.0.0.2"; tunnel = false),
                )
                @test msg == join(
                    [
                        "\"h\": SSH tunnel is off but bind is \"127.0.0.2\"",
                        "Hint: enable tunnel (default) or set a non-loopback bind with --unsafe-expose-port",
                    ],
                    "\n",
                )
            elseif kind === :gate_unsafe
                msg = _gate_err(() -> DistSSHRun.validate_host_launch_plan("h", "10.0.0.5"))
                @test msg == join(
                    [
                        "\"h\": non-loopback bind \"10.0.0.5\"",
                        "Hint: pass --unsafe-expose-port to expose the worker port beyond loopback",
                    ],
                    "\n",
                )
            end
        end
    end
    @testset "0.0.0.0 gates" begin
        msg_tunnel = _gate_err(
            () -> DistSSHRun.validate_host_launch_plan("h", "0.0.0.0"; tunnel = false, unsafe_expose_port = true),
        )
        @test msg_tunnel == join(
            [
                "\"h\": bind 0.0.0.0 requires --unsafe-expose-port and SSH tunnel enabled",
                "Hint: pass --unsafe-expose-port and keep tunnel enabled (default)",
            ],
            "\n",
        )
        msg_unsafe = _gate_err(
            () -> DistSSHRun.validate_host_launch_plan("h", "0.0.0.0"; tunnel = true, unsafe_expose_port = false),
        )
        @test occursin("0.0.0.0", msg_unsafe)
    end
    @testset "non-string TOML bind" begin
        _with_tempdir() do tmp
            path = joinpath(tmp, "h.toml")
            write(path, "[[hosts]]\nname = \"h\"\nbind = 1\n")
            let msg = try
                    DistSSHRun.DistSSHBase.read_toml_host_entries(path)
                catch e
                    e isa ArgumentError ? e.msg : rethrow()
                end
                @test msg ==
                    "$(path): hosts[1]: bind must be a string, got Int64; checked: TOML bind field; fix: $_FIX"
            end
        end
    end
end
