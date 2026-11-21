using Test
using DistSSHBase

@testset "record_writer" begin
    @test DistSSHBase.record_writer_string("DistSSHRun", v"0.2.0-DEV") == "DistSSHRun 0.2.0-DEV"
    @test DistSSHBase.parse_record_writer("DistSSHShip 1.0.1") == ("DistSSHShip", "1.0.1")
    @test DistSSHBase.parse_record_writer("nopkg") === nothing
    @test DistSSHBase.parse_record_writer("DistSSHRun") === nothing

    @test DistSSHBase.record_writer_minor_match(
        "DistSSHRun 0.2.1",
        "DistSSHRun",
        v"0.2.0-DEV",
    ) == :ok
    @test DistSSHBase.record_writer_minor_match(
        "DistSSHRun 0.1.0",
        "DistSSHRun",
        v"0.2.0-DEV",
    ) == DistSSHBase.RecordWriterMismatchKind.minor
    @test DistSSHBase.record_writer_minor_match(
        "Other 0.2.0",
        "DistSSHRun",
        v"0.2.0-DEV",
    ) == DistSSHBase.RecordWriterMismatchKind.package
    @test DistSSHBase.record_writer_minor_match(
        nothing,
        "DistSSHRun",
        v"0.2.0-DEV",
    ) == DistSSHBase.RecordWriterMismatchKind.missing

    ere = DistSSHBase.record_writer_toml_line_ere("DistSSHRun", v"0.2.0-DEV")
    @test occursin("^writer = \"DistSSHRun 0\\.2", ere)
end