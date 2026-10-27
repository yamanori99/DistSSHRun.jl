category: breaking

- An SSH host that starts with `-`, including `user@-host`, is rejected before `ssh` or `scp` runs. A host or remote path that contains a control character (NUL, newline, or any other control byte) is rejected. Remote shell words go through one `posix_quote`. `openrsync` handling and the project-local `sshflags` warning are still open on #197.
