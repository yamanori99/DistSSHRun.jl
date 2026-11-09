category: fixed

- Fix deploy record upload (`scp` local-then-remote, expanded path, atomic `deploy.toml.tmp` install) and surface write/read staleness warnings instead of swallowing failures.
- `DistSSHBase._path_under_resolved` follows symlinks so in-tree links to outside paths are not treated as inside the project root.
