category: breaking

- `drive --run-id` and `ride --run-id` compare Project.toml using the deploy
  record `project_hash` (raw file SHA-256, same as worker `project.sha256` and
  `manifest_hash`), not the git blob digest in `content_file_digests`.
  Re-run `setup ship-tree` so remote `.distssh/deploy.toml` includes
  `project_hash`. `--unsafe-skip-env-digests` waives Manifest/Project digest
  checks on this path (recorded as unverified).
