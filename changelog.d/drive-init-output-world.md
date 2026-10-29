category: fixed

- In-process `drive!` looks up `Main.init_output_dir!` with `invokelatest` after `include`. A stale world-age read of that binding warned on Julia 1.12+ and will error later.
