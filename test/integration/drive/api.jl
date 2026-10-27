using Test

# Same project when the strings match, or when both paths exist and `realpath`
# agrees. `active_project()` sometimes spells the file, sometimes the directory.
function _api_project_same(left, right)::Bool
    left == right && return true
    (left isa AbstractString && right isa AbstractString) || return false
    (ispath(left) && ispath(right)) || return false
    return realpath(left) == realpath(right)
end

# Oracle: `drive!(…, "parent:2")` runs the smoke driver in this process.
# CLI child is `local.jl`. Not SSH.
#
# First in-process `include` of a driver into `Main`. Later files (e.g.
# `integration/drive/execute.jl`) share that `Main` and will warn-overwrite
# `main()`. Keep this file before those includes in `runtests.jl`.

@testset "drive! l:N" begin
    fixture = _fixture("drive_local_smoke.jl")
    _mktemp_host() do proj
        _write_host_project!(proj, "DriveApiSmoke")
        script = joinpath(proj, "job.jl")
        cp(fixture, script; force = true)
        # `:quiet` sends driver stdout to the kit log only. Use `:verbose` so
        # SMOKE_OK is on the captured stream (same string as CLI `local.jl`).
        prev_v = DistSSHRun.kit_verbosity()
        saved_raw = Base.ACTIVE_PROJECT[]
        saved_project = Base.active_project()
        saved_load = copy(Base.load_path())
        try
            mktemp() do out_path, out_io
                mktemp() do err_path, err_io
                    result = redirect_stdout(out_io) do
                        redirect_stderr(err_io) do
                            DistSSHRun.drive!(
                                script,
                                "parent:2";
                                project = proj,
                                verbosity = :verbose,
                                yes = true,
                            )
                        end
                    end
                    flush(out_io)
                    flush(err_io)
                    out = read(out_path, String)
                    err = read(err_path, String)
                    @test result.ok
                    @test result.exit_code == 0
                    @test occursin("DISTSSHKIT_RUNNER_SMOKE_OK nw=2", out)
                    # No explicit output_dir=/log_dir= — still resolved (not the raw `nothing` kwarg).
                    @test result.output_dir !== nothing
                    @test result.log_dir !== nothing
                    # `@everywhere` must not redefine master helpers (warn-overwrite).
                    @test !occursin("overwritten", err)
                end
            end
            # Library `drive!` still leaves the host active. Run #184/#185
            # will flip this to `@test` when the library restores the project.
            @testset "active project unchanged after drive! (Run #184/#185)" begin
                @test_broken _api_project_same(Base.active_project(), saved_project)
            end
        finally
            DistSSHRun.set_kit_verbosity!(prev_v)
            # Production restores with `Base.set_active_project`. Do not copy
            # this raw write into src. The test puts back the exact previous
            # slot, including `nothing`. `set_active_project(nothing)` accepts
            # `nothing`, then `active_project()` walks `LOAD_PATH`.
            Base.ACTIVE_PROJECT[] = saved_raw
        end
        @test _api_project_same(Base.active_project(), saved_project)
        @test Base.load_path() == saved_load
    end
end
