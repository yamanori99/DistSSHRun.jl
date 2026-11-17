using Test

const _REPO_ROOT = abspath(joinpath(@__DIR__, "..", "..", ".."))
const _SSH_E2E_HARNESS_FILES = (
    joinpath(_REPO_ROOT, "test", "support", "ssh_e2e.jl"),
    joinpath(_REPO_ROOT, "test", "e2e.jl"),
)

# Helpers must not patch a shipped remote tree (0444/0555). Change the controller
# project and `setup ship-tree` instead.
const _FORBIDDEN_REMOTE_SHIP_MUTATION_PATTERNS = (
    r"_ssh_e2e_push_job_runtests",
    r"\bscp\b.*ssh_config",
    r"rm\s+-f.*runtests\.jl",
    r"_ssh_e2e_work_root\(.*\).*\b(write|cp|scp|rm)\b",
)

@testset "SSH E2E harness does not mutate shipped remote trees" begin
    for path in _SSH_E2E_HARNESS_FILES
        @test isfile(path)
        text = read(path, String)
        for pat in _FORBIDDEN_REMOTE_SHIP_MUTATION_PATTERNS
            @test begin
                msg = "$path must not match $(pat.pattern)"
                !occursin(pat, text) || error(msg)
            end
        end
    end
end