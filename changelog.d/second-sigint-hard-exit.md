category: fixed

- A second Ctrl-C during `drive` cleanup on Julia 1.13 now `_exit`s 130. The previous `jl_exit` from the signal handler could SIGSEGV on macOS, so the process did not report 130.
