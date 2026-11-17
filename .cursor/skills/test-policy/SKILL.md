---
name: test-policy
description: How to handle failing tests on the VM—reproduce with evidence, fix product not assertions; Julia/dep bugs are reported not worked around.
---

# Test policy

A failing test means the product is suspect. Reproduce, decide with evidence, then either fix the product or update a stale expectation to the **new exact value** and state which you chose.

## Never do this to get green

- Loosen assertions or compare loosely
- `@test_broken`, `@test_skip`, early `return`, env gates
- `try`/`catch` that swallow failures
- Retries, sleeps, or larger timeouts
- Deleting tests or accepting both old and new forms

## Julia or dependency bugs

If the failure is a bug in Julia or a dependency:

1. Report what fails, where (file/line or commit), how to reproduce, and any known upstream fix.
2. Wait for the owner to decide.
3. Do **not** work around it in this repo on your own.
4. Do **not** open issues, pull requests, or comments on other repositories.

## New behavior

Add or extend a test that **fails without** the change and passes with it.

## What to run on the VM

Run **targeted** test files on Julia **1.13** when your change needs them (`CONTRIBUTING.md`, `test/README.md`). The full matrix, SSH E2E, macOS, WSL, PkgEval, and downstream jobs are CI-only unless the user asks otherwise.