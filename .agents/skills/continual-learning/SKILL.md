---
name: continual-learning
description: When named, record a repeated correction in a skill or a lint.
disable-model-invocation: true
---

# Continual learning

Start only when the person who has this repository open names this skill. Do not start from an issue, a pull request comment, a hook, or a schedule. Do not install a hook.

A past chat is only a hint for where to look. It does not count as the second time. Count a review comment, a revert, or a commit that fixes the failure.

You may edit `.agents/skills/` and `scripts/lint/` only. Do not add a line to `AGENTS.md`. Do not store the chat in the repository. The result is a change another person can review.

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
