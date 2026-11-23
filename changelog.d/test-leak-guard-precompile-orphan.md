category: skip
no user-facing change

- Parallel CI: the leak guard ignores Julia incremental precompile orphans that still carry `DISTSSH_TEST_LEAK_TAG`, matching the existing `--worker` orphan rule. Reparent detection no longer requires `ppid == 1`; WSL2 subreaper parents are covered.
