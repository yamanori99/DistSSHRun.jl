using Distributed
using DistSSHRun

const proj = ENV["DISTSSH_CLUSTER_TEST_PROJ"]
const marker = ENV["DISTSSH_TEST_SIGINT_MARKER"]
const state = ENV["DISTSSH_TEST_CLUSTER_STATE"]

const owned = Ref(Int[])
const user_added = Ref(0)
const foreign_before = Ref(0)
const interrupted = Ref(false)
session = DistSSHSession(; project = proj, head_workers = 2)
addprocs(1; topology = :master_worker)
foreign_before[] = workers()[end]
try
    cluster(session) do c
        owned[] = copy(c.workers)
        addprocs(1; topology = :master_worker)
        user_added[] = workers()[end]
        touch(marker)
        sleep(120)
        return nothing
    end
catch e
    if e isa InterruptException
        interrupted[] = true
    else
        rethrow()
    end
end
open(state, "w") do io
    for w in owned[]
        println(io, "owned\t", w, "\t", w in workers())
    end
    println(io, "user\t", user_added[], "\t", user_added[] in workers())
    println(io, "foreign\t", foreign_before[], "\t", foreign_before[] in workers())
end
interrupted[] && exit(130)
