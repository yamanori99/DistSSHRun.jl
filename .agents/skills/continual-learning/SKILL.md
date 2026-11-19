---
name: continual-learning
description: Record a repeated correction in a skill or a lint. Slash command only.
disable-model-invocation: true
---

# Continual learning

Start only when the user explicitly invoked this skill with its slash command. Do not start from a task that merely seems to match, from an issue, a pull request comment, a hook, or a schedule. Do not install a hook.

A past chat is only a hint for where to look. It does not count as the second time. Count a review comment, a revert, or a commit that fixes the failure.

You may edit `.agents/skills/` and `scripts/lint/` only. Do not add a line to `AGENTS.md`. Do not store the chat in the repository. The result is a change another person can review.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
