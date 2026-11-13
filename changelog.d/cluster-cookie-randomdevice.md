category: fixed

- Before the first worker joins, `drive` and `ride` set the Distributed cluster cookie from `RandomDevice` when you have not already initialized Distributed, and wrap worker launch so the controller's default RNG is restored afterward. Julia's first `cluster_cookie` / `addprocs` would otherwise draw from the default RNG. The cookie is never logged.
