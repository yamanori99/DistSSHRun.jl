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
      @test selected == all
      @test length(selected) > 0
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
    end
  end

  @testset "DISTSSHRUN_TEST_SHORT" begin
    withenv(merge(clear, Dict("DISTSSHRUN_TEST_SHORT" => "1"))...) do
      selected = _runtest_selected_files(_RUNTESTS_SRC)
      @test "unit/DistSSHRun/execute.jl" ∉ selected
      @test "unit/DistSSHRun/messages/display.jl" ∈ selected
    end
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

  @testset "runtests.jl has no standalone _runtest_announce" begin
    calls = [
      line for line in eachline(IOBuffer(_RUNTESTS_SRC), keep = true) if
        occursin(r"^\s*_runtest_announce\(", line)
    ]
    @test length(calls) == 1
    @test strip(calls[1]) == "_runtest_announce(rel)"
  end
end