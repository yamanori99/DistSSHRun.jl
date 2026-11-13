"""
Worker → master heartbeat for DistSSHRun `drive`.

Not registered. DistSSHRun includes this source as
`DistSSHRun.DistSSHHeartbeat`, the same way it includes DistSSHUp.
The worker never `using`s DistSSHRun: Run always evals `WORKER_SOURCE`
into `Main.DistSSHHeartbeat` on workers.

When enabled by the controller (master), the deadline is the maximum time
the master may go without yielding before workers self-exit with code 75.
A worker that does not yield for more than twice the ping interval
resets its last-success time so the stall is not a false-positive exit.
DistSSHRun enables this monitor only with an explicit opt-in and deadline.
"""
module DistSSHHeartbeat

using DistSSHBase
using Distributed

const HEARTBEAT_CODE_VERSION = v"0.1.0"
const HEARTBEAT_EXIT_CODE = 75

include("config.jl")
include("monitor.jl")
include("worker_source.jl")
include("deliver.jl")

end # module DistSSHHeartbeat
