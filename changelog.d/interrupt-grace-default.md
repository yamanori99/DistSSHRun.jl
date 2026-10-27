category: planned

- `interrupt_grace` on `terminate!` and `terminate_run!` will default to a positive value, so a stop sends SIGINT before SIGTERM. DistSSHQueue `cancel` of a running job will use that default. Until then the default is `0` and `cancel` does not send SIGINT.
