# Goal 1: two in-process drive! calls under --warn-overwrite=yes.
# Mimics test/unit/DistSSHRun/drive.jl:1063 then test/integration/drive/api.jl:63.

using DistSSHRun
using Dates

function write_host!(proj, name)
    write(joinpath(proj, "Project.toml"), "name = \"$name\"\nversion = \"0.0.1\"\n")
    write(joinpath(proj, "Manifest.toml"), "# lock\n")
    mkpath(joinpath(proj, "src"))
    write(joinpath(proj, "src", "$name.jl"), "module $name\nend\n")
    return nothing
end

function first_drive!(root)
    # Same shape as drive.jl:1063 (parent:1, quiet).
    app = joinpath(root, "app1")
    mkpath(joinpath(app, "src"))
    write_host!(app, "App1")
    script = joinpath(app, "job.jl")
    marker = joinpath(root, "RAN1")
    write(script, "write($(repr(marker)), \"yes\")\n")
    return DistSSHRun.drive!(
        script,
        ["parent:1"];
        project = app,
        snapshot = "20260101T000000Z-aaaaaa",
        yes = true,
        quiet = true,
        enable_log = false,
    )
end

function second_drive!(root)
    # Same shape as api.jl:39 (parent:2, verbose smoke).
    proj = joinpath(root, "app2")
    mkpath(proj)
    write_host!(proj, "DriveApiSmoke")
    script = joinpath(proj, "job.jl")
    write(
        script,
        """
        using Distributed
        function main()
            nw = nworkers()
            nw >= 2 || error("expected >= 2 workers, got ", nw)
            println("DISTSSHKIT_RUNNER_SMOKE_OK nw=", nw)
        end
        """,
    )
    return DistSSHRun.drive!(
        script,
        "parent:2";
        project = proj,
        verbosity = :verbose,
        yes = true,
    )
end

root = mktempdir(; prefix = "hb375-g1-")
println("workdir=", root)
try
    println("=== first drive! (parent:1) ===")
    r1 = redirect_stdout(devnull) do
        redirect_stderr(devnull) do
            first_drive!(root)
        end
    end
    println("first ok=", r1.ok, " exit=", r1.exit_code)

    println("=== second drive! (parent:2) stderr ===")
    mktemp() do out_path, out_io
        mktemp() do err_path, err_io
            r2 = redirect_stdout(out_io) do
                redirect_stderr(err_io) do
                    second_drive!(root)
                end
            end
            flush(out_io)
            flush(err_io)
            err = read(err_path, String)
            out = read(out_path, String)
            println("second ok=", r2.ok, " exit=", r2.exit_code)
            println("--- stdout ---")
            println(out)
            println("--- stderr ---")
            println(err)
            println("--- overwritten? ", occursin("overwritten", err), " ---")
            println("--- replacing module? ", occursin("replacing module", err), " ---")
        end
    end
finally
    rm(root; recursive = true, force = true)
end
