---
name: push-gate
description: Run the mandatory pre-push gate (Runic, trailing newlines, whitespace, JETLS) via ./.github/agent-check.sh after committing; paste the script last line in the report.
---

# Push gate

Mandatory push gate (Takanori, 2026-11-17), applies to every push from now on:

1. Commit everything first (the gate needs a clean tree: no staged, unstaged or untracked files). After your LAST edit, run all of these on the exact committed tree you will push:
   - `runic --check --diff .` (Runic pinned in `.github/runic-version`; whole repo, same as CI incl. `.github`, bench, demos)
   - trailing-newline audit on every changed file (exactly one final newline; your editor may strip it)
   - `git diff --check origin/main...HEAD`
   - `./.github/jetls-check.sh` (both settings CI uses)
   Where `.github/agent-check.sh` exists, it runs all four in one command; use it.
2. If anything fails, fix it, commit, and rerun ALL four from the start. Repeat until one full pass is clean with no edits in between.
3. Push only that verified tree. Any edit after the clean pass (even a newline or a PR-body-driven tweak) means rerun all four before pushing.
4. In your report, state the commit SHA and that all four passed on it.

## How to run

```bash
./.github/agent-check.sh
```

Optional base ref:

```bash
./.github/agent-check.sh --base "$(git merge-base HEAD origin/main)"
```

After a full pass, paste the script **last line** into your report (for example `agent-check: all four push-gate checks passed on <sha>`).
