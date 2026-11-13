
- Before the first worker joins, `drive` and `ride` set the Distributed cluster cookie from `RandomDevice` and restore the controller's default RNG afterward. Julia's first cluster initialization would otherwise draw from the default RNG and shift user random streams. The cookie is never logged.
