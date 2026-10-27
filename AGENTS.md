# Agents

Users run `julia -m DistSSHKit`. This repository is DistSSHRun.

Do not call `setup!(session, :delete)` or `setup!(session, :prune)` unless `confirm_path` is a path the user typed. `yes=true` does not delete. Never copy the target out of an error, including `ConfirmPathMismatch`, into a retry.

Agents must not pass `-y`, `--yes`, or set `DISTSSHKIT_YES` for `setup --delete` or `setup --prune`. That combination is an error. Use `--confirm-path` with the path the command printed.

Read [DistSSHKit releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md) before a pull request that raises the version or changes public behavior.

Fill [.github/pull_request_template.md](.github/pull_request_template.md). Write Testing and Revert from the command that ran and what it returned. Risk names what can break, not a grade. Do not paste the type-label procedure into the body. The check applies the label. The order is in that releasing doc: closing issue, then branch prefix, then a Conventional Commit title, else `chore` when the diff has no `src/`, `ext/`, or root `Project.toml`. A version cut uses `cut` instead of a type label.

When reviewing a diff, follow [REVIEW.md](REVIEW.md).

Label a pull request `breaking` when it changes public behavior, including the CLI (flags, confirmation, exit codes, what is deleted). Do not mix a breaking change with other changes.

Ask before editing `.coderabbit.yaml` or `.github/`.

Do not write the Registrator register command in an issue, a pull request body, or a pull request comment. That text registers the package. The only place for it is a comment on the merge commit, and only when the user asked to register.
