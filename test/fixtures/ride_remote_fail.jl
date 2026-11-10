# Remote ride failure fixture. The rewritten `map` errors on a worker.
map(x -> error("DISTSSH_RIDE_REMOTE_BOOM"), 1:2)
