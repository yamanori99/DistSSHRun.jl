category: breaking

- The POSIX remote login-shell probe (`case x in x)`) runs once before the first remote command on that host in the process, including setup SSH preflight. fish is rejected without running the command. A host that passes is not probed again. A probe that is unknown still waits for a later non-zero exit, as before.
