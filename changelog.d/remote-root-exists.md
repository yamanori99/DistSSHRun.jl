category: breaking

- `remote_root` must already exist on the host, be owned by the SSH user, and not be group-writable or world-writable. A missing root is an error. The ship does not create it from `$HOME` or the environment, and it does not write a marker file. `runs/<run_id>/src/` is still created under that existing root.
