using Test

# Oracle: `src/cli/drive.jl` + `--log-dir` writes one log with SMOKE_OK.
# Does not cover `-m DistSSHRun` (log_via_module.jl).

@testset "drive log via script path" begin
    fixture = _fixture("drive_local_smoke.jl")
    julia = _julia_exe()

    _mktemp_host() do proj
        _write_host_project!(proj, "SmokeLogApp")
        script = joinpath(proj, "job.jl")
        cp(fixture, script; force = true)
        log_dir = joinpath(proj, "logs")
        mkpath(log_dir)

        cmd = _host_drive_cmd(;
            script = script,
            host_project = proj,
            log_dir = log_dir,
            julia = julia,
        )
        _assert_drive_log_output(; cmd = cmd, log_dir = log_dir)
    end
end
