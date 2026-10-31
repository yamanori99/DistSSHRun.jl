category: added

- `drive --isolated` runs the driver in a child Julia process. The default remains the current process. The child is started without the drive `--isolated` option. A later `--isolated` stays a script argument. The child keeps the parent's project and load path, and `DISTRIBUTED_PROJECT_ROOT` when the CLI resolved one. A child stopped by a signal is a failure.
