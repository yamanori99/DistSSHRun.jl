# Worker module text. Built at load. Do not read these files at drive time.

function _worker_source_text()::String
    monitor = joinpath(@__DIR__, "monitor.jl")
    worker = joinpath(@__DIR__, "worker.jl")
    Base.include_dependency(monitor)
    Base.include_dependency(worker)
    return string(
        "module DistSSHHeartbeat\n",
        "using Distributed: remotecall_fetch, myid\n",
        "const HEARTBEAT_CODE_VERSION = v\"", HEARTBEAT_CODE_VERSION, "\"\n",
        read(monitor, String),
        "\n",
        read(worker, String),
        "\nend\n",
        "nothing\n",
    )
end

const WORKER_SOURCE = _worker_source_text()
