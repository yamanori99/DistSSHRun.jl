"""Validate bugs/*.yaml and check that each bug has a reproducer (from julia-in-lean)."""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRIORITIES = {"P0", "P1", "P2", "P3"}
KINDS = {
    "wrong-result",
    "wrong-exception",
    "missing-error",
    "crash",
    "hang",
    "documentation",
    "model-counterexample",
}
TEXT = [
    "title",
    "area",
    "summary",
    "likelihood",
    "maybe_intended",
    "reproducer",
    "expected",
    "promised_by",
    "cause",
    "possible_fix",
]


def declared_theorems() -> set[str]:
    decl = re.compile(r"^\s*(?:private\s+|protected\s+)?theorem\s+([^\s:({\[]+)", re.M)
    return {
        name.rsplit(".", 1)[-1]
        for f in (ROOT / "DistSSHLean").rglob("*.lean")
        for name in decl.findall(f.read_text(errors="ignore"))
    }


def theorem_known(theorems: set[str], name: str) -> bool:
    short = name.rsplit(".", 1)[-1]
    return name in theorems or short in theorems


def check(path: Path, theorems: set[str], yaml_mod) -> list[str]:
    try:
        bug = yaml_mod.safe_load(path.read_text())
    except yaml_mod.YAMLError as err:
        return [f"{path.name}: invalid YAML: {err}"]
    if not isinstance(bug, dict):
        return [f"{path.name}: top level is not a mapping"]
    problems = []

    def need(cond: bool, msg: str) -> None:
        if not cond:
            problems.append(f"{path.name}: {msg}")

    need(bug.get("id") == path.stem, f"id {bug.get('id')!r} does not match the file name")
    need(bug.get("priority") in PRIORITIES, f"priority {bug.get('priority')!r} not in {sorted(PRIORITIES)}")
    need(bug.get("kind") in KINDS, f"kind {bug.get('kind')!r} not in {sorted(KINDS)}")
    for key in TEXT:
        need(isinstance(bug.get(key), str), f"{key} missing or not a string")
    for key in ["files", "functions"]:
        need(isinstance(bug.get(key), list) and bug[key], f"{key} missing or empty list")
    output, reproduced = bug.get("output"), bug.get("reproduced")
    for version in ["release", "nightly"]:
        need(
            isinstance(output, dict) and isinstance(output.get(version), str),
            f"output.{version} missing",
        )
        need(
            isinstance(reproduced, dict) and isinstance(reproduced.get(version), bool),
            f"reproduced.{version} missing or not a bool",
        )
    dups = bug.get("duplicates")
    need(
        isinstance(dups, dict)
        and isinstance(dups.get("issues"), list)
        and isinstance(dups.get("queries"), list)
        and dups["queries"],
        "duplicates needs issues (list) and non-empty queries (list)",
    )
    lean = bug.get("lean")
    need(
        isinstance(lean, dict) and isinstance(lean.get("property"), str) and isinstance(lean.get("theorem"), str),
        "lean.property and lean.theorem required",
    )
    if isinstance(lean, dict) and isinstance(lean.get("theorem"), str):
        thm = lean["theorem"]
        need(theorem_known(theorems, thm), f"lean.theorem {thm!r} not in DistSSHLean")
    need((ROOT / "repro" / f"{path.stem}.jl").exists(), f"missing repro/{path.stem}.jl")
    return problems


def self_test() -> int:
    import yaml as yaml_mod

    theorems = declared_theorems()
    body = """
id: selftest-bad
priority: P2
kind: wrong-result
title: t
area: a
summary: s
likelihood: low
maybe_intended: "no"
reproducer: repro/x.jl
expected: e
promised_by: p
cause: c
possible_fix: f
files:
  - lib/DistSSHBase/src/ssh/shell_status.jl
functions:
  - shell_status
output:
  release: r
  nightly: n
reproduced:
  release: false
  nightly: false
duplicates:
  issues: []
  queries:
    - q
lean:
  property: fake
  theorem: totally_nonexistent_theorem_xyz
""".lstrip()
    repro_dir = ROOT / "repro"
    repro_dir.mkdir(exist_ok=True)
    repro = repro_dir / "selftest-bad.jl"
    repro.write_text('println("ok")\n')
    yaml_path = ROOT / "bugs" / "selftest-bad.yaml"
    (ROOT / "bugs").mkdir(exist_ok=True)
    try:
        yaml_path.write_text(body)
        problems = check(yaml_path, theorems, yaml_mod)
    finally:
        yaml_path.unlink(missing_ok=True)
        repro.unlink(missing_ok=True)

    if not any("lean.theorem" in p for p in problems):
        print(f"FAIL self-test: expected lean.theorem error, got {problems}")
        return 1
    print("SELFTEST bugs unknown lean.theorem rejected")
    print("BUGS SELFTEST OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    files = sorted((ROOT / "bugs").glob("*.yaml"))
    if not files:
        print("BUGS 0 PROBLEMS 0")
        return 0

    try:
        import yaml
    except ImportError:
        print("FAIL: PyYAML required for bugs/*.yaml (pip install pyyaml)")
        return 1

    theorems = declared_theorems()
    problems = [p for f in files for p in check(f, theorems, yaml)]
    for p in problems:
        print(p)
    print(f"BUGS {len(files)} PROBLEMS {len(problems)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())