# E2E strict bind: SSH workers join, then the controller writes into the output dir.
using Distributed

function main()
    all(!=(1), pmap(_ -> myid(), workers())) || error("expected SSH workers")
    touch(joinpath(ENV["DISTRIBUTED_OUTPUT_DIR"], "bind_ok.txt"))
    return nothing
end
