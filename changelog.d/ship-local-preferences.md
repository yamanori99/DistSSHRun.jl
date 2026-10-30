category: breaking

- `LocalPreferences.toml` and `JuliaLocalPreferences.toml` next to a shipped `Project.toml` are included in the ship tree even when gitignored. A non-empty depot `artifacts/Overrides.toml`, or a non-empty `@v#.#` preference file in the first depot, refuses the ship. Those depot files are hashed in the error and are not copied into the project.
