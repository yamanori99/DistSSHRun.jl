category: breaking

- A non-empty depot `artifacts/Overrides.toml`, or a non-empty `@v#.#` preference file in the first depot, refuses the ship. Those depot files are hashed in the error and are not copied into the project. `git_send_list` is the git send list. Project preference files follow `.gitignore`: a gitignored `LocalPreferences.toml` is not forced into the ship tar. Add `!LocalPreferences.toml` to ship it. A symlink at that path is shipped as a symlink.
