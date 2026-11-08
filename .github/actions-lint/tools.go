//go:build tools

// Blank imports keep actionlint and pinact as direct go.mod requires so
// Dependabot's gomod updater can bump them. Prefer this over a `tool`
// directive until Dependabot supports those (dependabot-core#12050).

package tools

import (
	_ "github.com/rhysd/actionlint/cmd/actionlint"
	_ "github.com/suzuki-shunsuke/pinact/v5/cmd/pinact"
)
