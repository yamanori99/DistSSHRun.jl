# Goal 4 / plan item 2: compare (a) source-string module vs (b) LOAD_PATH+using.
# Each experiment is a child `julia` with JULIA_DEPOT_PATH on that command only.

workdir = mktempdir(; prefix = "hb375-g4-")
println("workdir=", workdir)
julia = joinpath(Sys.BINDIR, Base.julia_exename())

pkgdir = joinpath(workdir, "DistSSHHeartbeat")
mkpath(joinpath(pkgdir, "src"))
uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
write(
    joinpath(pkgdir, "Project.toml"),
    """
    name = "DistSSHHeartbeat"
    uuid = "$uuid"
    version = "0.1.0"

    [deps]
    Distributed = "8ba89e20-285c-5b6f-9357-94700520ee1b"
    """,
)
write(
    joinpath(pkgdir, "src", "DistSSHHeartbeat.jl"),
    """
    module DistSSHHeartbeat
    using Distributed: remotecall_fetch, myid
    const HEARTBEAT_CODE_VERSION = v"0.1.0"
    ping() = remotecall_fetch(myid, 1)
    end
    """,
)

clash_uuid = "11111111-2222-4333-8444-555555555555"
clash_pkg = joinpath(workdir, "OtherHeartbeat")
mkpath(joinpath(clash_pkg, "src"))
write(
    joinpath(clash_pkg, "Project.toml"),
    """
    name = "DistSSHHeartbeat"
    uuid = "$clash_uuid"
    version = "9.9.9"
    """,
)
write(
    joinpath(clash_pkg, "src", "DistSSHHeartbeat.jl"),
    """
    module DistSSHHeartbeat
    const HEARTBEAT_CODE_VERSION = v"9.9.9"
    const FROM = :user_manifest
    end
    """,
)
clash_proj = joinpath(workdir, "ClashUser")
mkpath(joinpath(clash_proj, "src"))
write(
    joinpath(clash_proj, "Project.toml"),
    """
    name = "ClashUser"
    uuid = "99999999-9999-4999-8999-999999999999"
    version = "0.1.0"

    [deps]
    DistSSHHeartbeat = "$clash_uuid"
    """,
)
write(joinpath(clash_proj, "src", "ClashUser.jl"), "module ClashUser\nend\n")

depot_rw = joinpath(workdir, "depot-rw")
depot_exist = joinpath(workdir, "depot-exist")
depot_ro = joinpath(workdir, "depot-ro")
mkpath(depot_rw)
mkpath(depot_exist)
mkpath(depot_ro)

function run_child(label, code; depot, extra_flags = String[], extra_env = Dict{String, String}())
    println("\n======== ", label, " ========")
    flush(stdout)
    env = Dict(
        "JULIA_DEPOT_PATH" => depot,
        "JULIA_LOAD_PATH" => "@:@stdlib",
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        "HOME" => joinpath(workdir, "home"),
    )
    merge!(env, extra_env)
    mkpath(env["HOME"])
    argv = String[julia, "--startup-file=no"]
    append!(argv, extra_flags)
    push!(argv, "-e", code)
    t = @elapsed begin
        proc = run(pipeline(setenv(Cmd(argv), env); stdout = stdout, stderr = stderr); wait = false)
        wait(proc)
        println("exit=", proc.exitcode)
    end
    println("wall=", round(t; digits = 3), "s")
    return nothing
end

pkgdir_lit = repr(pkgdir)
clash_proj_lit = repr(clash_proj)
clash_pkg_lit = repr(clash_pkg)

run_child(
    "instantiate ClashUser + develop other DistSSHHeartbeat",
    """
    using Pkg
    Pkg.activate($clash_proj_lit)
    Pkg.develop(path=$clash_pkg_lit)
    println("clash Project.toml ready")
    """;
    depot = depot_rw,
)

WRAP = """
module DistSSHHeartbeat
using Distributed: remotecall_fetch, myid
const HEARTBEAT_CODE_VERSION = v"0.1.0"
ping() = remotecall_fetch(myid, 1)
end
"""
wrap_lit = repr(WRAP)

