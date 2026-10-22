using Test

@testset "version" begin
    @test DistSSHUp.julia_version_mismatch_kind(v"1.12.6", v"1.12.6") == :none
    @test DistSSHUp.julia_version_mismatch_kind(v"1.12.6", v"1.12.9") == :patch
    @test DistSSHUp.julia_version_mismatch_kind(v"1.12.6", v"1.11.6") == :minor
    @test DistSSHUp.julia_version_mismatch_kind(v"1.12.6", v"2.0.6") == :minor
    @test DistSSHUp.julia_version_mismatch_kind(VERSION, VersionNumber(VERSION.major, VERSION.minor + 1, 0)) ==
        :minor

    @test DistSSHUp.juliaup_channel(v"1.12.6") == "1.12"
    @test DistSSHUp.juliaup_channel(v"1.14.0-DEV") == "1.14-nightly"
    @test DistSSHUp.juliaup_channel(v"1.14.0-DEV.3787") == "1.14-nightly"
    @test DistSSHUp.juliaup_channel(v"1.13.0-rc1") == "1.13.0-rc1"
    @test DistSSHUp.juliaup_channel(v"1.13.0-alpha2") == "1.13.0-alpha2"
    @test DistSSHUp.juliaup_channel(v"1.13.0-beta1") == "1.13.0-beta1"
    if isempty(VERSION.prerelease)
        @test DistSSHUp.juliaup_channel(VERSION) == "$(VERSION.major).$(VERSION.minor)"
    elseif String(first(VERSION.prerelease)) == "DEV"
        @test DistSSHUp.juliaup_channel(VERSION) == "$(VERSION.major).$(VERSION.minor)-nightly"
    end

    @test DistSSHUp.julia_version_mismatch_kind(v"1.13.2+0.aarch64", v"1.13.2") == :none
    @test DistSSHUp.julia_version_mismatch_kind(v"1.14.0-alpha1", v"1.14.0-alpha1") == :none
    @test DistSSHUp.julia_version_mismatch_kind(v"1.14.0-alpha1", v"1.14.0") == :prerelease
    @test DistSSHUp.julia_version_mismatch_kind(v"1.14.0-alpha1", v"1.14.0-alpha2") == :prerelease

    @test DistSSHUp.juliaup_parent_behind_channel(v"1.12.6", v"1.12.9")
    @test !DistSSHUp.juliaup_parent_behind_channel(v"1.12.9", v"1.12.6")
    @test !DistSSHUp.juliaup_parent_behind_channel(v"1.12.6", v"1.12.6")
    @test !DistSSHUp.juliaup_parent_behind_channel(v"1.12.6", v"1.11.9")
    @test !DistSSHUp.juliaup_parent_behind_channel(v"1.14.0-alpha1", v"1.14.0-alpha1")
    @test !DistSSHUp.juliaup_parent_behind_channel(v"1.14.0", v"1.14.0-alpha1")
    @test !DistSSHUp.juliaup_parent_behind_channel(v"1.13.2+0.aarch64", v"1.13.2")
    @test DistSSHUp.juliaup_parent_behind_channel(v"1.14.0-alpha1", v"1.14.0")

    @test DistSSHUp._juliaup_version("Juliaup 1.22.7\n") == v"1.22.7"
    @test DistSSHUp._juliaup_version("juliaup 1.22.7") === nothing
    @test_throws ErrorException DistSSHUp._reject_old_juliaup(v"1.21.0", "Juliaup 1.21.0")
    @test DistSSHUp._reject_old_juliaup(v"1.22.0", "Juliaup 1.22.0") === nothing
    @test_throws ErrorException DistSSHUp._reject_old_juliaup(nothing, "nope")
end
