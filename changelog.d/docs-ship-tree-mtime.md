category: changed

- `help setup`, the home page, README, and `setup!` state that `--ship-tree` needs a git work tree and that git decides what is sent (`git ls-files --cached --others --exclude-per-directory=.gitignore`; `.git/info/exclude` and `core.excludesFile` are not used). Original mtimes are not kept. Pull-back `touch`es extracted files. Ship does not `touch`; files keep the extract-time mtime. Remaining rsync is `push_cache!`. Collect and slot pull-back use Tar. The git-work-tree error names the same `ls-files` command.
