using Test

# Fresh process: point the active project at a throwaway env, then
# `_kit_cli_cmd` must still pass `TEST_PROJECT` and `DistSSHRun --help` exits 0.
# Runs after `drive!` in the suite; the child does not see that active project.

@testset "kit cli --project is TEST_PROJECT" begin
    _with_tempdir() do throwaway
        write(joinpath(throwaway, "Project.toml"), "name = \"ThrowawayNoRun\"\n")
        child = joinpath(@__DIR__, "project_child.jl")
        cmd = setenv(
            `$(_julia_cmd_for()) --startup-file=no --project=$TEST_PROJECT $child $TEST_PROJECT $throwaway`,
            _child_julia_env(),
        )
        proc, out = _run_subprocess(cmd)
        if proc.exitcode != 0
            println(stderr, "──── kit cli project (exit=$(proc.exitcode)) ────")
            println(stderr, out)
            println(stderr, "──── end kit cli project ────")
        end
        @test proc.exitcode == 0
        @test occursin("CLI_PROJECT=" * TEST_PROJECT, out)
        @test occursin("Usage", out)
    end
end
