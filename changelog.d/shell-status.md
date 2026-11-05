category: added

- `DistSSHBase.shell_status` is public and is not exported. For a child that has exited, a signal returns `128 + termsignal` (SIGINT 130, SIGPIPE 141, SIGKILL 137, SIGTERM 143) and any other exit returns `exitcode` unchanged. A process that has not exited throws `ArgumentError`. Callers that still read `exitcode` alone are unchanged.
