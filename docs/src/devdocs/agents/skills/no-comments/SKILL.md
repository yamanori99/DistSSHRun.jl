---
name: no-comments
description: Judge comments in a diff. Do not spawn a subagent. Slash command only.
disable-model-invocation: true
---

# No comments

Start only when the user explicitly invoked this skill with its slash command. Do not start from a task that merely seems to match. Do not spawn a subagent.

Use the caller's files or diff. Otherwise use the current diff against `main`, including the working tree.

A comment may stay only when it is a license notice, a public API docstring, or a constraint the code cannot state. A link is not a reason to keep it. An all-caps reminder or a claim that a shortcut is acceptable for the moment is not a reason. A protocol quirk becomes a named function and a test, then the comment goes.

A `do not remove` comment must name the type, runtime check, test, or lint that replaces it. If it does not, delete it and report the constraint as open. Do not restore a comment whose keep was refuted.

Do not edit application code to make a comment look necessary. Report the deletion count and any constraint that is still open.

Copyright (c) 2026 Lauren Tan. SPDX-License-Identifier: MIT
