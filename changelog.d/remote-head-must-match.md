category: planned

- `setup --sync`, `setup --pull`, and `sync!` will fail when the remote `HEAD` is not the local `HEAD`, including an unpushed local commit on `--pull`. 0.1.7 warns. A hash that could not be read stays a warning.
