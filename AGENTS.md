# Agents

Users run `julia -m DistSSHKit`. This repository is DistSSHRun.

Do not call `setup!(session, :delete)` or `setup!(session, :prune)`. `yes=true` still deletes without `--confirm-path`. Use the CLI.

Agents must not pass `-y`, `--yes`, or set `DISTSSHKIT_YES` for `setup --delete` or `setup --prune`. Use `--confirm-path` with the path the command printed.

Read [DistSSHKit releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md) before a pull request that raises the version or changes public behavior.

Label a pull request `breaking` when it changes public behavior, including the CLI (flags, confirmation, exit codes, what is deleted). Do not mix a breaking change with other changes.

Ask before editing `.coderabbit.yaml` or `.github/`.
