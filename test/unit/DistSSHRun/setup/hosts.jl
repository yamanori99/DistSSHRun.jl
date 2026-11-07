using Test

# Module setup hosts — validate + op return values (CLI exit codes live in integration/setup/exit.jl).

@testset "setup hosts safety" begin
    function _with_fake_remotes(f::Function; extra_env = Dict{String, String}())
        _with_tempdir() do state_dir
            withenv(merge(_fake_setup_remote_env(state_dir), extra_env)...) do
                _apply_quiet_setup_session!()
                return f(state_dir)
            end
        end
    end

    @testset "validate_setup_hosts" begin
        # Representative refusals; DistSSHRun/hosts.jl covers the underlying predicates.
        @test_throws ArgumentError DistSSHRun.validate_setup_hosts(String[])
        @test_throws ArgumentError DistSSHRun.validate_setup_hosts(["parent"])
        @test DistSSHRun.validate_setup_hosts(["parent"]; allow_parent = true) === nothing
        @test DistSSHRun.validate_setup_hosts(["parent", "host-a"]; allow_parent = true) === nothing
        @test DistSSHRun.setup_mode_allows_parent(:juliaup)
        @test DistSSHRun.setup_mode_allows_parent(:juliaup_update)
        @test !DistSSHRun.setup_mode_allows_parent(:check)
        @test DistSSHRun.setup_juliaup_ssh_hosts(["parent"]) == String[]
        @test DistSSHRun.validate_setup_hosts(["local"]) === nothing
        @test_throws ArgumentError DistSSHRun.validate_setup_hosts(["demos/foo.jl"])
        @test DistSSHRun.validate_setup_hosts(["root@192.0.2.10", "host-b"]) === nothing
        @test_throws ArgumentError DistSSHRun.validate_setup_hosts(["-bad"])
        @test_throws ArgumentError DistSSHRun.validate_setup_hosts(["user@-h"])
        @test_throws ArgumentError DistSSHRun.validate_setup_hosts(["host\nname"])
        @test DistSSHRun.setup_cli_host_token("host-a") == "child:host-a"
        @test DistSSHRun.setup_cli_host_token("parent") == "parent"
    end

    @testset "finish_host_op!" begin
        _apply_quiet_setup_session!()
        @test DistSSHRun.finish_host_op!(
            "X",
            (; cancelled = true, succeeded = 0, failed = 0),
        )
        out, ok = _capture_stdio() do _, _
            DistSSHRun.finish_host_op!(
                "Pkg.test",
                (; cancelled = false, succeeded = 0, failed = 2),
            )
        end
        @test !ok
        @test occursin("Pkg.test did not succeed on any host", out)
        out2, ok2 = _capture_stdio() do _, _
            DistSSHRun.finish_host_op!(
                "Pkg.test",
                (; cancelled = false, succeeded = 1, failed = 1),
            )
        end
        @test !ok2
        @test occursin("failed on 1 host", out2)
        _, ok3 = _capture_stdio() do _, _
            DistSSHRun.finish_host_op!(
                "Pkg.test",
                (; cancelled = false, succeeded = 2, failed = 0),
            )
        end
        @test ok3
    end

    @testset "probe / preflight" begin
        _with_fake_remotes() do _
            @test DistSSHRun.probe_setup_ssh("host1") === nothing
            @test DistSSHRun.preflight_setup_ssh(["host1", "host2"])
        end
        _with_fake_remotes(extra_env = Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1")) do _
            @test DistSSHRun.probe_setup_ssh("host1") isa String
            @test DistSSHRun.preflight_setup_ssh(["host1"]) == false
        end
    end

    @testset "preflight kit log has one host prefix" begin
        function _result_lines(body::AbstractString)
            return filter(
                l -> startswith(l, "  ") && occursin(r": [✓✗]", l),
                split(body, '\n'; keepempty = false),
            )
        end
        function _count_host_prefix(body::AbstractString, host::AbstractString)
            needle = "  $(host): "
            n = 0
            for line in split(body, '\n'; keepempty = false)
                @test count(needle, line) <= 1
                count(needle, line) == 1 && startswith(line, needle) && (n += 1)
            end
            return n
        end

        function _with_preflight_log(f; fail_hosts::Vector{String} = String[])
            return _with_tempdir() do tmp
                state_dir = joinpath(tmp, "state")
                mkpath(state_dir)
                ssh = joinpath(tmp, "ssh.jl")
                fail_lit = join(repr.(fail_hosts), ", ")
                write(
                    ssh,
                    """
                    host = length(ARGS) >= 1 ? ARGS[1] : ""
                    script = length(ARGS) >= 2 ? ARGS[2] : ""
                    if occursin("case x in x)", script)
                        m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
                        m === nothing || println(m.match)
                        exit(0)
                    end
                    if host in String[$fail_lit]
                        println(stderr, "Permission denied (publickey).")
                        exit(255)
                    end
                    if strip(script) == "echo ok" || strip(script) == "true"
                        println("ok")
                        exit(0)
                    end
                    if strip(script) == "echo \\\$SHELL"
                        println("/bin/sh")
                        exit(0)
                    end
                    println("ok")
                    """,
                )
                env = merge(
                    _fake_setup_remote_env(state_dir),
                    Dict("DISTSSHKIT_TEST_SSH" => ssh),
                )
                withenv(env...) do
                    return f(tmp)
                end
            end
        end

        # Open a kit log, run `body`, then close even when a test fails.
        # `body` is first so `do` syntax works (`with_kit_verbosity` same order).
        function _with_kit_log_handle(body, tmp::AbstractString, prefix::AbstractString)
            path = DistSSHRun.init_log_file(tmp; prefix = prefix)
            try
                body()
                return path
            finally
                DistSSHRun.close_log_file()
            end
        end

        @testset "quiet success and failure" begin
            _with_preflight_log() do tmp
                with_kit_verbosity(:quiet) do
                    out, log_path = _capture_stdio() do _, _
                        _with_kit_log_handle(tmp, "preflight_q_ok") do
                            @test DistSSHRun.preflight_setup_ssh(["host1", "host2"])
                        end
                    end
                    body = read(log_path, String)
                    @test !occursin("host1", out)
                    @test !occursin("host2", out)
                    @test !occursin("SSH preflight", out)
                    @test _count_host_prefix(body, "host1") == 1
                    @test _count_host_prefix(body, "host2") == 1
                    @test any(l -> startswith(l, "  host1: ✓"), _result_lines(body))
                    @test any(l -> startswith(l, "  host2: ✓"), _result_lines(body))
                end
            end
            _with_preflight_log(; fail_hosts = ["host1"]) do tmp
                with_kit_verbosity(:quiet) do
                    out, log_path = _capture_stdio() do _, _
                        _with_kit_log_handle(tmp, "preflight_q_fail") do
                            @test DistSSHRun.preflight_setup_ssh(["host1"]) == false
                        end
                    end
                    body = read(log_path, String)
                    @test !occursin("host1", out)
                    @test !occursin("✗", out)
                    @test _count_host_prefix(body, "host1") == 1
                    @test any(l -> startswith(l, "  host1: ✗"), _result_lines(body))
                end
            end
        end

        @testset "progress success and failure" begin
            _with_preflight_log() do tmp
                with_kit_verbosity(:progress) do
                    out, log_path = _capture_stdio() do _, _
                        _with_kit_log_handle(tmp, "preflight_p_ok") do
                            @test DistSSHRun.preflight_setup_ssh(["host1"])
                        end
                    end
                    body = read(log_path, String)
                    @test !occursin("host1: ✓", out)
                    @test _count_host_prefix(body, "host1") == 1
                    @test any(l -> startswith(l, "  host1: ✓"), _result_lines(body))
                end
            end
            _with_preflight_log(; fail_hosts = ["host1"]) do tmp
                with_kit_verbosity(:progress) do
                    out, log_path = _capture_stdio() do _, _
                        _with_kit_log_handle(tmp, "preflight_p_fail") do
                            @test DistSSHRun.preflight_setup_ssh(["host1"]) == false
                        end
                    end
                    body = read(log_path, String)
                    @test occursin("host1", out)
                    @test occursin("✗", out)
                    @test _count_host_prefix(body, "host1") == 1
                    @test any(l -> startswith(l, "  host1: ✗"), _result_lines(body))
                    @test count("  host1: ", out) == 1
                end
            end
        end

        @testset "verbose keeps heading form" begin
            _with_preflight_log() do tmp
                with_kit_verbosity(:verbose) do
                    out, log_path = _capture_stdio() do _, _
                        _with_kit_log_handle(tmp, "preflight_v_ok") do
                            @test DistSSHRun.preflight_setup_ssh(["host1"])
                        end
                    end
                    body = read(log_path, String)
                    @test occursin("SSH preflight:", out)
                    @test occursin("host1:", out)
                    @test occursin("✓", out)
                    @test _count_host_prefix(body, "host1") == 1
                    @test occursin("  host1: ✓", replace(body, '\r' => ""))
                end
            end
            _with_preflight_log(; fail_hosts = ["host1"]) do tmp
                with_kit_verbosity(:verbose) do
                    out, log_path = _capture_stdio() do _, _
                        _with_kit_log_handle(tmp, "preflight_v_fail") do
                            @test DistSSHRun.preflight_setup_ssh(["host1"]) == false
                        end
                    end
                    body = read(log_path, String)
                    @test occursin("host1:", out)
                    @test occursin("✗", out)
                    @test _count_host_prefix(body, "host1") == 1
                    @test occursin("  host1: ✗", replace(body, '\r' => ""))
                end
            end
        end

        @testset "mixed multi-host results" begin
            _with_preflight_log(; fail_hosts = ["host2"]) do tmp
                for v in (:quiet, :progress, :verbose)
                    with_kit_verbosity(v) do
                        out, log_path = _capture_stdio() do _, _
                            _with_kit_log_handle(tmp, "preflight_mix_$(v)") do
                                @test DistSSHRun.preflight_setup_ssh(["host1", "host2"]) == false
                            end
                        end
                        body = read(log_path, String)
                        @test _count_host_prefix(body, "host1") == 1
                        @test _count_host_prefix(body, "host2") == 1
                        lines = _result_lines(replace(body, '\r' => ""))
                        if v === :verbose
                            @test occursin("  host1: ✓", replace(body, '\r' => ""))
                            @test occursin("  host2: ✗", replace(body, '\r' => ""))
                        else
                            @test any(l -> startswith(l, "  host1: ✓"), lines)
                            @test any(l -> startswith(l, "  host2: ✗"), lines)
                        end
                        if v === :quiet
                            @test !occursin("host1", out)
                            @test !occursin("host2", out)
                        elseif v === :progress
                            @test occursin("host2", out)
                            @test occursin("✗", out)
                            @test !occursin("host1: ✓", out)
                            @test count("  host2: ", out) == 1
                        else
                            @test occursin("host1:", out)
                            @test occursin("host2:", out)
                        end
                    end
                end
            end
        end
    end

    @testset "delete_remotes" begin
        withenv("DISTSSHKIT_YES" => nothing) do
            prev_ni = DistSSHRun.kit_noninteractive()
            DistSSHRun.set_kit_noninteractive!(false)
            try
                for v in (:quiet, :progress, :verbose)
                    with_kit_verbosity(v) do
                        _with_active_kit_progress() do _
                            out, result, nsus = _capture_stdio(; probe_suspend = true) do stdin_io, _
                                println(stdin_io, "no")
                                flush(stdin_io)
                                seekstart(stdin_io)
                                DistSSHRun.delete_remotes(["host1"], "~/App.jl")
                            end
                            @test result.cancelled && result.succeeded == 0 && result.failed == 0
                            @test isempty(result.hosts)
                            @test occursin("Cancelled.", out)
                            @test occursin("DELETE", out)
                            @test occursin("Type 'delete'", out)
                            @test occursin("~/App.jl", out)
                            # #374: bar is suspended while stdin is read, then released.
                            @test nsus >= 1
                            @test DistSSHRun.KIT_PROGRESS_SUSPEND[] == 0
                        end
                    end
                end
            finally
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end

        _with_fake_remotes() do state_dir
            host = "host1"
            slot = replace(host, r"[@:/]" => "_")
            tree = joinpath(state_dir, slot, "tree")
            mkpath(tree)
            touch(joinpath(tree, "keepme.txt"))
            result = DistSSHRun.delete_remotes([host], "~/App.jl"; confirm = false)
            @test !result.cancelled && result.succeeded == 1 && result.failed == 0
            @test length(result.hosts) == 1 && result.hosts[1].ok
            @test !isdir(joinpath(state_dir, slot))
        end
    end

    @testset "clone_to_remotes" begin
        withenv("DISTSSHKIT_YES" => nothing) do
            prev_ni = DistSSHRun.kit_noninteractive()
            DistSSHRun.set_kit_noninteractive!(false)
            try
                for v in (:quiet, :progress, :verbose)
                    with_kit_verbosity(v) do
                        out, result = _capture_stdio() do stdin_io, _
                            println(stdin_io, "n")
                            flush(stdin_io)
                            seekstart(stdin_io)
                            DistSSHRun.clone_to_remotes(
                                ["host1"], "~/App.jl", "git@example.com:org/App.jl.git",
                            )
                        end
                        @test result.cancelled && result.succeeded == 0 && result.failed == 0
                        @test occursin("Cancelled.", out)
                        @test occursin("Safety:", out)
                        @test occursin("Proceed?", out)
                    end
                end
            finally
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end

        _with_fake_remotes() do _
            result = DistSSHRun.clone_to_remotes(
                ["host1"], "~/App.jl", "git@example.com:org/App.jl.git";
                confirm = false,
            )
            @test !result.cancelled && result.succeeded == 1 && result.failed == 0
            @test length(result.hosts) == 1 && result.hosts[1].ok
        end
        # Nonempty refuse: return value here; message text in setup/send_list.jl.
        # `_capture_stdio`: `print_err` ignores quiet, so otherwise a red ✗ leaks.
        _with_fake_remotes() do state_dir
            host = "host1"
            slot = replace(host, r"[@:/]" => "_")
            tree = joinpath(state_dir, slot, "tree")
            mkpath(tree)
            touch(joinpath(tree, "keepme.txt"))
            _, result = _capture_stdio() do _, _
                DistSSHRun.clone_to_remotes(
                    [host], "~/App.jl", "git@example.com:org/App.jl.git";
                    confirm = false,
                )
            end
            @test !result.cancelled && result.succeeded == 0 && result.failed == 1
            @test length(result.hosts) == 1 && !result.hosts[1].ok
        end

        _with_fake_remotes(; extra_env = Dict("DISTSSHKIT_TEST_PROJECT_MODE" => "drwxrwxr-x")) do state_dir
            host = "host1"
            slot = replace(host, r"[@:/]" => "_")
            tree = joinpath(state_dir, slot, "tree")
            mkpath(tree)
            _, result = _capture_stdio() do _, _
                DistSSHRun.clone_to_remotes(
                    [host], "~/App.jl", "git@example.com:org/App.jl.git";
                    confirm = false,
                )
            end
            @test !result.cancelled && result.succeeded == 0 && result.failed == 1
            @test occursin("group-writable", result.hosts[1].message)
            @test !isdir(joinpath(tree, ".git"))
        end
        _with_fake_remotes(; extra_env = Dict("DISTSSHKIT_TEST_PROJECT_MODE" => "drwxrwxrwx")) do state_dir
            host = "host1"
            slot = replace(host, r"[@:/]" => "_")
            tree = joinpath(state_dir, slot, "tree")
            _, result = _capture_stdio() do _, _
                DistSSHRun.clone_to_remotes(
                    [host], "~/App.jl", "git@example.com:org/App.jl.git";
                    confirm = false,
                )
            end
            @test result.failed == 1
            @test occursin("world-writable", result.hosts[1].message)
            @test !isdir(tree)
        end

        _with_fake_remotes(; extra_env = Dict("DISTSSHKIT_TEST_GIT_CLONE_FAIL" => "1")) do _
            result = DistSSHRun.clone_to_remotes(
                ["host1"], "~/App.jl", "git@example.com:org/App.jl.git";
                confirm = false,
            )
            @test result.failed == 1
            @test occursin("repository not found", result.hosts[1].message)
        end
    end

    @testset "prune_kit_leaves confirm abort" begin
        withenv("DISTSSHKIT_YES" => nothing) do
            prev_ni = DistSSHRun.kit_noninteractive()
            DistSSHRun.set_kit_noninteractive!(false)
            try
                _with_tempdir() do tmp
                    for v in (:quiet, :progress, :verbose)
                        with_kit_verbosity(v) do
                            _with_active_kit_progress() do _
                                out, result, nsus = _capture_stdio(; probe_suspend = true) do stdin_io, _
                                    println(stdin_io, "no")
                                    flush(stdin_io)
                                    seekstart(stdin_io)
                                    DistSSHRun.prune_kit_leaves(["host1"], "~/App.jl", tmp)
                                end
                                @test result.cancelled && result.succeeded == 0 && result.failed == 0
                                @test isempty(result.hosts)
                                @test occursin("Cancelled.", out)
                                @test occursin("Type 'prune'", out)
                                @test occursin("~/App.jl", out)
                                # #374: bar is suspended while stdin is read, then released.
                                @test nsus >= 1
                                @test DistSSHRun.KIT_PROGRESS_SUSPEND[] == 0
                            end
                        end
                    end
                end
            finally
                DistSSHRun.set_kit_noninteractive!(prev_ni)
            end
        end
    end
end
