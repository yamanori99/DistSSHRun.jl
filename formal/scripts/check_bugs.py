"""Validate bugs/*.yaml and check that each bug has a reproducer (from julia-in-lean)."""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML required (pip install pyyaml)")
    sys.exit(1)

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


def check(path: Path, theorems: set[str]) -> list[str]:
    try:
        bug = yaml.safe_load(path.read_text())
    except yaml.YAMLError as err:
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
    need((ROOT / "repro" / f"{path.stem}.jl").exists(), f"missing repro/{path.stem}.jl")
    return problems


def main() -> int:
    files = sorted((ROOT / "bugs").glob("*.yaml"))
    theorems = declared_theorems()
    problems = [p for f in files for p in check(f, theorems)]
    for p in problems:
        print(p)
    print(f"BUGS {len(files)} PROBLEMS {len(problems)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())