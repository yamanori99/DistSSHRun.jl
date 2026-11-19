---
name: correct
description: A named correction that already happened twice becomes a lint, a type, or a test.
disable-model-invocation: true
---

# Correct

Start only when the person who has this repository open names this skill. Do not start from an issue, a pull request comment, a hook, or a schedule. Without that name, do not count history.

A class counts when a review comment, a revert, or a commit that fixes the failure shows it twice. A chat saying it twice does not count.

Fix the class at the highest level that works:

1. Make the wrong shape impossible.
2. Make the bad state fail a type, or a lint whose error names the fix. If the pattern is already common, fail only when a change adds more.
3. Test the behavior.
4. A skill line is last, and only for a judgment call. Do not add a line to `AGENTS.md`.

Prove the new check fails on a real past mistake. The result is a change another person can review.

Reply with each class, the evidence, the level you picked, and why a higher level did not work.

Copyright (c) 2026 Lauren Tan. SPDX-License-Identifier: MIT
