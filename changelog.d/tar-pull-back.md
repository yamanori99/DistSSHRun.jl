category: breaking

- Collect, `collect!`, and go slot pull-back use stdlib Tar instead of rsync. Original mtimes are not kept. Pull-back `touch`es extracted files. File modes are not kept: a non-executable file arrives as `0644`, and an executable file as `0755`. A symlink that points outside the copied tree is refused. The extract step uses an empty local directory. Remaining rsync is `push_cache!`. The remote Julia executable is `--julia`, or auto-detect.
