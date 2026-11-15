category: added

- `tool_require` is public on DistSSHBase and is not exported. It loads a package
  with `Base.require` and fails when another loaded package shares the same name
  but a different UUID.