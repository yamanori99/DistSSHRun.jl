# CLI conventions

DistSSHRun and `julia -m DistSSHKit` follow the same exit conventions as Rust
[clap](https://docs.rs/clap), especially
[`Arg::required` / `arg_required_else_help`](https://docs.rs/clap/latest/clap/struct.Arg.html#method.required):

| Situation | Output stream | Exit code |
| --- | --- | --- |
| No arguments on a command that needs operands or flags (`go`, `ride`, `drive`, `up`, `setup`, or the top-level driver with no subcommand) | Full `--help` text on **stderr** | **2** |
| Explicit `--help` / `-h` | Same help text on **stdout** | **0** |
| Usage error (unknown flag, missing operand, bad combination) | Error and a short hint on **stderr** | **2** |
| Runtime failure (SSH error, job failure, missing file, …) | Diagnostics on **stderr** (command-specific) | **1** (unless documented below) |
| Ctrl-C in the foreground | — | **130** |
| Broken pipe (EPIPE) while writing | — | **141** |
| Opt-in worker heartbeat: controller silent past deadline | — | **75** |

Display commands whose bare invocation is already meaningful keep their
defaults: `hostinfo`, `pool`, `setup requirements`, `progress` (uses the
current directory when no path is given), and similar.

`doctor` will follow the same table in a separate change.