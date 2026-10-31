category: breaking

- Every remote git command also passes `--no-optional-locks` and ephemeral `-c` for `advice.detachedHead=false`, `submodule.recurse=false`, `gc.auto=0`, and `core.autocrlf=false`. `safe.directory` is still not set. A remote project directory that is group-writable or world-writable is refused before checkout. `setup --clone` uses `umask 022`, so the tree it creates is not group-writable. A missing directory is not created by that check.
