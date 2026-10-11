"""Delimiter-balance check for Dart sources (no Dart SDK needed).

Catches the classic phone-editing mistakes (a missing `)` / `}` / `]`) before CI spends
minutes on `flutter analyze`. It understands comments (including nested /* */), single and
triple quoted strings, raw strings and `${...}` interpolation. It does NOT type-check.

Usage: python tools/dart_balance.py main.dart store.dart ...
"""
from __future__ import annotations

import sys
from pathlib import Path

OPEN = "([{"
CLOSE = {")": "(", "]": "[", "}": "{"}


class Scanner:
    def __init__(self, src: str) -> None:
        self.src = src
        self.n = len(src)
        self.errors: list[str] = []

    def line(self, i: int) -> int:
        return self.src.count("\n", 0, i) + 1

    def err(self, i: int, msg: str) -> None:
        self.errors.append(f"line {self.line(i)}: {msg}")

    def skip_line_comment(self, i: int) -> int:
        j = self.src.find("\n", i)
        return self.n if j < 0 else j

    def skip_block_comment(self, i: int) -> int:
        depth = 0
        while i < self.n:
            if self.src.startswith("/*", i):
                depth += 1
                i += 2
            elif self.src.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        self.err(i, "unterminated /* comment")
        return self.n

    def skip_string(self, i: int) -> int:
        """i points at the opening quote (or at the r of a raw string)."""
        src = self.src
        raw = src[i] == "r"
        if raw:
            i += 1
        q = src[i]
        triple = src.startswith(q * 3, i)
        start = i
        i += 3 if triple else 1
        end = q * 3 if triple else q
        while i < self.n:
            if src.startswith(end, i):
                return i + len(end)
            c = src[i]
            if not raw and c == "\\":
                i += 2
                continue
            if not raw and c == "$" and i + 1 < self.n and src[i + 1] == "{":
                i = self.scan_code(i + 2, interpolation=True)
                continue
            if c == "\n" and not triple:
                self.err(start, "unterminated string")
                return i
            i += 1
        self.err(start, "unterminated string")
        return self.n

    def scan_code(self, i: int, interpolation: bool = False) -> int:
        src = self.src
        stack: list[tuple[str, int]] = []
        while i < self.n:
            c = src[i]
            if src.startswith("//", i):
                i = self.skip_line_comment(i)
                continue
            if src.startswith("/*", i):
                i = self.skip_block_comment(i)
                continue
            if c in "'\"":
                i = self.skip_string(i)
                continue
            if c == "r" and i + 1 < self.n and src[i + 1] in "'\"" and not (
                i > 0 and (src[i - 1].isalnum() or src[i - 1] in "_$")
            ):
                i = self.skip_string(i)
                continue
            if c in OPEN:
                stack.append((c, i))
            elif c in CLOSE:
                if not stack:
                    if interpolation and c == "}":
                        return i + 1
                    self.err(i, f"unexpected '{c}'")
                else:
                    opener, at = stack.pop()
                    if opener != CLOSE[c]:
                        self.err(i, f"'{c}' closes '{opener}' opened at line {self.line(at)}")
            i += 1
        for opener, at in stack:
            self.err(at, f"'{opener}' never closed")
        if interpolation:
            self.err(i, "unterminated ${ interpolation")
        return i


def check(src: str) -> list[str]:
    sc = Scanner(src)
    sc.scan_code(0)
    return sc.errors


def main(argv: list[str]) -> int:
    bad = 0
    for name in argv:
        errors = check(Path(name).read_text(encoding="utf-8"))
        if errors:
            bad += 1
            print(f"FAIL {name}")
            for e in errors[:20]:
                print("   ", e)
        else:
            print(f"ok   {name}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
