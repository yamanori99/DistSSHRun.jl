category: changed

- The remote login shell must be POSIX (`sh`, `bash`, `dash`, or `zsh`). `ssh` runs a command as `$SHELL -c`, not a login shell. Distributed's SSHManager starts workers with `sh -l -c`, and that wrap cannot be changed. `fish` and `csh` are unsupported. `fish` can silently change quoting (a backslash inside single quotes). See `help setup`.
