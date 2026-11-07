using Test

# Discriminate kit payload from host warnings that happen to contain `'!'`.

@testset "tty progress payload markers" begin
    mem = "  ⠋  workers         ━━━━━━━╺━━━━━━━━━━━━  3/7  0:00WARNING: Memory pressure detected!"
    host_bang = "WARNING: something went wrong!"
    kit_warn = "  ! host1: ssh slow"
    glued_kit = "  ⠋  workers         ━━━━━━━╺━━━━━━━━━━━━  3/7  0:00  ! host1: ssh slow"
    boom = "ERROR: DISTSSHKIT_RUNNER_BOOM"
    smoke = "DISTSSHKIT_RUNNER_SMOKE_OK nw=2"

    @test !_tty_payload_line(mem)
    @test _tty_bar_line(mem)
    @test !_tty_payload_line(host_bang)
    @test _tty_payload_line(kit_warn)
    @test _tty_fail_or_warn_line(kit_warn)
    @test _tty_payload_line(glued_kit)
    @test _tty_bar_line(glued_kit)
    @test _tty_payload_line(boom)
    @test _tty_payload_line(smoke)

    # Host `'!'` glued onto a live bar is not a payload line; cursor-up after
    # that `'!'` must not be treated as a post-payload redraw.
    mem_raw = mem * "\n\e[1A" * mem * "\n" * smoke * "\n"
    _assert_tty_progress_payload(mem_raw)

    # Kit warn on a spinner bar is still the glue case `_assert` rejects.
    @test _tty_payload_line(glued_kit) && _tty_bar_line(glued_kit)
end
