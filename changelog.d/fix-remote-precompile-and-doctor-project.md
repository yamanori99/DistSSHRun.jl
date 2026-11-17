category: fixed

- Drive and ride keep SSH workers when the shipped project is not writable on the worker. Precompile is skipped there; a missing remote path is not treated as a precompile failure.
- `pipeline!` runs when head workers were not set.
- `doctor` uses the same project root as the other CLIs (`DISTRIBUTED_PROJECT_ROOT`, otherwise the job root).
