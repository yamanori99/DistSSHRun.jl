using Test

# Same project when the strings match, or when both paths exist and `realpath`
# agrees. `active_project()` sometimes spells the file, sometimes the directory.
function _api_project_same(left, right)::Bool
    left == right && return true
    (left isa AbstractString && right isa AbstractString) || return false
    (ispath(left) && ispath(right)) || return false
    return realpath(left) == realpath(right)
end

# Oracle: `drive!(…; head_workers = 2)` runs the smoke driver in this process.
# CLI child is `local.jl`. Not SSH.
#
# `unit/DistSSHRun/drive.jl` may already have included a driver into `Main`.
# Every in-process `drive!` / `run_drive_parsed!` here uses `reuse_main=true`.
# Later files (e.g. `integration/drive/execute.jl`) share that `Main`.

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
                                script; head_workers = 2,
                                project = proj,
                                verbosity = :verbose,
                                reuse_main = true
                            )
                        end
                    end
                    flush(out_io)
                    flush(err_io)
                    out = read(out_path, String)
                    err = read(err_path, String)
                    @test result.ok
                    @test result.exit_code == 0
                    @test occursin("DISTSSH_RUNNER_SMOKE_OK nw=2", out)
                    # No explicit output_dir=/log_dir= — still resolved (not the raw `nothing` kwarg).
                    @test result.output_dir !== nothing
                    @test result.log_dir !== nothing
                    # Heartbeat must not redefine master helpers (warn-overwrite).
                    @test !occursin("overwritten", err)
                    @test !isdefined(Main, :stop_heartbeat_monitor)
                    @test !isdefined(Main, :start_heartbeat_monitor)
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
                "DISTRIBUTED_RUNNER" => nothing
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
                                enable_log = false,
                                reuse_main = true
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
                session = DistSSHRun.DistSSHSession(
                    project = proj,
                    workers = String[],
                    quiet = true,
                    verbosity = :quiet
                )
                parsed = DistSSHRun.drive_parsed_from_session(
                    session,
                    script;
                    workers = DistSSHRun.WorkerPlan(1, Dict{String, Int}()),
                    enable_log = false,
                    skip_hash_check = true,
                    reuse_main = true
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

# A script that defines `init_output_dir!` leaves that function in `Main`.
# The next in-process `drive!` of a script that does not define it must
# allocate its own directory, including when the previous directory now has files.
@testset "drive! ignores a leftover init_output_dir!" begin
    _mktemp_host() do proj
        _write_host_project!(proj, "DriveLeftoverInit")
        filled = joinpath(proj, "output")
        with_init = joinpath(proj, "with_init.jl")
        write(
            with_init, """
            function init_output_dir!(_)
                dest = joinpath(@__DIR__, "output")
                mkpath(dest)
                ENV["DISTRIBUTED_OUTPUT_DIR"] = dest
                return nothing
            end
            function main()
                write(joinpath(ENV["DISTRIBUTED_OUTPUT_DIR"], "filled.txt"), "x")
                println("DISTSSH_INIT_RAN")
                return nothing
            end
            """
        )
        no_init = joinpath(proj, "no_init.jl")
        write(
            no_init, """
            function main()
                println("DISTSSH_NO_INIT_OUTPUT")
                return nothing
            end
            """
        )
        prev_v = DistSSHRun.kit_verbosity()
        try
            first = redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    DistSSHRun.drive!(
                        with_init; head_workers = 1,
                        project = proj,
                        verbosity = :quiet,
                        enable_log = false,
                        reuse_main = true
                    )
                end
            end
            @test first.ok
            @test first.output_dir == DistSSHRun.canonical_local_path(filled)
            @test isfile(joinpath(filled, "filled.txt"))
            delete!(ENV, "DISTRIBUTED_OUTPUT_DIR")
            second = redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    DistSSHRun.drive!(
                        no_init; head_workers = 1,
                        project = proj,
                        verbosity = :quiet,
                        enable_log = false,
                        reuse_main = true
                    )
                end
            end
            @test second.ok
            @test second.exit_code == 0
            @test second.output_dir !== nothing
            @test second.output_dir != DistSSHRun.canonical_local_path(filled)
        finally
            DistSSHRun.set_kit_verbosity!(prev_v)
            delete!(ENV, "DISTRIBUTED_OUTPUT_DIR")
        end
    end
end

# Each driver hook stays in `Main` after its script. A later in-process `drive!`
# runs only the hooks its own script defines. A hook added to
# `_drive_script_hook_signatures` needs a definition here.
@testset "drive! runs only this script's hooks" begin
    _mktemp_host() do proj
        _write_host_project!(proj, "DriveLeftoverHooks")
        hooks = keys(DistSSHRun._drive_script_hook_signatures(String[]))
        marker(hook) = joinpath(proj, "RAN_$(hook)")
        args = Dict(:init_output_dir! => "_")
        scripts = Pair{String, Vector{Symbol}}[]
        for hook in hooks
            path = joinpath(proj, "with_$(hook).jl")
            write(
                path, """
                function $(hook)($(get(args, hook, "")))
                    touch($(repr(marker(hook))))
                    return nothing
                end
                """
            )
            push!(scripts, path => [hook])
        end
        bare = joinpath(proj, "bare.jl")
        write(bare, "bare_loaded = true\n")
        push!(scripts, bare => Symbol[])
        prev_v = DistSSHRun.kit_verbosity()
        try
            for (script, defined) in scripts
                foreach(h -> rm(marker(h); force = true), hooks)
                res = redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        DistSSHRun.drive!(
                            script; head_workers = 1,
                            project = proj,
                            verbosity = :quiet,
                            enable_log = false,
                            reuse_main = true
                        )
                    end
                end
                delete!(ENV, "DISTRIBUTED_OUTPUT_DIR")
                @test res.ok
                @test [h for h in hooks if isfile(marker(h))] == defined
            end
        finally
            DistSSHRun.set_kit_verbosity!(prev_v)
            delete!(ENV, "DISTRIBUTED_OUTPUT_DIR")
        end
    end
end

# `main = make_main(path)` rebinds a closure whose type, and so `Method`, is unchanged.
@testset "drive hook selection sees a rebound closure" begin
    make_main(path) = () -> path
    a, b = make_main("a"), make_main("b")
    m = first(methods(a, Tuple{}))
    @test first(methods(b, Tuple{})) === m
    before = (main = (a, m),)
    @test DistSSHRun._drive_script_hooks(before, (main = (b, m),)).main === m
    @test DistSSHRun._drive_script_hooks(before, before).main === nothing
    @test DistSSHRun._drive_script_hooks((main = nothing,), (main = nothing,)).main === nothing
end

@testset "init_output_dir! lookup uses the definition world" begin
    # Tracked fixture: JETLS executes this `@testset` as top-level and cannot
    # `include` a path that only exists after `mktempdir` + `write`.
    path = _fixture("drive_init_output.jl")
    args = String[]
    lookup() = DistSSHRun._drive_script_hook_bindings(args).init_output_dir!
    before = lookup()
    redirect_stderr(devnull) do
        Base.include(Main, path)
    end
    mktemp() do err_path, err_io
        after = redirect_stderr(err_io) do
            lookup()
        end
        flush(err_io)
        @test after isa Tuple{Function, Method}
        @test after !== before
        @test !occursin("prior to its definition", read(err_path, String))
    end
end
