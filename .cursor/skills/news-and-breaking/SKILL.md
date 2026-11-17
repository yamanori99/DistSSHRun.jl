---
name: news-and-breaking
description: changelog.d fragment rules, valid categories, and when a PR needs the breaking label (report only; never apply labels).
---

# NEWS and breaking

## When a fragment is required

Add one new `changelog.d/<slug>.md` when the pull request changes:

- `src/**`
- `lib/**/src/**`
- `ext/**`

Docs, tests, and CI-only edits do not require a fragment. A version **cut** PR runs `./.github/news-collect.sh` instead of adding a fragment.

## Fragment format

Validated by `./.github/news-collect.sh --validate FILE` and `./.github/news-fragment.sh`:

```
category: <breaking|planned|added|fixed|changed|skip>
<blank line>
- <one bullet of user-facing text>
<exactly one trailing newline>
```

Slug file name: `[a-z0-9][a-z0-9.-]{0,60}.md`.

To list valid categories from the repo tooling:

```bash
./.github/news-collect.sh --self-test
./.github/news-fragment.sh --self-test
```

## Breaking

Treat as **breaking** when public behavior changes, including:

- CLI flags, defaults, confirmation prompts, exit codes, error types
- Removals and renames (no compatibility aliases)
- Anything you are unsure about — default to breaking

`category: breaking` in a **new or edited** fragment means the pull request needs the `breaking` label. **Agents never add or remove labels.** Report: `This PR needs the breaking label`. A red **NEWS section** check only for a missing label is expected until the owner applies it.

Never downgrade a fragment category to get green. Never edit `NEWS.md` in ordinary feature pull requests.