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

- [ ] Breaking status is correct — a change PR has the `breaking` label
      when needed; a cut PR has the NEWS structure required by its version
      bump. Breaking includes CLI behavior: flags, confirmation, exit codes,
      what is deleted. See
      [DistSSHKit releasing](https://github.com/yamanori99/DistSSHKit.jl/blob/main/docs/src/developers/releasing.md).
- [ ] Version is correct — `Project.toml` `version` went up when this
      should ship, and stayed when it should not (CI reads the diff;
      register when the required checks are green; E2E weekly Intel / WSL
      watch; `cut-hold` if scheduled Linux is red)
- [ ] Remote / smoke is done, or this change does not need it
