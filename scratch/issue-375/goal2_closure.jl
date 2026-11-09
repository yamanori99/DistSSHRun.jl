# Goal 2 / plan item 3: ping closure defined inside a non-Main module.
# Local addprocs only.

using Distributed
using Serialization

function show_err(label, ex)
    println(label, ": ", typeof(ex))
    println(sprint(showerror, ex))
    return nothing
end

addprocs(1)
w = workers()[1]
println("julia=", VERSION, " master=", myid(), " worker=", w)
println("threads=", Threads.nthreads())

# (A) Closure defined in Main on the worker — expected to work (whole type sent).
println("\n=== (A) remotecall_fetch(() -> true, 1) from worker Main ===")
try
    r = remotecall_fetch(w) do
        remotecall_fetch(() -> true, 1)
    end
    println("PASS result=", r)
catch e
    println("FAIL")
    show_err("A", e)
end

# (B) Closure defined inside DistSSHHeartbeat on the worker.
# The module lives only on the worker (under Main). Master does not have it.
src = """
module DistSSHHeartbeat
using Distributed
const VERSION_STAMP = "repro"
ping_closure() = remotecall_fetch(() -> true, 1)
ping_myid() = remotecall_fetch(myid, 1)
end
"""
remotecall_fetch(w, src) do s
    include_string(Main, s)
    return nothing
end
println("\nworker Main.DistSSHHeartbeat defined=", remotecall_fetch(w) do
    isdefined(Main, :DistSSHHeartbeat)
end)
println("master Main.DistSSHHeartbeat defined=", isdefined(Main, :DistSSHHeartbeat))

println("\n=== (B) DistSSHHeartbeat.ping_closure() on worker (closure in module) ===")
try
    r = remotecall_fetch(w) do
        Base.invokelatest(Main.DistSSHHeartbeat.ping_closure)
    end
    println("UNEXPECTED PASS result=", r)
catch e
    println("FAIL as hypothesized")
    show_err("B", e)
end

println("\n=== (C) DistSSHHeartbeat.ping_myid() on worker (myid exists both sides) ===")
try
    r = remotecall_fetch(w) do
        Base.invokelatest(Main.DistSSHHeartbeat.ping_myid)
    end
    println("PASS result=", r, " (expect 1)")
catch e
    println("FAIL")
    show_err("C", e)
end

# Extra: show the closure type name on the worker.
println("\n=== closure type on worker ===")
println(remotecall_fetch(w) do
    t = typeof(() -> true)
    string(t, " parent=", parentmodule(t), " nameof=", nameof(t))
end)
println(remotecall_fetch(w) do
    t = typeof(Main.DistSSHHeartbeat.eval(:(() -> true)))
    string(t, " parent=", parentmodule(t))
end)

rmprocs(workers())
println("\ndone")
