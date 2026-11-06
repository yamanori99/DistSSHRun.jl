category: breaking

- Detached `execute!` starts in the project directory, passes `--threads=1` and `--history-file=no`, and keeps an allowlist of environment variables. `dir`, `threads`, `env_allow`, and `env` override that. Restore the previous working directory, thread flag, and environment copy with `dir=pwd()`, `threads=:unset`, and `env_allow=:all`. `JULIA_LOAD_PATH`, the CLI include guards, and names containing `COOKIE` stay dropped.
- Local go slots and local drive workers inherit that environment, and their thread count follows the child. `SSH_AUTH_SOCK` is on the allowlist, so local workers inherit the agent socket. SSH workers are unchanged. A `drive --isolated` grandchild inherits the filtered environment.
- `run.toml` gains `[launch]` (`threads`, `dir`, `dropped`) and stays schema 1. Detached `execute!` logs how many names were dropped. The names are in `detached_launch`, `[launch]`, and the debug log.
- In-process `execute!` and `julia -m DistSSHKit` are unchanged.
