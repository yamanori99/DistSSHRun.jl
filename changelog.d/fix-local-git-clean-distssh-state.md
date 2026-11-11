category: fixed

- `local_git_clean` and `setup check` ignore untracked or modified paths under `.distssh/`, legacy `.distsshkit/`, and `.distsshqueue/`, matching `git_source_snapshot`. Setup progress under `.distssh/setup` no longer fails the local git preflight when those directories are absent from `.gitignore`.
- `demo install` copies a `.gitignore` that lists both `.distssh/` and `.distsshkit/`.
