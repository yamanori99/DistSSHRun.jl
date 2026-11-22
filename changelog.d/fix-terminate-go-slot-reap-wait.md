category: fixed

- `terminate!` and `terminate_run!` wait after go-slot `pkill` until each targeted slot pid leaves the process table (reaping a zombie child when this process is the parent, then SIGKILL by exact pid). Leftover slots fail closed instead of returning success.
