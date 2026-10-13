using Test

@testset "status" begin
    st = """
    Default  Channel  Version
    -------------------------------------------------------------------------
         *  1.13     1.13.2+0.aarch64.apple.darwin14
          1.12     1.12.7+0.aarch64.apple.darwin14
    """
    @test DistSSHUp._juliaup_default_channel_from_status(st) == "1.13"
    @test DistSSHUp._juliaup_default_channel_from_status("no default here") === nothing
    @test DistSSHUp._juliaup_patch_from_status("     *  1.13     1.13.2+0.aarch64.apple.darwin14") ==
        "1.13.2"
    @test DistSSHUp._juliaup_patch_from_status("* 1.13") == "-"
    @test DistSSHUp._juliaup_patch_from_status("* release  1.11.6+0.x86_64") == "1.11.6"
    @test DistSSHUp._juliaup_patch_from_status("") == "-"
    rows = DistSSHUp._installed_status_lines(st)
    @test length(rows) == 2
    only = DistSSHUp._installed_status_lines(st; channel = "1.12")
    @test length(only) == 1
    @test occursin("1.12", only[1])
    @test isempty(DistSSHUp._installed_status_lines(st; channel = "nightly"))
    sh = DistSSHUp._juliaup_status_sh()
    @test occursin("status", sh)
    @test occursin(raw"$HOME/.juliaup/bin/juliaup", sh)
end
