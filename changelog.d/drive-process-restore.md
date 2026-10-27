category: fixed

- `drive` / `drive!` restore the active project and `DISTRIBUTED_PROJECT_ROOT`, `DISTRIBUTED_REMOTE_PROJECT_ROOT`, `DISTRIBUTED_OUTPUT_DIR`, and `DISTRIBUTED_RUNNER` when they return, including after an error or Ctrl-C. A second `main` in the same process runs. (#184, #185)
- Ctrl-C during `drive` still exits 130 after cleanup. A second Ctrl-C exits 130 and skips the rest of that cleanup. `drive!` rethrows the interrupt instead of exiting. On Julia 1.14 the caller task stays cancelled.
