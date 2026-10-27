category: breaking

- `setup --delete` and `setup --prune` no longer treat `-y`, `--yes`, or `DISTSSHKIT_YES` as permission to delete. Without `--confirm-path`, those switches exit 1 and the message names `--confirm-path` (`help setup`). With neither `-y` nor `--confirm-path`, the commands still ask for `delete` or `prune`. A matching `--confirm-path` still deletes.
