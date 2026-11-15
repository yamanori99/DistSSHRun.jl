category: breaking

- `resolve_pkg_project_dir` and new `current_project_file` follow
  `Base.current_project` (walk to `homedir()`, `JuliaProject.toml` before
  `Project.toml`, no depth cap). Vendored DistSSHKit/Queue/Run stubs are no
  longer skipped; use an explicit `--project` or `kit_project_root` where the
  kit checkout layout applies.
- New public resolvers in `DistSSHBase` / `DistSSHRun`: `manifest_path`,
  `local_preferences_path` (Base naming for `(Julia)LocalPreferences.toml`),
  `julia_sysimage_path`, `julia_default_sysimage_path`, and
  `julia_sysimage_is_default`.
- `drive`, `ride`, and `go` call `assert_controller_environment_for_verify!`
  before worker checks: existing Manifest digest gate,
  `Pkg.is_manifest_current` must be `true` (`false` and `nothing` fail closed
  with what/where/why/fix text), and the controller must use the default
  sysimage for its Julia build. `--unsafe-heterogeneous` waives only Manifest /
  Project byte digests, not these gates. Worker verification also compares
  resolved sysimage paths.