category: breaking

- Drive and ride teardown, Ctrl-C worker interrupt, init ping or activation, heartbeat stop, and ride error cleanup act only on workers registered for that run. Other workers in the same Julia session are skipped with a warning. Setup `cleanup` is unchanged.
