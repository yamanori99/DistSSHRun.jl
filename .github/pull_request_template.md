# Pull request

## Summary

<!-- What / why -->

## Testing

<!-- The command that ran, and what it returned. If nothing ran, say why. -->

## Risk

<!-- Name what this can break. Do not grade it. -->

## Revert

<!-- How to undo this after it merges. -->

## Checklist

- [ ] A removed public name appears as an identifier in a changelog fragment
      bullet in this pull request. Do not add a `breaking` label.
      A cut PR runs `./.github/news-collect.sh` and keeps the NEWS section
      required by its version bump. See
      [DistSSHKit releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md).
- [ ] News fragment — this PR adds one `changelog.d/*.md` file when it
      changes `src/`, `lib/**/src/`, or `ext/`. Docs, tests, and CI do not
      need one. A cut PR assembles fragments and does not add a new one.
- [ ] Version is correct — `Project.toml` `version` went up when this
      should ship, and stayed when it should not (CI reads the diff;
      register when the required checks are green; E2E weekly Intel / WSL
      watch; `cut-hold` if scheduled Linux is red)
- [ ] Remote / smoke is done, or this change does not need it
