---
name: deslop
description: Remove extra comments and defensive checks that the diff added on a trusted path. Keep behavior.
---

# Remove AI code slop

Check the diff against `main` and remove slop introduced in the branch.

- Extra comments that are unnecessary or inconsistent with the file.
- Defensive checks that are abnormal for a trusted path.
- Deeply nested code that should be simplified with an early return.
- Other patterns inconsistent with the file and the surrounding code.

Keep behavior unchanged unless fixing a clear bug. Prefer a small edit. Keep the final summary to a few sentences.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
