category: breaking

- `setup --juliaup` and `setup --juliaup-update` are errors. Use `up add CHANNEL`, `up update`, and `up default CHANNEL`. `setup!(session, :juliaup)` and `:juliaup_update` are unchanged. `setup --remote-dir` is an error; use `--deploy-root`.
