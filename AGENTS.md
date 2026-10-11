# Agents

Users run `julia -m DistSSHKit`. This repository is DistSSHRun.

Do not call `setup!(session, :delete)` or `setup!(session, :prune)`. `yes=true` still deletes without `--confirm-path`. Use the CLI.

Agents must not pass `-y`, `--yes`, or set `DISTSSHKIT_YES` for `setup --delete` or `setup --prune`. Use `--confirm-path` with the path the command printed.

Ask before editing `.coderabbit.yaml` or `.github/`.
