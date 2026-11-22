using Test
using TOML

const _COMPILE_BENCH_DIR = normpath(joinpath(@__DIR__, "..", "..", "..", "bench", "compile"))
const _COMPILE_BENCH_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

function _bench_stage_work()::String
    work = mktempdir()
    src = joinpath(_COMPILE_BENCH_DIR, "fixtures")
    for name in readdir(src)
        cp(joinpath(src, name), joinpath(work, name))
    end
    return work
end

function _bench_fill_tokens(text::AbstractString, work::AbstractString, store::AbstractString)::String
    return replace(replace(String(text), "{work}" => work), "{store}" => store)
end

function _bench_depot_path(depot::AbstractString)::String
    existing = get(ENV, "JULIA_DEPOT_PATH", "")
    sep = Sys.iswindows() ? ";" : ":"
    return isempty(existing) ? string(depot, sep) : string(depot, sep, existing)
end

@testset "compile bench config" begin
    @testset "kit.progress fixture" begin
        fixture = joinpath(_COMPILE_BENCH_DIR, "fixtures", "kit.progress")
        @test isfile(fixture)
        work = mktempdir()
        try
            cp(fixture, joinpath(work, "kit.progress"))
            rows = DistSSHRun.kit_progress_phases(work)
            @test length(rows) == 2
            mktemp() do out_path, out_io
                code = redirect_stdout(out_io) do
                    DistSSHRun.progress([work])
                end
                flush(out_io)
                @test code == 0
                @test occursin("workers", read(out_path, String))
            end
        finally
            rm(work; force = true, recursive = true)
        end
    end

    @testset "commands.toml entries exit 0" begin
        data = TOML.parsefile(joinpath(_COMPILE_BENCH_DIR, "commands.toml"))
        @test String(data["package"]) == "DistSSHRun"
        specs = data["command"]
        specs isa AbstractDict && (specs = [specs])
        depot = mktempdir()
        try
            inst = setenv(
                `$(_julia_cmd_for()) --startup-file=no --project=$_COMPILE_BENCH_ROOT -e $(raw"using Pkg; Pkg.instantiate()")`,
                _child_julia_env(Dict("JULIA_DEPOT_PATH" => _bench_depot_path(depot))),
            )
            proc = run(ignorestatus(inst))
            @test proc.exitcode == 0
            store = joinpath(mktempdir(), "jobs.toml")
            write(store, "jobs = []\n")
            work = _bench_stage_work()
            try
                for spec in specs
                    name = String(spec["name"])
                    args = String[
                        _bench_fill_tokens(string(a), work, store) for a in spec["args"]
                    ]
                    cmd = setenv(
                        _kit_cli_cmd(args),
                        _child_julia_env(
                            Dict(
                                "JULIA_DEPOT_PATH" => _bench_depot_path(depot),
                                "JULIA_PKG_PRECOMPILE_AUTO" => "0",
                            ),
                        );
                        dir = _COMPILE_BENCH_ROOT,
                    )
                    proc, out = let
                        p, reader = _start_subprocess(ignorestatus(cmd))
                        wait(p)
                        p, fetch(reader)
                    end
                    _assert_proc_ok(proc, out; label = "compile bench $name")
                end
            finally
                rm(work; force = true, recursive = true)
            end
        finally
            rm(depot; force = true, recursive = true)
        end
    end
end
