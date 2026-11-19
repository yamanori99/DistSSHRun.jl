---
name: verify-this
description: >
  Restate one claim, run it, and return VERIFIED, NOT VERIFIED, or INCONCLUSIVE.
  Use when an effect has to be run to be believed, including "did this actually get faster".
---

# Verify this

Verification proves or disproves one claim. Do not use it for "the code is cleaner".

For one feature, say what exists, how to run it, and where a run can lie. Then:

1. Restate the claim so a run can falsify it.
2. Pick the smallest local command that can disprove it. Do not start the full `Pkg.test` matrix or SSH end-to-end unless the user asked.
3. Capture a baseline and the changed state with the same command.
4. Return exactly one of `VERIFIED`, `NOT VERIFIED`, or `INCONCLUSIVE`.

`VERIFIED` means the change moved the way the claim said, with no obvious confound. `NOT VERIFIED` means it did not. `INCONCLUSIVE` means the baseline, the noise, or the environment made the comparison invalid. Name the OS. When the claim depends on `ssh` or process start time, the other OS does not count.

```text
VERIFIED | NOT VERIFIED | INCONCLUSIVE
Claim: <one sentence>

Evidence:
<what ran>: baseline=<...>, treatment=<...>, delta=<...>

Reasoning:
<one paragraph, including the OS>
```

Copyright (c) 2026 Cursor. SPDX-License-Identifier: MIT
