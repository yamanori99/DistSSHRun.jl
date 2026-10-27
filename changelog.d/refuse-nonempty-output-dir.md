category: breaking

- `go`, `ride`, and `drive` refuse a non-empty output directory, a file, or a symlink. The error names that directory and the files in it. On the CLI the next line is `help go`, `help ride`, or `help drive`. An empty directory is kept, and a missing path is created. Omitting the directory still allocates a fresh one.
- `go!` applies this to `output_dir` and to `collect_spec` when that value is a path. `ride!` applies it to the output directory. `drive` applies it to the directory chosen after `init_output_dir!`. Detached `execute!` applies it to an explicit `output_dir` before the child starts.
- Demos that used a fixed `output/` directory take a new empty directory when that one already has files, so a second run still runs.
