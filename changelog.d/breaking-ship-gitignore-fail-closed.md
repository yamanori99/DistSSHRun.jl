category: breaking

- **Ship and git send list:** refuse POSIX paths with a backslash, an unreadable
  `.gitignore`, a symlinked `.gitignore`, or a git repository git cannot resolve
  (`git_work_tree`, broken gitlinks). Previously some cases were dropped or sent
  unfiltered. Messages name the path and one fix command. Healthy trees keep the
  same file set.