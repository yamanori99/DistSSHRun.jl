category: fixed

- At `:progress` with `--no-log`, `drive` releases the live bar before `main` so driver stdout and stderr stay on their original destinations (prompts stay visible; `2>file` is preserved). A separator before the finished bar is written only when that bar can draw, so redirected non-TTY stdout is not given an extra newline. The finished bar is drawn afterward on a later line, so markers are not glued onto the live row. Log-enabled `:progress` capture/replay is unchanged.
