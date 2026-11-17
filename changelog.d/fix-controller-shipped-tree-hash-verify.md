category: fixed

- Shipped-tree verify: compare the controller project using the same send list as `setup ship-tree`, not the raw directory tarball hash.
- Shipped-tree verify: keep read-only and per-file digest checks on workers only, not the editable controller project.