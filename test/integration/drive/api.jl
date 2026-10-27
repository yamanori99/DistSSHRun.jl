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
        env_keys = (
            "DISTRIBUTED_PROJECT_ROOT",
            "DISTRIBUTED_REMOTE_PROJECT_ROOT",
            "DISTRIBUTED_OUTPUT_DIR",
            "DISTRIBUTED_RUNNER",
        )
        saved_env = Dict(k => get(ENV, k, nothing) for k in env_keys)
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
            @testset "active project unchanged after drive! (Run #184/#185)" begin
                @test Base.ACTIVE_PROJECT[] === saved_raw
                @test _api_project_same(Base.active_project(), saved_project)
            end
            @test Dict(k => get(ENV, k, nothing) for k in env_keys) == saved_env
        finally
            DistSSHRun.set_kit_verbosity!(prev_v)
            # Safety net if the library restore fails. Production writes this
            # slot itself, including `nothing`.
            Base.ACTIVE_PROJECT[] = saved_raw
            for (k, v) in saved_env
                if v === nothing
                    delete!(ENV, k)
                else
                    ENV[k] = v
                end
            end
        end
        @test _api_project_same(Base.active_project(), saved_project)
        @test Base.load_path() == saved_load
    end
end

@testset "drive restores env and active project on error and interrupt (#185)" begin
    _mktemp_host() do proj
        _write_host_project!(proj, "DriveRestore")
        saved_raw = Base.ACTIVE_PROJECT[]
        prev_v = DistSSHRun.kit_verbosity()
        try
            withenv(
                "DISTRIBUTED_PROJECT_ROOT" => "prior-root",
                "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "",
                "DISTRIBUTED_OUTPUT_DIR" => nothing,
                "DISTRIBUTED_RUNNER" => nothing,
            ) do
                Base.ACTIVE_PROJECT[] = nothing
                bad = joinpath(proj, "bad.jl")
                write(bad, "error(\"drive-boom\")\n")
                err = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        try
                            DistSSHRun.drive!(
                                bad;
                                project = proj,
                                verbosity = :quiet,
                                yes = true,
                                enable_log = false,
                            )
                            nothing
                        catch e
                            e
                        end
                    end
                end
                @test err isa LoadError
                @test Base.ACTIVE_PROJECT[] === nothing
                @test get(ENV, "DISTRIBUTED_PROJECT_ROOT", "") == "prior-root"
                @test get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", "missing") == ""
                @test !haskey(ENV, "DISTRIBUTED_OUTPUT_DIR")
                @test !haskey(ENV, "DISTRIBUTED_RUNNER")

                script = joinpath(proj, "stop.jl")
                write(script, "function main()\n    throw(InterruptException())\nend\n")
                session = DistSSHRun.KitSession(
                    project = proj,
                    workers = String[],
                    quiet = true,
                    yes = true,
                    verbosity = :quiet,
                )
                parsed = DistSSHRun.drive_parsed_from_session(
                    session,
                    script;
                    workers = DistSSHRun.WorkerPlan(1, Dict{String, Int}()),
                    enable_log = false,
                    skip_hash_check = true,
                )
                got = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        try
                            DistSSHRun.run_drive_parsed!(parsed; project_root = proj)
                            nothing
                        catch e
                            e
                        end
                    end
                end
                @test got isa InterruptException
                @test Base.ACTIVE_PROJECT[] === nothing
                @test get(ENV, "DISTRIBUTED_PROJECT_ROOT", "") == "prior-root"
                @test get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", "missing") == ""
                @test !haskey(ENV, "DISTRIBUTED_OUTPUT_DIR")
                @test !haskey(ENV, "DISTRIBUTED_RUNNER")
            end
        finally
            Base.ACTIVE_PROJECT[] = saved_raw
            DistSSHRun.set_kit_verbosity!(prev_v)
        end
    end
end
