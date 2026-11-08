using Test

# Oracle: child `julia -m DistSSHRun <cmd> --help` / `--version` exits 0 and
# prints a Usage / version needle. Does not run workers, SSH, or rsync.
# `--help` / `--version` run `_subprocess_width()` at a time. Each is still its
# own process. The `ride` smoke stays after them so it does not share that wave.

@testset "CLI child help and version" begin
    env = _child_julia_env(Dict("DISTSSHKIT_YES" => "1"))
    cmds = Cmd[]
    kinds = Symbol[]
    labels = String[]
    for cmd in ("drive", "go", "ride", "setup", "hostinfo", "pool")
        push!(cmds, setenv(_kit_cli_cmd([cmd, "--help"]), env))
        push!(kinds, :help)
        push!(labels, cmd)
        push!(cmds, setenv(_kit_cli_cmd([cmd, "--version"]), env))
        push!(kinds, :version)
        push!(labels, cmd)
    end
    for (argv, kind) in (
            (["drive", "--require-git", "--help"], :drive_flags),
            (["hostinfo", "--help"], :hostinfo_flags),
            (
                ["go", "--julia", "/opt/julia/bin/julia", "--output-dir", "my_runs", "--help"],
                :go_flags,
            ),
        )
        push!(cmds, setenv(_kit_cli_cmd(argv), env))
        push!(kinds, kind)
        push!(labels, "")
    end
    results = _run_subprocesses(cmds)
    for (kind, label, (proc, out)) in zip(kinds, labels, results)
        @test proc.exitcode == 0
        if kind === :help
            @test occursin("Usage", out)
            @test occursin(label, lowercase(out))
            @test !occursin("Unknown subcommand", out)
        elseif kind === :version
            @test occursin("DistSSHRun $(DistSSHRun.dist_ssh_kit_version())", out)
        elseif kind === :drive_flags
            @test occursin("Usage", out)
            @test occursin("--require-git", out)
            @test !occursin("--mem-headroom", out)
        elseif kind === :hostinfo_flags
            @test occursin("Usage", out)
            @test occursin("hostinfo", lowercase(out))
            @test !occursin("--gb-per-worker", out)
        else
            @test kind === :go_flags
            @test occursin("Usage", out)
            @test occursin("--julia", out)
            @test occursin("--output-dir", out)
            @test !occursin("--gb-per-worker", out)
        end
    end

    # Counted tokens must get past ride_main into ride! (not UndefVarError in Main).
    mktempdir() do d
        script = joinpath(d, "id.jl")
        write(script, "map(identity, 1:2)\n")
        od = joinpath(d, "out")
        mkdir(od)
        ride_proc, ride_out = _run_subprocess(
            setenv(
                _kit_cli_cmd(
                    [
                        "ride", "-y", "-q", "--no-spi-check",
                        "--output-dir", od, "parent:1", script,
                    ]
                ),
                merge(env, Dict("DISTRIBUTED_PROJECT_ROOT" => _kit_root())),
            ),
        )
        @test !occursin("UndefVarError", ride_out)
        @test ride_proc.exitcode == 0
    end
end
