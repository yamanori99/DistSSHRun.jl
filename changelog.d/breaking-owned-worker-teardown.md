category: breaking

- Drive and ride teardown, Ctrl-C worker interrupt, init ping or activation, heartbeat stop, and ride error cleanup act only on workers registered for that run. Other workers in the same Julia session are skipped with a warning. Driver sync, package load, prepare hooks, and heartbeat install use the same owned set. Launch rollback still removes every worker joined since a `before` snapshot. Setup `cleanup` is unchanged.
