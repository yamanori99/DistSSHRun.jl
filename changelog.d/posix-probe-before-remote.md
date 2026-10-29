category: breaking

- Setup SSH preflight and remote commands that go through `_remote_shell_status` run a POSIX login-shell probe (`case x in x)`) once per host and live `ssh_opts()` in the process. fish is rejected without running that command. `run_on_host` and other direct `_ssh_cmd` paths are not probed up front. A probe that is unknown still waits for a later non-zero exit, as before.
