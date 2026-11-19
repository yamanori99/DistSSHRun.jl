---
name: tdd
description: Write the failing test first when that test is cheap.
disable-model-invocation: true
---

# TDD

Use this when the user asks for a failing test, or when the bug has an obvious cheap local test. Skip it when the only check is SSH end-to-end or the full `Pkg.test` matrix.

1. Name the intended behavior and the smallest reproduction.
2. Write the smallest test that would have caught the bug.
3. Run it and confirm it fails for that reason.
4. Make the smallest production change.
5. Run the test again and confirm it passes.

Prefer no new test over a test that only encodes the current implementation or needs expensive infrastructure. Do not weaken an existing assertion unless the intended behavior changed. Report the failing-before run and the passing-after run. If you could not show the failure first, say why.

Copyright (c) 2026 Lauren Tan. SPDX-License-Identifier: MIT
