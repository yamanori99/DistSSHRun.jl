---
name: ci-triage
description: Triage pull request CI on the exact head SHA—quote first real error lines, classify PR-caused vs main-red vs flaky vs expected (missing breaking label).
---

# CI triage

## Scope

Read **every job** on the pull request **head SHA** only. For each failed job, quote the **first real error line** (not boilerplate).

## Classification

| Class | Meaning | Agent action |
|-------|---------|----------------|
| PR-caused | Failure is from this diff | Fix under the push gate |
| main already red | Same job failed on `main` at the cited base | Report job, URL, first error; do not fix here |
| flaky / infra | Transient runner or network | Report; agents cannot `gh run rerun` (`Resource not accessible by integration`); no empty commits to retrigger |
| expected | Missing `breaking` label with `category: breaking` fragment | Report; owner labels |

## VM limits

These run **CI-only** (no Docker, no `sshd` on the Cloud Agent VM):

- SSH E2E (Linux, macOS, WSL)
- PkgEval
- Downstream integration jobs

Do not sleep-loop for hours waiting on CI.

## Report format

One line per job:

```
<job>: <conclusion> - <class> - <first error line or url>
```