run_child(
    "(a) eval source into DistSSHHeartbeat under worker Main; ping myid",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    t = @elapsed remotecall_fetch(w, $wrap_lit) do s
        include_string(Main, s)
        return nothing
    end
    r = remotecall_fetch(w) do
        Base.invokelatest(Main.DistSSHHeartbeat.ping)
    end
    println("first_eval_s=", t)
    println("ping=", r)
    println("master_defined=", isdefined(Main, :DistSSHHeartbeat))
    println("worker_parent=", remotecall_fetch(w) do
        string(parentmodule(Main.DistSSHHeartbeat))
    end)
    rmprocs(workers())
    """;
    depot = depot_rw,
)

run_child(
    "(a) second eval same module (replacing module warning)",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    remotecall_fetch(w, $wrap_lit) do s
        include_string(Main, s)
        return nothing
    end
    err = sprint() do io
        redirect_stderr(io) do
            remotecall_fetch(w, $wrap_lit) do s
                include_string(Main, s)
                return nothing
            end
        end
    end
    println("stderr=[", err, "]")
    println("replacing=", occursin("replacing module", err))
    rmprocs(workers())
    """;
    depot = depot_rw,
)

run_child(
    "(a) clash with user script module DistSSHHeartbeat already in worker Main",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    remotecall_fetch(w) do
        include_string(Main, "module DistSSHHeartbeat\nconst FROM = :user_script\nend\n")
        return nothing
    end
    err = sprint() do io
        redirect_stderr(io) do
            remotecall_fetch(w, $wrap_lit) do s
                include_string(Main, s)
                return nothing
            end
        end
    end
    println("stderr=[", err, "]")
    st = remotecall_fetch(w) do
        m = Main.DistSSHHeartbeat
        (has_from = isdefined(m, :FROM), has_ping = isdefined(m, :ping), from = isdefined(m, :FROM) ? m.FROM : nothing)
    end
    println("after=", st)
    rmprocs(workers())
    """;
    depot = depot_rw,
)

run_child(
    "(b) pushfirst LOAD_PATH with shipped dir then using; ping",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    t = @elapsed info =         remotecall_fetch(w, $pkgdir_lit) do p
            pushfirst!(LOAD_PATH, p)
            Core.eval(Main, :(using DistSSHHeartbeat))
            m = Base.invokelatest(getfield, Main, :DistSSHHeartbeat)
            (
                version = string(m.HEARTBEAT_CODE_VERSION),
                ping = Base.invokelatest(m.ping),
                path = string(pathof(m)),
            )
        end
    println("first_using_s=", t)
    println("info=", info)
    rmprocs(workers())
    """;
    depot = depot_rw,
)

run_child(
    "(b) Pkg.precompile shipped DistSSHHeartbeat (writable depot)",
    """
    using Pkg
    Pkg.activate($pkgdir_lit)
    t = @elapsed Pkg.precompile()
    println("precompile_s=", t)
    """;
    depot = depot_rw,
    extra_env = Dict("JULIA_PKG_PRECOMPILE_AUTO" => "1"),
)

run_child(
    "(b) --compiled-modules=existing, empty depot, using shipped dir",
    """
    using Distributed
    addprocs(1; exeflags=`--compiled-modules=existing --startup-file=no`)
    w = workers()[1]
    info = try
        remotecall_fetch(w, $pkgdir_lit) do p
            pushfirst!(LOAD_PATH, p)
            Core.eval(Main, :(using DistSSHHeartbeat))
            m = Base.invokelatest(getfield, Main, :DistSSHHeartbeat)
            (version = string(m.HEARTBEAT_CODE_VERSION), path = string(pathof(m)))
        end
    catch e
        println("ERROR ", typeof(e), " ", sprint(showerror, e))
        nothing
    end
    println("info=", info)
    rmprocs(workers())
    """;
    depot = depot_exist,
    extra_flags = ["--compiled-modules=existing"],
)

# Read-only depot: copy empty-ish depot_exist after chmod. Worker inherits depot.
run_child(
    "(b) prepare read-only depot (chmod after a failed/empty start)",
    """
    println("ok")
    """;
    depot = depot_ro,
)

function chmod_tree(path, mode)
    for (root, dirs, files) in walkdir(path)
        for d in dirs
            chmod(joinpath(root, d), mode)
        end
        for f in files
            chmod(joinpath(root, f), mode)
        end
        chmod(root, mode)
    end
    return nothing
end
chmod_tree(depot_ro, 0o555)

