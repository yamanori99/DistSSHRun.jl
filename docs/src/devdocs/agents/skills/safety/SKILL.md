---
name: safety
description: >
  Design rules that are not a lint yet, plus releases, registration, and child-process source strings.
  Use when adding or changing behavior, a data format, a name, CLI, an exit code, a message, where
  environment variables are read, or the version, and when releasing or registering.
---

# Safety

When a rule becomes a lint or a test, delete that line here.

- Read the DistSSHKit releasing document before a pull request that raises the version or changes public behavior.
- Do not lower `version`. Root `[deps]` each have a `[compat]` with an upper bound. Do not use `0` or `>=` alone. A stdlib JLL `[compat]` must not start at a patch while `julia` starts at `x.y.0`.
- `DistSSHBase`, `DistSSHUp`, `DistSSHShip`, and `DistSSHHeartbeat` are not registered in General.
- Breaking registration notes include `breaking` or `changelog`, and point at `NEWS.md`.
- Do not write the Registrator register command in an issue, a pull request body, or a pull request comment. The only place for it is a comment on the merge commit, and only when the user asked to register.
- A child-process source string must not reference a module binding. Embed constants as values where the string is defined.
- Do not write a `.distssh-run` or `.distsshrun` marker. Teardown belongs to DistSSHQueue.
- Fail closed. Loosen only with an explicit flag or keyword, not with an environment variable.
- Do not silently remap an old key or flag. Error with the corrected form.
- One concept has one name. Do not add an alias. A public rename ships without a compatibility alias.
- A missing value is a typed reason. Versioned formats record the writer package and version; readers reject a different major.minor.
- CLI: missing operands print help on stderr and exit 2. Explicit help prints on stdout and exits 0. Other usage errors exit 2.
- Read process environment for job defaults in exactly one place per invocation. Job execution must not read `ENV` for those defaults.
- Each feature has one implementation. A second entry reaches that implementation, and a parity test covers the entries. Keep that test out of PkgEval.
- User-facing errors, hints, and help belong in the messages layer.
- If the cause is Julia or a dependency, report the commit or version. Do not copy an upstream function into this package to avoid it. Do not open an issue or a pull request on another repository.
- Do not pass a review fix by searching source for the condition you added. Run one call that failed before the fix.
- When a fix closes a hole, search for the same pattern elsewhere. Fix each match in the same pull request, or open an issue for it.
- A test for a bug that runs extra work also checks that the extra work did not happen. A success result alone does not show that.
