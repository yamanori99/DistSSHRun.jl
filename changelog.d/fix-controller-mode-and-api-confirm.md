category: fixed

- Controller shipped-tree verify compares the ship send list and file digests. Read-only `0444` / `0555` checks stay on the extracted worker tree.
- `setup!` and `sync!` from the Julia API do not prompt. The setup CLI still prompts unless `--yes`.
