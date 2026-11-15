category: added

- `DistSSHBase.tool_require` is a family-internal helper (not public API). It
  loads a package with `Base.require` and fails when another loaded package shares
  the same name but a different UUID.