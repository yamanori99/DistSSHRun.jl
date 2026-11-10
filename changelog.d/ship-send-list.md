category: added

- `ship_send_list(root)` returns the relative paths a ship tar contains for
  that directory, sorted. The list is the same with or without `.git`. Declared
  inputs and unshippable nodes stay out. It does not print the
  gitignored-project warning. The name is public and is not exported.
  `git_send_list` is the git list for `git-clone`, `git-sync`, and `git-pull`.
