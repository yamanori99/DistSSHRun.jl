# Review

DistSSHRun is the run layer. DistSSHKit reexports it, and most users add
DistSSHKit. DistSSHQueue and DistSSHKit both build on its public names,
command line, and files. Comment only on bugs and regressions that this
diff introduces. Formatting, types, lint rules, the pull request body,
and labels are checked by CI. Do not repeat them.

Start the summary with the number of findings. When it is zero, say
there is nothing to fix. Cite a file and a line in the diff for each
finding. Do not guess from a name. Do not repeat a finding already
posted.

## Questions

Ask these of every diff.

1. Does every input path this diff touches still reject a missing, malformed, or old-form value with an error, with no new fallback, alias, silent default, skip, or allowlist entry?
2. Does this diff change a public name, a command-line flag, an exit code, a message, a file this package writes or reads, or other behavior that DistSSHQueue or DistSSHKit relies on, without a changelog fragment in this pull request that says so?
3. Does any manual page, README, docstring, help text, error hint, or changelog fragment now say something the changed code does not do?

## Where they apply here

- Question 1: a value that reaches a remote shell goes through the shared
  quoting helper. A host that starts with `-` (including `user@-host`), or
  a host or path that contains a control character, is rejected before
  `ssh` runs.
- Question 1: delete and prune remove only a path the user confirmed
  (`--confirm-path`). A yes flag or variable (`-y`, `--yes`,
  `DISTSSH_YES`) never stands in for it. A host without its own confirmed
  path is not deleted.
- Question 2: a removed or renamed public name appears as an identifier in
  a changelog fragment bullet. Teardown and the run marker belong to
  DistSSHQueue. This package writes no run marker.
- Question 3: the controller's run record and the remote shipped-tree
  stamp are different files. A user doc says to add DistSSHKit, not
  DistSSHRun.

## Pre-existing

A finding outside this diff stays out of this pull request. List it
here, one line each, with file:line, and do not ask for a fix.
