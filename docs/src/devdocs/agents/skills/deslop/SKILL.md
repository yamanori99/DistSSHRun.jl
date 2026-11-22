---
name: deslop
description: >
  Remove what a diff added that the surrounding code does not do: extra comments, defensive checks on a trusted path, deep nesting. Keep behavior.
  Use when a diff should match the surrounding code, including "clean up this diff", "match the file's style", and "remove slop".
---

# Match the surrounding code

Compare the branch with `main`. Remove what the branch added that the rest of the file does not do.

- Comments that are unnecessary or that the rest of the file would not have.
- Defensive checks on a path whose input is already trusted. A check on user input, a file, the environment, or a remote host is not defensive. Keep it.
- Deep nesting that an early return makes flat.
- Other patterns that do not match the file and the code around it.

Keep behavior unchanged unless you are fixing a clear bug. Prefer a small edit. Keep the final summary to a few sentences.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
