using Test

@testset "machine placement tokens" begin
    DB = DistSSHBase
    hint = DB.IPV6_SSH_PLACEMENT_HINT
    @testset "format parse roundtrip" begin
        cases = (
            ("host", 1, nothing),
            ("4*host", 4, nothing),
            ("user@host:2222", 1, 2222),
            ("4*user@host:2222", 4, 2222),
        )
        for (tok, w, port) in cases
            p = DB.parse_machine_token(tok)
            @test p.workers == w
            port === nothing ? (@test p.port === nothing) : (@test p.port == port)
            @test DB.parse_machine_token(DB.format_machine_token(p)) == p
        end
    end

    @testset "reject IPv6 placement tokens" begin
        for bad in (
                "::1",
                "[::1]",
                "2*[::1]",
                "2*[fe80::1]:2222",
                "2*alice@[::1]:2222",
                "user@[::1]",
                "[::1]:2222",
            )
            err = try
                DB.parse_machine_token(bad)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            msg = sprint(showerror, err)
            @test occursin("IPv6 literals are not supported", msg)
            @test occursin("Host lab6", msg)
            @test occursin(hint, msg)
        end
    end

    @testset "legacy migration errors" begin
        @test_throws ArgumentError DB.parse_machine_token("parent:2")
        @test_throws ArgumentError DB.parse_machine_token("child:host-a:4")
    end

    @test_throws ArgumentError DB.parse_machine_token("0*host")
    @test_throws ArgumentError DB.parse_machine_token("h\nname")
end
