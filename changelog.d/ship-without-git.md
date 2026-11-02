category: breaking

- `--ship-tree` no longer needs a git work tree. The send list is a walk of the project that applies each directory's `.gitignore` (case-sensitive; `core.ignorecase` is not used). `.git/info/exclude`, `core.excludesFile`, and a `.gitignore` above the project are not used. Tracked files that match `.gitignore` are not sent. Path sources follow the same walk. Matching is GitIgnore 0.1.1. As of 2026-11-02, treat send-list mismatches as possible matcher bugs. `rsync_send_list` is still the git list.
