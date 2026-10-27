category: fixed

- A Julia path passed to `get_remote_julia_version` is one quoted remote shell word, so a path that contains spaces is not split. A leading `~/` is sent as `$HOME/`. A `$HOME/…` prefix still expands on the remote. A backtick, double quote, backslash, or any other `$` in that word is escaped.