run_child(
    "(b) using shipped dir with read-only JULIA_DEPOT_PATH",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    info = try
        remotecall_fetch(w, $pkgdir_lit) do p
            pushfirst!(LOAD_PATH, p)
            Core.eval(Main, :(using DistSSHHeartbeat))
            m = Base.invokelatest(getfield, Main, :DistSSHHeartbeat)
            (version = string(m.HEARTBEAT_CODE_VERSION), path = string(pathof(m)))
        end
    catch e
        println("ERROR ", typeof(e), " ", sprint(showerror, e))
        nothing
    end
    println("info=", info)
    rmprocs(workers())
    """;
    depot = depot_ro,
)

# Keep depot_ro read-only for the next compiled-modules=existing case.

# Same read-only depot, but --compiled-modules=existing so load should not mkdir compiled/
run_child(
    "(b) read-only depot + --compiled-modules=existing",
    """
    using Distributed
    addprocs(1; exeflags=`--compiled-modules=existing --startup-file=no`)
    w = workers()[1]
    info = try
        remotecall_fetch(w, $pkgdir_lit) do p
            pushfirst!(LOAD_PATH, p)
            Core.eval(Main, :(using DistSSHHeartbeat))
            m = Base.invokelatest(getfield, Main, :DistSSHHeartbeat)
            (version = string(m.HEARTBEAT_CODE_VERSION), path = string(pathof(m)))
        end
    catch e
        println("ERROR ", typeof(e), " ", sprint(showerror, e))
        nothing
    end
    println("info=", info)
    rmprocs(workers())
    """;
    depot = depot_ro,
    extra_flags = ["--compiled-modules=existing"],
)
chmod_tree(depot_ro, 0o755)

run_child(
    "(b) name clash: --project=ClashUser, pushfirst shipped, using DistSSHHeartbeat",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    info = try
        remotecall_fetch(w, $clash_proj_lit, $pkgdir_lit) do user_proj, shipped
            Base.ACTIVE_PROJECT[] = joinpath(user_proj, "Project.toml")
            pushfirst!(LOAD_PATH, shipped)
            Core.eval(Main, :(using DistSSHHeartbeat))
            m = Base.invokelatest(getfield, Main, :DistSSHHeartbeat)
            (
                version = string(m.HEARTBEAT_CODE_VERSION),
                path = string(pathof(m)),
                has_from = isdefined(m, :FROM),
                uuid = string(Base.PkgId(m).uuid),
                load_path0 = string(LOAD_PATH[1]),
            )
        end
    catch e
        println("ERROR ", typeof(e), " ", sprint(showerror, e))
        nothing
    end
    println("pushfirst_shipped=", info)
    rmprocs(workers())
    """;
    depot = depot_rw,
)

run_child(
    "(b) name clash: --project=ClashUser, no pushfirst (loads Manifest copy)",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    info = try
        remotecall_fetch(w, $clash_proj_lit) do user_proj
            Base.ACTIVE_PROJECT[] = joinpath(user_proj, "Project.toml")
            Core.eval(Main, :(using DistSSHHeartbeat))
            m = Base.invokelatest(getfield, Main, :DistSSHHeartbeat)
            (
                version = string(m.HEARTBEAT_CODE_VERSION),
                path = string(pathof(m)),
                has_from = isdefined(m, :FROM),
                uuid = string(Base.PkgId(m).uuid),
            )
        end
    catch e
        println("ERROR ", typeof(e), " ", sprint(showerror, e))
        nothing
    end
    println("env_copy=", info)
    rmprocs(workers())
    """;
    depot = depot_rw,
    extra_flags = ["--project=$clash_proj"],
)

run_child(
    "(a) eval still works when ClashUser project is active (no using)",
    """
    using Distributed
    addprocs(1)
    w = workers()[1]
    remotecall_fetch(w, $clash_proj_lit) do user_proj
        Base.ACTIVE_PROJECT[] = joinpath(user_proj, "Project.toml")
        nothing
    end
    remotecall_fetch(w, $wrap_lit) do s
        include_string(Main, s)
        return nothing
    end
    r = remotecall_fetch(w) do
        Base.invokelatest(Main.DistSSHHeartbeat.ping)
    end
    println("ping=", r, " version=", remotecall_fetch(w) do
        string(Main.DistSSHHeartbeat.HEARTBEAT_CODE_VERSION)
    end)
    rmprocs(workers())
    """;
    depot = depot_rw,
    extra_flags = ["--project=$clash_proj"],
)

println("\nALL DELIVERY EXPERIMENTS DONE")
