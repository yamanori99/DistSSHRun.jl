category: fixed

- Before the first worker joins, `drive` and `ride` set the Distributed cluster cookie from `RandomDevice` when you have not already initialized Distributed, and wrap worker launch so the controller's default RNG is restored afterward. The cookie is never logged.
