category: fixed

- In-process `drive!` runs `init_output_dir!` only when this script defines it. A function left in `Main` by an earlier driver is not called, so a later script does not reuse that driver's output directory.
