# First `drive` pays this compile unless it already ran here.
# A missing script throws before workers, SSH, or a run directory.
# The hint calls run on a real file: `plan` is syntax-only unless sizing
# was requested, so this does not start workers either.

using PrecompileTools

@setup_workload begin
    @compile_workload begin
        dir = mktempdir()
        try
            missing = joinpath(dir, "missing.jl")
            args = String["parent:2", missing]
            parsed = parse_drive_args(args)
            try
                run_drive_parsed!(
                    parsed;
                    original_args = args,
                    project_root = pwd(),
                )
                error("precompile drive: missing script returned")
            catch err
                err isa ErrorException || rethrow()
                occursin("Script not found", err.msg) || rethrow()
            end

            plain = joinpath(dir, "plain.jl")
            drive = joinpath(dir, "drive.jl")
            write(plain, "ys = map(x -> x * x, 1:3)\n")
            write(drive, "using Distributed\nprintln(pmap(x -> x * x, 1:2))\n")
            _drive_script_hint_now(plain, dir; shown = "plain.jl")
            _drive_script_hint_now(drive, dir; shown = "drive.jl")
        finally
            rm(dir; force = true, recursive = true)
        end
    end
end
