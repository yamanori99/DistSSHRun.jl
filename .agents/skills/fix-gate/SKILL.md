---
name: fix-gate
description: After a failure, rerun scripts/check.sh on the commit to push.
---

# Fix gate

When a check fails:

1. Fix the failure.
2. Commit the fix.
3. Run `./scripts/check.sh` on that commit.
4. Repeat until one clean pass with no edits between the commit and the run.

`scripts/check.sh` runs `docs/make.jl` only when the diff touches `docs/` or a docstring line, and it does not pass `linkcheck`. Do not start the full `Pkg.test` matrix or SSH end-to-end from this skill. Do not add a separate fix-ci or loop-on-ci skill.
