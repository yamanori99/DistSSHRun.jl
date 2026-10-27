category: added

- When a remote command fails with an exit other than 0 or SSH's 255, DistSSH checks whether that host's login shell is POSIX. A failed check keeps the original error and adds a line that names `$SHELL` and points to `help setup`. A command that succeeds does not run the check. A host that passes is not checked again in that process.
