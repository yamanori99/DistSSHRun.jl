using Test

# File scope: a local inside `@testset` is captured by the verbosity `do` and boxed.
function _confirm_stdio(answer; keyword = nothing)
    return _capture_stdio() do stdin_io, _
        write(stdin_io, answer)
        flush(stdin_io)
        seekstart(stdin_io)
        DistSSHRun.kit_confirm("really wipe?"; keyword = keyword)
    end
end

@testset "cli_session" begin
    clear_verbosity_env = (
        "DISTSSHKIT_QUIET" => nothing,
        "DISTSSHKIT_PROGRESS" => nothing,
        "DISTSSHKIT_VERBOSE" => nothing,
    )

    @testset "peel flags" begin
        withenv(clear_verbosity_env..., "DISTSSHKIT_YES" => nothing) do
            let (session, rest) = DistSSHRun.peel_kit_cli_flags(["--quiet", "--yes", "child:host1", "s.jl"])
                @test session.quiet
                @test session.verbosity === :quiet
                @test session.yes
                @test rest == ["child:host1", "s.jl"]
            end

            let (session, rest) = DistSSHRun.peel_kit_cli_flags(["--verbose", "child:host1"])
                @test session.verbosity === :verbose
                @test !session.quiet
                @test rest == ["child:host1"]
            end

            let (session, rest) = DistSSHRun.peel_kit_cli_flags(["--hosts", "a:1, b", "s.jl"])
                @test session.hosts_flag == ["a:1", "b"]
                @test rest == ["s.jl"]
            end

            for flag in ("--version", "-v", "-V")
                let (session, rest) = DistSSHRun.peel_kit_cli_flags([flag])
                    @test session.show_version
                    @test rest == String[]
                end
            end
        end
    end

    @testset "quiet vs progress exclusivity" begin
        withenv(clear_verbosity_env...) do
            @test_throws ArgumentError DistSSHRun.peel_kit_cli_flags(["-q", "--progress"])
            @test_throws ArgumentError DistSSHRun.peel_kit_cli_flags(["--progress", "--quiet"])
            @test_throws ArgumentError DistSSHRun.peel_kit_cli_flags(["--progress", "--verbose"])
            @test_throws ArgumentError DistSSHRun.peel_kit_cli_flags(["--verbose", "-q"])
            @test_throws ArgumentError DistSSHRun.KitCliSession(quiet = true, verbosity = :progress)
        end
        withenv("DISTSSHKIT_QUIET" => "1", "DISTSSHKIT_PROGRESS" => "1") do
            @test_throws ArgumentError DistSSHRun.default_kit_cli_session()
        end
        withenv("DISTSSHKIT_VERBOSE" => "1", "DISTSSHKIT_PROGRESS" => "1", "DISTSSHKIT_QUIET" => nothing) do
            @test_throws ArgumentError DistSSHRun.default_kit_cli_session()
        end
    end

    @testset "ENV defaults" begin
        withenv("DISTSSHKIT_QUIET" => "1", "DISTSSHKIT_YES" => "true", "DISTSSHKIT_PROGRESS" => nothing, "DISTSSHKIT_VERBOSE" => nothing) do
            session = DistSSHRun.default_kit_cli_session()
            @test session.quiet
            @test session.verbosity === :quiet
            @test session.yes
        end
        withenv("DISTSSHKIT_QUIET" => nothing, "DISTSSHKIT_PROGRESS" => "1", "DISTSSHKIT_VERBOSE" => nothing, "DISTSSHKIT_YES" => nothing) do
            session = DistSSHRun.default_kit_cli_session()
            @test session.verbosity === :progress
            @test !session.quiet
            @test !session.yes
        end
        withenv("DISTSSHKIT_QUIET" => nothing, "DISTSSHKIT_PROGRESS" => nothing, "DISTSSHKIT_VERBOSE" => "1", "DISTSSHKIT_YES" => nothing) do
            session = DistSSHRun.default_kit_cli_session()
            @test session.verbosity === :verbose
            @test !session.quiet
        end
        @test DistSSHRun.kit_cli_auto_verbosity(; live = true) === :progress
        @test DistSSHRun.kit_cli_auto_verbosity(; live = false) === :verbose
    end

    @testset "apply_kit_cli_session!" begin
        withenv(clear_verbosity_env..., "DISTSSHKIT_YES" => nothing) do
            prev = DistSSHRun.kit_verbosity()
            prev_ni = DistSSHRun.kit_noninteractive()
            try
                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(yes = true))
                @test DistSSHRun.kit_confirm("ignored")

                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(verbosity = :progress))
                @test DistSSHRun.kit_verbosity() === :progress
                @test DistSSHRun.kit_output_progress()
                @test !DistSSHRun.kit_output_detail()
                @test !DistSSHRun.kit_output_quiet()

                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(verbosity = :verbose))
                @test DistSSHRun.kit_verbosity() === :verbose
                @test DistSSHRun.kit_output_detail()
            finally
                DistSSHRun.set_kit_verbosity!(prev)
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end
    end

    @testset "kit_confirm stdin" begin
        withenv("DISTSSHKIT_YES" => nothing) do
            prev_ni = DistSSHRun.kit_noninteractive()
            DistSSHRun.set_kit_noninteractive!(false)
            try
                # Prompt must show in every verbosity (TTY default is :progress).
                for v in (:quiet, :progress, :verbose)
                    with_kit_verbosity(v) do
                        out, ok = _confirm_stdio("n\n")
                        @test !ok
                        @test occursin("really wipe?", out)
                        _, ok = _confirm_stdio("y\n")
                        @test ok
                        _, ok = _confirm_stdio("DELETE\n"; keyword = "DELETE")
                        @test ok
                        _, ok = _confirm_stdio("nope\n"; keyword = "DELETE")
                        @test !ok
                    end
                end
            finally
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end
    end

    @testset "shared help constants" begin
        @test occursin("--progress", DistSSHRun.KIT_PROGRESS_FLAG_HELP)
        @test occursin("TTY default", DistSSHRun.KIT_PROGRESS_FLAG_HELP)
        @test occursin("--verbose", DistSSHRun.KIT_VERBOSE_FLAG_HELP)
        @test occursin("DISTSSHKIT_PROGRESS", DistSSHRun.KIT_PROGRESS_ENV_HELP)
        @test occursin("DISTSSHKIT_VERBOSE", DistSSHRun.KIT_VERBOSE_ENV_HELP)
        @test occursin("--hosts", DistSSHRun.KIT_HOSTS_FLAG_HELP)
        @test occursin("DISTSSHKIT_HOSTS", DistSSHRun.KIT_HOSTS_ENV_HELP)
        @test occursin("DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL", DistSSHRun.KIT_SKIP_PKILL_ENV_HELP)
        @test occursin("DISTSSHKIT_JOBS", DistSSHRun.KIT_JOBS_ENV_HELP)
        @test occursin("DISTSSHKIT_REQUIRE_ALL_HOSTS", DistSSHRun.KIT_REQUIRE_ALL_HOSTS_ENV_HELP)
    end

    @testset "kit_host_jobs" begin
        withenv("DISTSSHKIT_JOBS" => nothing) do
            @test DistSSHRun.kit_host_jobs() == 1
        end
        withenv("DISTSSHKIT_JOBS" => "4") do
            @test DistSSHRun.kit_host_jobs() == 4
        end
        withenv("DISTSSHKIT_JOBS" => "0") do
            @test DistSSHRun.kit_host_jobs() == 1
        end
        withenv("DISTSSHKIT_JOBS" => "nope") do
            @test DistSSHRun.kit_host_jobs() == 1
        end
        seen = Int[]
        DistSSHRun.map_host_jobs(["a", "b"]) do i, host
            push!(seen, i)
            @test host == ["a", "b"][i]
        end
        @test sort(seen) == [1, 2]
    end

    @testset "hosts file" begin
        hosts_file = _sample_hosts_file()
        let lines = DistSSHRun.read_hosts_file_lines(hosts_file)
            slots = DistSSHRun._go_plan_slots(lines)
            @test length(slots) == 5  # host-a + host-b:4
            @test count(s -> s.host == "host-b", slots) == 4
        end

        withenv("DISTSSHKIT_HOSTS" => "child:env-a:2, child:env-b", "DISTSSHKIT_HOSTS_FILE" => nothing) do
            session = DistSSHRun.KitCliSession(hosts_flag = ["parent:3"], hosts_file = hosts_file)
            @test DistSSHRun.kit_host_source_tokens(session; keep_counts = true) ==
                ["parent:3", "child:env-a:2", "child:env-b", "child:host-a:1", "child:host-b:4"]
            @test DistSSHRun.kit_host_source_tokens(session; keep_counts = false, roles = true) ==
                ["parent", "env-a", "env-b", "host-a", "host-b"]
        end
    end
end
