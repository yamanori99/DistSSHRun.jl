category: changed

- Collect, `collect!`, and go slot pull pass rsync `--safe-links`, so a remote symlink that points outside the copied tree is not recreated locally. Pull-back stays rsync through 0.2.x; Tar pull-back waits until 0.3.0 because it would drop remote mtimes on outputs.
