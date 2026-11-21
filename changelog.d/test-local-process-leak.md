category: skip
no user-facing change

- A test file fails when a local process it started is still running, then that process is killed. The second Ctrl-C worker leak stays broken.
