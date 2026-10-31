category: fixed

- `warn_openrsync_once` inspects the rsync cache pull will spawn, not the first `rsync` on PATH. A `DISTSSHKIT_TEST_RSYNC` double is `sh` plus a script, so unit tests no longer warn on GitHub `macos-latest` (Apple openrsync) while Homebrew GNU rsync on a local Mac never did.
