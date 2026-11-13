using Test

@testset "help chrome" begin
    @test DistSSHBase._help_section_line("Usage:")
    @test !DistSSHBase._help_section_line("  indented:")
    @test !DistSSHBase._help_section_line("# comment:")
    txt = sprint(
        io -> DistSSHBase.print_help_document(
            "DistSSHBase test",
            "Usage:\n  cmd --help\n";
            io = io,
        )
    )
    @test occursin("DistSSHBase test", txt)
    @test occursin("cmd --help", txt)
end
