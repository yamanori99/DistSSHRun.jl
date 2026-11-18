using Test

@testset "machine placement tokens" begin
    DB = DistSSHBase
    @testset "format parse roundtrip" begin
        cases = (
            ("host", 1, nothing),
            ("4*host", 4, nothing),
            ("user@host:2222", 1, 2222),
            ("4*user@host:2222", 4, 2222),
            ("[::1]", 1, nothing),
            ("2*[fe80::1]:2222", 2, 2222),
            ("2*alice@[::1]:2222", 2, 2222),
        )
        tok = DB.format_machine_token(2, "alice@[::1]"; port = 2222)
        @test tok == "2*alice@[::1]:2222"
        @test DB.parse_machine_token(tok) == DB.MachinePlacement(2, "alice@[::1]", 2222)
        for (tok, w, port) in cases
            p = DB.parse_machine_token(tok)
            @test p.workers == w
            port === nothing ? (@test p.port === nothing) : (@test p.port == port)
            @test DB.parse_machine_token(DB.format_machine_token(p)) == p
        end
    end

    @testset "legacy migration errors" begin
        @test_throws ArgumentError DB.parse_machine_token("parent:2")
        @test_throws ArgumentError DB.parse_machine_token("child:host-a:4")
    end

    @test_throws ArgumentError DB.parse_machine_token("0*host")
    @test_throws ArgumentError DB.parse_machine_token("h\nname")
end
