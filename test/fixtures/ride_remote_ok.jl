# Remote ride success fixture. The rewritten `map` may run on SSH workers.
# Do not write a controller path from the worker. The unique marker is a
# parent-side `println` after `map` returns. Ride buffers that stdout and
# replays it after `kit_progress_done!`.
map(identity, 1:2)
println("DISTSSHKIT_RIDE_REMOTE_OK")
