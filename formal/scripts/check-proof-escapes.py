#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Adapted from MilesCranmer/julia-in-lean julia-base/scripts/check-proof-escapes.py
# (Apache-2.0). Strips Lean comments and string/char literals, then flags proof
# escapes and user `axiom` declarations.
"""Reject proof escapes in Lean code without treating quoted evidence as code."""
from __future__ import annotations

import sys
from pathlib import Path

FORBIDDEN = {"sorry", "admit", "native_decide", "bv_decide", "ofReduceBool", "axiom"}


def violations(source: str) -> list[tuple[int, str]]:
    found = []
    size = len(source)

    def report(offset, token):
        found.append((source.count("\n", 0, offset) + 1, token))

    def identifier_char(char):
        return char.isalnum() or char in "_'!?" or "\u0300" <= char <= "\u036f"

    def character_end(start):
        end = start + 1
        if end >= size or source[end] in "'\n":
            return None
        if source[end] == "\\":
            end += 1
            if end >= size:
                return None
            escape = source[end]
            end += 1
            if escape == "u" and end < size and source[end] == "{":
                close = source.find("}", end + 1)
                if close == -1:
                    return None
                end = close + 1
            elif escape in "xuU":
                digits = {"x": 2, "u": 4, "U": 8}[escape]
                value = source[end : end + digits]
                if len(value) != digits or any(
                    c not in "0123456789abcdefABCDEF" for c in value
                ):
                    return None
                end += digits
            else:
                end += 1
            return end + 1 if end < size and source[end] == "'" else None
        return None

    def string_end(start, quote, hashes, raw, interpolated):
        index = quote + 1
        closing = '"' + hashes
        while index < size:
            if source.startswith(closing, index):
                return index + len(closing)
            if not raw and source[index] == "\\":
                index += 2
            elif interpolated and source.startswith("{{", index):
                index += 2
            elif interpolated and source[index] == "{":
                index = code_end(index + 1, interpolation=True)
            else:
                index += 1
        report(start, "unterminated string")
        return size

    def code_end(index, interpolation=False):
        start = index
        braces = 0
        string_interpolation = False
        while index < size:
            char = source[index]
            if char.isspace():
                index += 1
                continue
            if source.startswith("--", index):
                newline = source.find("\n", index + 2)
                index = size if newline == -1 else newline + 1
                continue
            if source.startswith("/-", index):
                comment_start = index
                depth = 1
                index += 2
                while index < size and depth:
                    if source.startswith("/-", index):
                        depth += 1
                        index += 2
                    elif source.startswith("-/", index):
                        depth -= 1
                        index += 2
                    else:
                        index += 1
                if depth:
                    report(comment_start, "unterminated comment")
                continue
            if char == "r":
                quote = index + 1
                while quote < size and source[quote] == "#":
                    quote += 1
                if quote < size and source[quote] == '"':
                    index = string_end(
                        index, quote, source[index + 1 : quote], True, string_interpolation
                    )
                    string_interpolation = False
                    continue
            if char == '"':
                index = string_end(index, index, "", False, string_interpolation)
                string_interpolation = False
                continue
            if char == "'":
                end = character_end(index)
                if end is not None:
                    index = end
                    string_interpolation = False
                    continue
            if char == "«":
                end = source.find("»", index + 1)
                if end == -1:
                    report(index, "unterminated identifier")
                    return size
                token = source[index + 1 : end]
                if token in FORBIDDEN:
                    report(index, token)
                index = end + 1
                string_interpolation = False
                continue
            if char.isalpha() or char == "_":
                end = index + 1
                while end < size and identifier_char(source[end]):
                    end += 1
                token = source[index:end]
                if token in FORBIDDEN:
                    report(index, token)
                string_interpolation = token.endswith("!")
                if token.endswith("!r") and end < size and source[end] in '#"':
                    index = end - 1
                    string_interpolation = True
                    continue
                index = end
                continue
            string_interpolation = False
            if interpolation and char == "}":
                if braces == 0:
                    return index + 1
                braces -= 1
            elif char == "{":
                braces += 1
            index += 1
        if interpolation:
            report(start - 1, "unterminated interpolation")
        return size

    code_end(0)
    return found


def lean_roots(root: Path) -> list[Path]:
    paths = sorted((root / "DistSSHLean").rglob("*.lean"))
    for name in ("DistSSHLean.lean", "Audit.lean", "Report.lean", "ShellStatusBatch.lean"):
        path = root / name
        if path.is_file():
            paths.append(path)
    return paths


def scan(root: Path) -> int:
    files = lean_roots(root)
    problems = 0
    for path in files:
        for line, token in violations(path.read_text()):
            print(f"FAIL proof escape {path.relative_to(root)}:{line}: {token}")
            problems += 1
    print(f"PROOF ESCAPES files {len(files)} problems {problems}")
    return int(problems != 0)


def self_test() -> int:
    fixtures = Path(__file__).resolve().parent / "fixtures"
    good = (fixtures / "proof-escapes-pass.lean").read_text()
    bad = (fixtures / "proof-escapes-fail.lean").read_text()
    if violations(good):
        print("FAIL self-test: pass fixture must have zero violations")
        return 1
    bad_hits = violations(bad)
    if not bad_hits or not any(t in {"sorry", "native_decide"} for _, t in bad_hits):
        print(f"FAIL self-test: fail fixture should report sorry/native_decide, got {bad_hits}")
        return 1
    print("PROOF ESCAPES SELFTEST OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    root = Path(__file__).resolve().parent.parent
    return scan(root)


if __name__ == "__main__":
    sys.exit(main())