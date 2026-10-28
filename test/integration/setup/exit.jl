using Test

# Oracle: kit `setup` CLI in a child julia — exit code and a message needle
# (1 sad + 1 happy per mode). Fake ssh/rsync only; not real OpenSSH.
# Module-level validate / op outcomes live under unit/DistSSHRun/setup/.
# Children run `_subprocess_width()` at a time. Each case still has its own
# process, temp host, and fake-ssh state directory.

@testset "setup CLI exit codes" begin
    remote = "~/dsk-setup-delete/App"
    state_dirs = String[]
    function fresh_state()
        d = abspath(string(mktempdir()))
        push!(state_dirs, d)
        return d
    end
    calls = [
        (; setup_args = ["--delete", "parent"]),
        (; setup_args = ["--delete", "host1"]),
        (;
            setup_args = ["--delete", "--remote-path", remote, "child:host1"],
            extra_env = _fake_setup_remote_env(fresh_state()),
        ),
        (;
            setup_args = [
                "--delete", "--remote-path", remote, "--confirm-path", "/not/the/path",
                "child:host1",
            ],
            extra_env = _fake_setup_remote_env(fresh_state()),
        ),
        (;
            setup_args = [
                "--delete", "--yes", "--remote-path", remote,
                "--confirm-path", remote, "child:host1",
            ],
            extra_env = merge(
                _fake_setup_remote_env(fresh_state()),
                Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"),
            ),
        ),
        (;
            setup_args = [
                "--delete", "--remote-path", remote, "--confirm-path", remote,
                "child:host1", "child:host2",
            ],
            extra_env = _fake_setup_remote_env(fresh_state()),
        ),
        (;
            setup_args = ["--ship-tree", "child:host1"],
            extra_env = merge(
                _fake_setup_remote_env(fresh_state()),
                Dict("DISTSSHKIT_TEST_MKDIR_FAIL" => "1"),
            ),
        ),
        (;
            setup_args = ["--ship-tree", "child:host1", "child:host2"],
            extra_env = _fake_setup_remote_env(fresh_state()),
        ),
        # `--julia` skips remote detect; fake ssh still sees `Pkg.test()`.
        (;
            setup_args = ["--runtest", "--julia", "/bin/echo", "child:host1"],
            extra_env = merge(
                _fake_setup_remote_env(fresh_state()),
                Dict("DISTSSHKIT_TEST_PKG_TEST_FAIL" => "1"),
            ),
        ),
        (;
            setup_args = ["--runtest", "--julia", "/bin/echo", "child:host1", "child:host2"],
            extra_env = _fake_setup_remote_env(fresh_state()),
        ),
        (;
            setup_args = ["--juliaup-update", "child:host1"],
            extra_env = merge(
                _fake_setup_remote_env(fresh_state()),
                Dict("DISTSSHKIT_TEST_NO_JULIAUP" => "1"),
            ),
        ),
        (;
            setup_args = ["--juliaup-update", "child:host1", "child:host2"],
            extra_env = _fake_setup_remote_env(fresh_state()),
        ),
    ]
    try
        got = _run_kit_setups(calls)

        @testset "host validation wiring" begin
            proc, combined = got[1]
            @test proc.exitcode == 1
            @test occursin("only for up", combined)
            proc2, combined2 = got[2]
            @test proc2.exitcode == 1
            @test occursin("child:NAME", combined2) || occursin("parent[:N]", combined2)
        end

        @testset "delete" begin
            proc, combined = got[3]
            @test proc.exitcode == 1
            @test occursin("do not authorize", combined)
            @test occursin("--confirm-path", combined)
            @test occursin("help setup", combined)
            @test !occursin("--help", combined)
            @test !occursin("Delete complete", combined)
            @test !occursin("Would remove", combined)

            proc, combined = got[4]
            @test proc.exitcode == 1
            @test occursin("does not match", combined)
            @test occursin("help setup", combined)
            @test !occursin("--help", combined)
            @test !occursin("SSH preflight failed", combined)

            proc, combined = got[5]
            @test proc.exitcode == 1
            @test occursin("SSH preflight failed", combined)
            @test !occursin("do not authorize", combined)

            proc, combined = got[6]
            @test proc.exitcode == 0
            @test occursin("Delete complete (2 host(s))", combined)
        end

        @testset "ship-tree" begin
            proc, combined = got[7]
            @test proc.exitcode == 1
            @test occursin("ship-tree did not succeed on any host", combined)

            proc, combined = got[8]
            @test proc.exitcode == 0
            @test occursin("ship-tree complete (2 host(s))", combined)
        end

        @testset "runtest" begin
            proc, combined = got[9]
            @test proc.exitcode == 1
            @test occursin("Pkg.test did not succeed on any host", combined)

            proc, combined = got[10]
            @test proc.exitcode == 0
            @test occursin("Pkg.test complete (2 host(s))", combined)
        end

        @testset "juliaup-update" begin
            proc, combined = got[11]
            @test proc.exitcode == 1
            @test occursin("deprecated", combined)
            @test occursin("juliaup update did not succeed on any host", combined)

            proc, combined = got[12]
            @test proc.exitcode == 0
            @test occursin("deprecated", combined)
            @test occursin("juliaup update complete (2 host(s))", combined)
        end
    finally
        for d in state_dirs
            _rm_tempdir!(d)
        end
    end
end
