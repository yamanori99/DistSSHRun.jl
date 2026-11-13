# First `drive` pays this compile unless it already ran here.
# A missing script throws before workers, SSH, or a run directory.

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
        finally
            rm(dir; force = true, recursive = true)
        end
    end
end
