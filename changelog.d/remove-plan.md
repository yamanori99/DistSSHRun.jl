category: breaking

- `plan`, `KitPlan`, `PlanFinding`, `print_plan`, and the `plan` command are removed. Callers get `UndefVarError`. Root help, the unknown-subcommand list, and the no-command hint lines no longer name `plan`. `drive` no longer warns on a file with no Distributed vocabulary.
