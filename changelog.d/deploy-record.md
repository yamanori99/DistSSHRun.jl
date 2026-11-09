category: added

- Setup (`git-clone`, `git-sync`, `git-pull`, `ship-tree`) writes the current
  deploy record to `<deploy_root>/.distssh/deploy.toml` (`schema = 1`). Run
  commands read it when resolving the remote work root (before the local
  last-snapshot convenience record), log deploy fields, emit stale-deploy warnings,
  and copy the record into run provenance. Transfer flags on go/drive are
  unchanged in this release.
