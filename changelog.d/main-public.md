category: added

- `main` is public on DistSSHRun and is not exported. `julia -m DistSSHRun` still dispatches the same commands. DistSSHKit calls `DistSSHRun.main`.
