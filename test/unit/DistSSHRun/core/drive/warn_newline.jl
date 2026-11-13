using Test

@testset "drive skipped-include warnings end with a newline" begin
    out, _ = _capture_stdio() do _, _
        DistSSHRun.set_kit_verbosity!(:verbose)
        try
            DistSSHRun._drive_print_skipped_include_warns!(
                String[
                    "line 1: test",
                    "line 2: already has newline\n",
                ]
            )
        finally
            DistSSHRun.set_kit_verbosity!(:quiet)
        end
    end
    @test match(r"line 1: test\n", out) !== nothing
    @test match(r"line 2: already has newline\n", out) !== nothing
    @test !occursin("line 1: testline 2", out)
end

@testset "drive require-git dirty tree warning newline" begin
    Sys.which("git") === nothing && @test_skip "git not in PATH"
    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"DriveWarn\"\n")
        write(joinpath(proj, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        write(joinpath(proj, "README.md"), "seed\n")
        _git_init_min!(proj)
        write(joinpath(proj, "README.md"), "dirty\n")
        script = joinpath(proj, "job.jl")
        write(script, "true\n")
        out_dir = joinpath(proj, "out")
        mkpath(out_dir)
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
            workers = DistSSHRun.WorkerPlan(0, Dict{String, Int}()),
            enable_log = true,
            skip_hash_check = false,
            output_dir = out_dir,
            julia = joinpath(Sys.BINDIR, Base.julia_exename()),
            require_all_hosts = false,
        )
        _with_tempdir() do log_root
            log_path = DistSSHRun.init_log_file(log_root; prefix = "drive_dirty")
            combined = mktemp() do cap_path, cap_io
                redirect_stdout(cap_io) do
                    redirect_stderr(cap_io) do
                        DistSSHRun.set_kit_verbosity!(:verbose)
                        try
                            try
                                DistSSHRun.run_drive_parsed!(parsed; project_root = proj)
                            catch
                            end
                        finally
                            DistSSHRun.set_kit_verbosity!(:quiet)
                            DistSSHRun.close_log_file()
                        end
                    end
                end
                flush(cap_io)
                read(cap_path, String)
            end
            body = isfile(log_path) ? read(log_path, String) : ""
            text = combined * body
            @test occursin("uncommitted changes", text)
            @test match(r"uncommitted changes[^\n]*\n", text) !== nothing
        end
    end
end
