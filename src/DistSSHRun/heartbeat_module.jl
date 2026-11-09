"""
Worker → master heartbeat for DistSSHRun `drive`.

Not a `[deps]` entry. General installs DistSSHRun with this source included,
the same way it includes DistSSHUp. DistSSHHeartbeat is not registered.
"""
module DistSSHHeartbeat

using ..DistSSHBase
using Distributed

const HEARTBEAT_CODE_VERSION = v"0.1.0"
const HEARTBEAT_EXIT_CODE = 75

let _hb_entry = joinpath(@__DIR__, "..", "..", "lib", "DistSSHHeartbeat", "src", "DistSSHHeartbeat.jl")
    isfile(_hb_entry) || error(
        "DistSSHRun: $_hb_entry is missing. Copy the whole DistSSHRun package directory, including lib/, not only src/.",
    )
end

include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHHeartbeat", "src", "config.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHHeartbeat", "src", "monitor.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHHeartbeat", "src", "worker_source.jl"))
include(joinpath(@__DIR__, "..", "..", "lib", "DistSSHHeartbeat", "src", "deliver.jl"))

end # module DistSSHHeartbeat
