---
name: deslop
description: >
  Remove comments, trusted-path defensive checks, deep nesting, and other slop the diff added. Keep behavior.
  Use when a diff should match the surrounding code, including "clean up this diff" and "remove slop".
---

# Remove AI code slop

Check the diff against `main` and remove slop introduced in the branch.

- Extra comments that are unnecessary or inconsistent with the file.
- Defensive checks that are abnormal for a trusted path.
- Deeply nested code that should be simplified with an early return.
- Other patterns inconsistent with the file and the surrounding code.

Keep behavior unchanged unless fixing a clear bug. Prefer a small edit. Keep the final summary to a few sentences.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
