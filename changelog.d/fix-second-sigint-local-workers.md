category: fixed

- A second Ctrl-C during `drive` cleanup on Julia 1.13 SIGKILLs this run's local Distributed workers before `_exit` 130, so they do not keep listening after the driver is gone.
