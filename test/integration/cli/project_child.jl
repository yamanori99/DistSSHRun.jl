# Subprocess for `project.jl`. Not included by `runtests.jl`.
# ARGS: TEST_PROJECT, throwaway directory (has Project.toml).

const TEST_PROJECT = String(ARGS[1])
const THROWAWAY = String(ARGS[2])

using Test
include(joinpath(@__DIR__, "..", "..", "support.jl"))

# Included while `--project` is still TEST_PROJECT. The switch is what the
# parent test is checking: `_kit_cli_cmd` must ignore it.
Base.set_active_project(joinpath(THROWAWAY, "Project.toml"))

function _cmd_project(cmd::Cmd)::String
    for arg in cmd.exec
        s = String(arg)
        startswith(s, "--project=") && return s[length("--project=") + 1:end]
    end
    return ""
end

cmd = _kit_cli_cmd(["--help"])
got = _cmd_project(cmd)
println("CLI_PROJECT=", got)
help = run(ignorestatus(setenv(cmd, _child_julia_env())))
exit((got == TEST_PROJECT && help.exitcode == 0) ? 0 : 1)
