category: breaking

- A signal-killed child is a failure where status was taken from `exitcode` alone. Those reads use `DistSSHBase.shell_status` (`128 + termsignal`; SIGINT 130, SIGPIPE 141, SIGKILL 137, SIGTERM 143). Exit 0, any other non-zero exit, and SSH exit 255 stay as they were. A go slot with no `go.exitcode` file uses that status, so a dead ssh is not success. `_ssh_phase_exit_code` still returns `nothing` when the child was signaled.
