category: changed

- Hosts no longer need `rsync`. `setup --check` looks for `ssh` and `git` only. Cache push, collect, and ship use stdlib Tar over SSH. Git clone, sync, and pull still need `git`.
