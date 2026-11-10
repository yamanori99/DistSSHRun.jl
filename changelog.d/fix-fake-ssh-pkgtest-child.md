category: fixed

- Registry `Pkg.test` no longer breaks arbitrary-dest ship tests: fake-SSH Julia children get `@:@stdlib` load path instead of inheriting the sandbox-only `JULIA_LOAD_PATH`.
- Ship prepare-dest failures now quote stderr and exit code, not stdout alone.
