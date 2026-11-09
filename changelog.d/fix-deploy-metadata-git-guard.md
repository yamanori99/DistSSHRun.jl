category: fixed

- Remote `setup git-sync` / `git-pull` ignore untracked `.distssh/` deploy metadata when checking for a dirty tree, so a written deploy record no longer blocks the next checkout.
- Refuse checkout when the target commit already tracks `.distssh/` and untracked deploy metadata is still on disk (collision).
