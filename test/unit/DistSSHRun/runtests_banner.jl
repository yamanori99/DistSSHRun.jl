# Oracle: `_runtest_selected_files` matches `runtests.jl` / `parallel.jl` selection.
using Test

const _RUNTESTS_SRC = read(joinpath(_test_root(), "runtests.jl"), String)

@testset "runtests banner selection" begin
    clear = Dict{String, String}(
        "DISTSSH_TEST_GROUP" => "",
        "DISTSSHRUN_TEST_SHORT" => "",
        "JULIA_PKGEVAL" => "",
    )

    @testset "full list" begin
        withenv(clear...) do
            all = _runtest_include_paths(_RUNTESTS_SRC)
            selected = _runtest_selected_files(_RUNTESTS_SRC)
            @test selected == filter(p -> !startswith(p, "tty/"), all)
            @test any(p -> startswith(p, "tty/"), all)
            @test length(selected) > 0
        end
        withenv(merge(clear, Dict("DISTSSH_TEST_GROUP" => "all"))...) do
            got = _runtest_selected_files(_RUNTESTS_SRC)
            want = _runtest_include_paths(_RUNTESTS_SRC)
            @test got == want
            @test length(got) > 0
        end
    end

    @testset "DISTSSH_TEST_GROUP" begin
        withenv(merge(clear, Dict("DISTSSH_TEST_GROUP" => "unit"))...) do
            unit = _runtest_selected_files(_RUNTESTS_SRC)
            @test all(x -> startswith(x, "unit/"), unit)
            withenv(merge(clear, Dict("DISTSSH_TEST_GROUP" => "integration"))...) do
                integ = _runtest_selected_files(_RUNTESTS_SRC)
                @test all(x -> startswith(x, "integration/"), integ)
                @test length(unit) > length(integ) || length(integ) > 0
                @test length(unit) < length(_runtest_include_paths(_RUNTESTS_SRC))
            end
            withenv(merge(clear, Dict("DISTSSH_TEST_GROUP" => "tty"))...) do
                tty = _runtest_selected_files(_RUNTESTS_SRC)
                @test all(x -> startswith(x, "tty/"), tty)
                @test !isempty(tty)
            end
        end
    end

    @testset "DISTSSHRUN_TEST_SHORT" begin
        withenv(merge(clear, Dict("DISTSSHRUN_TEST_SHORT" => "1"))...) do
            selected = _runtest_selected_files(_RUNTESTS_SRC)
            @test "unit/DistSSHRun/execute.jl" ∉ selected
            @test "unit/DistSSHRun/messages/display.jl" ∈ selected
        end
    end

    @testset "short-skip guards in runtests.jl" begin
        @test _runtest_short_skip_unguarded(_RUNTESTS_SRC) == String[]
    end

    @testset "_runtest_assert_planned_executed!" begin
        @test _runtest_assert_planned_executed!(String["a.jl"], String["a.jl"]) === nothing
        @test_throws ErrorException _runtest_assert_planned_executed!(String["a.jl"], String["b.jl"])
    end

    @testset "empty selection errors" begin
        src = raw"""_runtest_include("integration/demos/without_kit.jl", "path.jl")\n"""
        withenv(merge(clear, Dict("DISTSSH_TEST_GROUP" => "unit"))...) do
            @test_throws ErrorException _runtest_selected_files(src)
        end
        withenv(merge(clear, Dict("DISTSSHRUN_TEST_SHORT" => "1"))...) do
            @test_throws ErrorException _runtest_selected_files(src)
        end
    end

    @testset "parallel parity" begin
        withenv(clear...) do
            info = _runtest_assert_parallel_runtests_parity!(_RUNTESTS_SRC)
            selected = _runtest_selected_files(_RUNTESTS_SRC)
            @test info.planned_files == selected
            @test info.suite_keys == _runtest_parallel_suite_key.(selected)
            serial_paths = collect(_runtest_parallel_serial_paths())
            @test length(info.serial_keys) == length(serial_paths)
            if !isempty(serial_paths)
                @test info.serial_keys == _runtest_parallel_suite_key.(serial_paths)
            end
        end
    end

    @testset "runtests.jl has no standalone _runtest_announce" begin
        calls = [
            line for line in eachline(IOBuffer(_RUNTESTS_SRC), keep = true) if
                occursin(r"^\s*_runtest_announce\(", line)
        ]
        @test length(calls) == 1
        @test strip(calls[1]) == "_runtest_announce(rel)"
    end
end
