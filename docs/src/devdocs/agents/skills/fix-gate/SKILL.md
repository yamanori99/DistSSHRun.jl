---
name: fix-gate
description: >
  After scripts/check.sh or the pre-push hook fails, rerun scripts/check.sh on the commit to push.
  Use when push is blocked, including "pre-push hook failed" and "push is blocked".
---

# Fix gate

When a check fails:

1. Fix the failure.
2. Commit the fix.
3. Run `./scripts/check.sh` on that commit. Success ends with `HEAD <sha>: passed`. A line `FAIL  <step>` names the failing step; read the output below it.
4. Repeat until one clean pass with no edits between the commit and the run.

Do not amend the failing commit. A line that starts with `note:` is not a failure. A `pin:` failure means a pinned app is missing or at another version; do not install it unless the person asked.

The script builds the docs only when the diff touches `docs/` or a docstring line, and it does not run the link check. Do not start the full `Pkg.test` matrix or SSH end-to-end from this skill. Do not add a separate fix-ci or loop-on-ci skill.
