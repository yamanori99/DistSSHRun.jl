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
        "DISTSSH_QUIET" => nothing,
        "DISTSSH_PROGRESS" => nothing,
        "DISTSSH_VERBOSE" => nothing,
    )

    @testset "peel flags" begin
        withenv(clear_verbosity_env..., "DISTSSH_YES" => nothing) do
            let (session, rest) = DistSSHRun.peel_shared_cli_flags(["--quiet", "--yes", "child:host1", "s.jl"])
                @test session.quiet
                @test session.verbosity === :quiet
                @test session.yes
                @test rest == ["child:host1", "s.jl"]
            end

            let (session, rest) = DistSSHRun.peel_shared_cli_flags(["--verbose", "child:host1"])
                @test session.verbosity === :verbose
                @test !session.quiet
                @test rest == ["child:host1"]
            end

            let (session, rest) = DistSSHRun.peel_shared_cli_flags(["--hosts", "a:1, b", "s.jl"])
                @test session.hosts_flag == ["a:1", "b"]
                @test rest == ["s.jl"]
            end

            for flag in ("--version", "-v", "-V")
                let (session, rest) = DistSSHRun.peel_shared_cli_flags([flag])
                    @test session.show_version
                    @test rest == String[]
                end
            end
        end
    end

    @testset "quiet vs progress exclusivity" begin
        withenv(clear_verbosity_env...) do
            @test_throws ArgumentError DistSSHRun.peel_shared_cli_flags(["-q", "--progress"])
            @test_throws ArgumentError DistSSHRun.peel_shared_cli_flags(["--progress", "--quiet"])
            @test_throws ArgumentError DistSSHRun.peel_shared_cli_flags(["--progress", "--verbose"])
            @test_throws ArgumentError DistSSHRun.peel_shared_cli_flags(["--verbose", "-q"])
            @test_throws ArgumentError DistSSHRun.CliSharedFlags(quiet = true, verbosity = :progress)
        end
        withenv("DISTSSH_QUIET" => "1", "DISTSSH_PROGRESS" => "1") do
            @test_throws ArgumentError DistSSHRun.default_kit_cli_session()
        end
        withenv("DISTSSH_VERBOSE" => "1", "DISTSSH_PROGRESS" => "1", "DISTSSH_QUIET" => nothing) do
            @test_throws ArgumentError DistSSHRun.default_kit_cli_session()
        end
    end

    @testset "ENV defaults" begin
        withenv("DISTSSH_QUIET" => "1", "DISTSSH_YES" => "true", "DISTSSH_PROGRESS" => nothing, "DISTSSH_VERBOSE" => nothing) do
            session = DistSSHRun.default_kit_cli_session()
            @test session.quiet
            @test session.verbosity === :quiet
            @test session.yes
        end
        withenv("DISTSSH_QUIET" => nothing, "DISTSSH_PROGRESS" => "1", "DISTSSH_VERBOSE" => nothing, "DISTSSH_YES" => nothing) do
            session = DistSSHRun.default_kit_cli_session()
            @test session.verbosity === :progress
            @test !session.quiet
            @test !session.yes
        end
        withenv("DISTSSH_QUIET" => nothing, "DISTSSH_PROGRESS" => nothing, "DISTSSH_VERBOSE" => "1", "DISTSSH_YES" => nothing) do
            session = DistSSHRun.default_kit_cli_session()
            @test session.verbosity === :verbose
            @test !session.quiet
        end
        @test DistSSHRun.kit_cli_auto_verbosity(; live = true) === :progress
        @test DistSSHRun.kit_cli_auto_verbosity(; live = false) === :verbose
    end

    @testset "apply_shared_cli_flags!" begin
        withenv(clear_verbosity_env..., "DISTSSH_YES" => nothing) do
            prev = DistSSHRun.kit_verbosity()
            prev_ni = DistSSHRun.kit_noninteractive()
            try
                DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags(yes = true))
                @test DistSSHRun.kit_confirm("ignored")

                DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags(verbosity = :progress))
                @test DistSSHRun.kit_verbosity() === :progress
                @test DistSSHRun.kit_output_progress()
                @test !DistSSHRun.kit_output_detail()
                @test !DistSSHRun.kit_output_quiet()

                DistSSHRun.apply_shared_cli_flags!(DistSSHRun.CliSharedFlags(verbosity = :verbose))
                @test DistSSHRun.kit_verbosity() === :verbose
                @test DistSSHRun.kit_output_detail()
            finally
                DistSSHRun.set_kit_verbosity!(prev)
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end
    end

    @testset "kit_confirm stdin" begin
        withenv("DISTSSH_YES" => nothing) do
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
        @test occursin("DISTSSH_PROGRESS", DistSSHRun.KIT_PROGRESS_ENV_HELP)
        @test occursin("DISTSSH_VERBOSE", DistSSHRun.KIT_VERBOSE_ENV_HELP)
        @test occursin("--hosts", DistSSHRun.KIT_HOSTS_FLAG_HELP)
        @test occursin("DISTSSH_HOSTS", DistSSHRun.KIT_HOSTS_ENV_HELP)
        @test occursin("DISTSSH_SKIP_GLOBAL_WORKER_PKILL", DistSSHRun.KIT_SKIP_PKILL_ENV_HELP)
        @test occursin("DISTSSH_JOBS", DistSSHRun.KIT_JOBS_ENV_HELP)
        @test occursin("DISTSSH_REQUIRE_ALL_HOSTS", DistSSHRun.KIT_REQUIRE_ALL_HOSTS_ENV_HELP)
    end

    @testset "kit_host_jobs" begin
        withenv("DISTSSH_JOBS" => nothing) do
            @test DistSSHRun.kit_host_jobs() == 1
        end
        withenv("DISTSSH_JOBS" => "4") do
            @test DistSSHRun.kit_host_jobs() == 4
        end
        withenv("DISTSSH_JOBS" => "0") do
            @test DistSSHRun.kit_host_jobs() == 1
        end
        withenv("DISTSSH_JOBS" => "nope") do
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

        withenv("DISTSSH_HOSTS" => "child:env-a:2, child:env-b", "DISTSSH_HOSTS_FILE" => nothing) do
            session = DistSSHRun.CliSharedFlags(hosts_flag = ["parent:3"], hosts_file = hosts_file)
            @test DistSSHRun.placement_source_tokens(session; keep_counts = true) ==
                ["parent:3", "child:env-a:2", "child:env-b", "child:host-a:1", "child:host-b:4"]
            @test DistSSHRun.placement_source_tokens(session; keep_counts = false, roles = true) ==
                ["parent", "env-a", "env-b", "host-a", "host-b"]
        end
    end
end
