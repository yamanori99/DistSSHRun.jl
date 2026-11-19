---
name: no-comments
description: Judge comments in a diff. Do not spawn a subagent.
disable-model-invocation: true
---

# No comments

Use the caller's files or diff. Otherwise use the current diff against `main`, including the working tree.

A comment may stay only when it is a license notice, a public API docstring, or a constraint the code cannot state. A link is not a reason to keep it. `IMPORTANT` and `fine for now` are not reasons. A protocol quirk becomes a named function and a test, then the comment goes.

A `do not remove` comment must name the type, runtime check, test, or lint that replaces it. If it does not, delete it and report the constraint as open. Do not restore a comment whose keep was refuted.

Do not edit application code to make a comment look necessary. Report the deletion count and any constraint that is still open.

Copyright (c) 2026 Lauren Tan. SPDX-License-Identifier: MIT
