# Shared test infrastructure (barrel; mirrors cli/drive.jl + DistSSHRun/core/drive/).
# Guard: runtests and some unit files may both `include` this path; JETLS should not reload fragments.

if !isdefined(Main, :_child_julia_env)
    include(joinpath(@__DIR__, "..", "lib", "DistSSHBase", "test", "support.jl"))
    include(joinpath(@__DIR__, "..", "lib", "DistSSHUp", "test", "support.jl"))
    if !isdefined(Main, :_binding_world_age_warning_text)
        include(joinpath(@__DIR__, "support", "binding_world_stderr.jl"))
    end
    include(joinpath(@__DIR__, "support", "_common.jl"))
    include(joinpath(@__DIR__, "support", "subprocess.jl"))
    include(joinpath(@__DIR__, "support", "progress_tty.jl"))
    include(joinpath(@__DIR__, "support", "host.jl"))
    include(joinpath(@__DIR__, "support", "drive.jl"))
    include(joinpath(@__DIR__, "support", "setup.jl"))
    include(joinpath(@__DIR__, "support", "staging.jl"))
    include(joinpath(@__DIR__, "support", "ssh_e2e.jl"))
end
