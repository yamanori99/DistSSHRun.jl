category: added

- `terminate!` and `terminate_run!` set `KitRunResult.stop` from the signal ladder. `:within_grace` means the process exited after one SIGINT, before SIGTERM. `:sigterm` and `:sigkill` mean that `interrupt_grace` window ended and the ladder escalated. `:no_sigint` means `interrupt_grace` was 0, so SIGINT was not sent. `nothing` means the ladder did not run. The same string is written as `stop` in `kit.result` and, when the file already exists, in `run.toml`. `schema` stays 1. An unknown `stop` string is ignored.
