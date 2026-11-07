category: fixed

- At `:progress` with `--no-log`, `drive` releases the live bar before `main` so driver stdout and stderr stay on their original destinations (prompts stay visible; `2>file` is preserved). The finished bar is drawn afterward on a later line, so markers are not glued onto the live row. Log-enabled `:progress` capture/replay is unchanged.
