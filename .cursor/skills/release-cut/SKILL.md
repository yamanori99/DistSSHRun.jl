---
name: release-cut
description: Version cut workflow—milestone check, version-cut.sh lockstep, news-collect, push gate; see DistSSHKit releasing.md for full procedure.
---

# Release cut

The full procedure lives in DistSSHKit [Releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md). Read that document; do not treat this skill as a copy.

## Agent steps (DistSSHRun)

1. **Milestone** — Confirm the target milestone has no open issues except owner-marked manual ones; otherwise stop.
2. **Versions** — After setting the new `Project.toml` version, run:
   ```bash
   ./.github/version-cut.sh --lockstep-write X.Y.Z
   ```
   (`--lockstep-write` updates lib `version` and compat pins; verify flags in `./.github/version-cut.sh --self-test`.)
3. **NEWS** — Run `./.github/news-collect.sh` (not a new `changelog.d` fragment on a cut PR).
4. **Commit scope** — The cut commit should touch only `Project.toml`, `NEWS.md`, `changelog.d`, and compat-related files as required by the scripts.
5. **Push gate** — `./.github/agent-check.sh`, then open/update the PR and triage CI per `ci-triage`.

## Register order

Run → Queue → Kit, each after General has registered the previous package.

## Registrator

**Never** write the Registrator register command in issues, pull request bodies, or comments. The owner registers after merge when checks are green.