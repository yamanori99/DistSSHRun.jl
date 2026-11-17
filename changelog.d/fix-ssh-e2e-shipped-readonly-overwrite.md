category: fixed

- SSH E2E: remove remote `test/runtests.jl` before scp so `0444` shipped files can be replaced.
- SSH E2E: re-ship after setup phase so controller `content_tree_hash` matches deploy record before drive jobs (0.2.0 shipped-tree verify).
