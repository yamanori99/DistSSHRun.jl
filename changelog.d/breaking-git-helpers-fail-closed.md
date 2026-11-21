category: breaking

- **Local git helpers:** `clone_url_from_local_origin`, `get_local_git_hash`, and
  `local_git_clean` now throw when git fails on a tree that has `.git` metadata,
  matching `git_work_tree`. They still return their absent values (`nothing` / `true`)
  for paths that are not git work trees, and `clone_url_from_local_origin` still
  returns `nothing` when `origin` is missing. Callers that relied on corrupt
  repositories looking “clean” or “unavailable” now fail with git’s stderr and a fix hint.
