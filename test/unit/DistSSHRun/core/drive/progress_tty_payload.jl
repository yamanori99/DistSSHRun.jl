using Test

# Discriminate kit payload from host warnings that happen to contain `'!'`.

@testset "tty progress payload markers" begin
    mem = "  ⠋  workers         ━━━━━━━╺━━━━━━━━━━━━  3/7  0:00WARNING: Memory pressure detected!"
    host_bang = "WARNING: something went wrong!"
    kit_warn = "  ! host1: ssh slow"
    glued_kit = "  ⠋  workers         ━━━━━━━╺━━━━━━━━━━━━  3/7  0:00  ! host1: ssh slow"
    boom = "ERROR: DISTSSH_RUNNER_BOOM"
    smoke = "DISTSSH_RUNNER_SMOKE_OK nw=2"
    ride_ok = "DISTSSH_RIDE_REMOTE_OK"
    ride_boom = "DISTSSH_RIDE_REMOTE_BOOM"

    @test !_tty_payload_line(mem)
    @test _tty_bar_line(mem)
    @test !_tty_payload_line(host_bang)
    @test _tty_payload_line(kit_warn)
    @test _tty_fail_or_warn_line(kit_warn)
    @test _tty_payload_line(glued_kit)
    @test _tty_bar_line(glued_kit)
    @test _tty_payload_line(boom)
    @test _tty_payload_line(smoke)
    @test _tty_payload_line(ride_ok)
    @test _tty_payload_line(ride_boom)
    @test !_tty_bar_line(ride_ok)
    @test !_tty_bar_line(ride_boom)

    # Host `'!'` glued onto a live bar is not a payload line; cursor-up after
    # that `'!'` must not be treated as a post-payload redraw.
    mem_raw = mem * "\n\e[1A" * mem * "\n" * smoke * "\n"
    _assert_tty_progress_payload(mem_raw)

    # Kit warn on a spinner bar is still the glue case `_assert` rejects.
    @test _tty_payload_line(glued_kit) && _tty_bar_line(glued_kit)

    # `@test` count is fixed: extra redraw / payload lines must not add cases.
    bar = "  ⠋  workers         ━━━━━━━╺━━━━━━━━━━━━  3/7  0:00"
    short = kit_warn * "\n" * smoke * "\n"
    many = join(fill(bar, 40), "\r") * "\n" * kit_warn * "\n" * smoke * "\n" *
        join(fill(bar, 40), "\r") * "\n"
    ts_short = @testset "assert count short" begin
        _assert_tty_progress_payload(short)
    end
    ts_many = @testset "assert count many redraws" begin
        _assert_tty_progress_payload(many)
    end
    @test ts_short.n_passed == 3
    @test ts_many.n_passed == ts_short.n_passed
    ts_hosts = @testset "assert count hosts" begin
        fail = "  ✗ host1: boom\n  ✗ host2: boom\n" * smoke * "\n"
        _assert_tty_progress_payload(fail; hosts = ["host1", "host2"])
    end
    @test ts_hosts.n_passed == 4
end
