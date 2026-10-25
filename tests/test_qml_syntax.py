#!/usr/bin/env python3
"""Syntax-check every QML file before it can reach the panel.

Why this exists: a scripted edit to main.qml once closed a string literal early
(`title: "GPU UTILISATION"  ·  " + ...`). The collector and every Python test
still passed, the file still looked plausible, and the only symptom was the
renderer crash-looping with `Expected token ','` in the journal -- discovered
after a rebuild and a restart, on the live panel.

QML syntax errors are cheap to catch and expensive to miss. This runs the same
check in CI and locally, so the failure happens at commit time instead of on the
case screen.

Uses `qmllint` when available (Qt6). If it is not installed, falls back to a
structural check that still catches the common scripting damage: unbalanced
braces, brackets and parentheses, and unterminated string literals.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import unittest
from pathlib import Path

QML_DIR = Path(__file__).resolve().parent.parent / "renderer" / "qml"
QML_FILES = sorted(QML_DIR.glob("*.qml"))


def find_linter() -> str | None:
    for name in ("qmllint", "qmllint6", "qmllint-qt6"):
        p = shutil.which(name)
        if p:
            return p
    return None


def strip_qml_comments_and_strings(src: str) -> str:
    """Remove comments and string literals so bracket counting is meaningful.

    A brace inside a string ("GPU  ·  {" ) or a comment must not count.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        # Line comment
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        # Block comment
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        # String literal (double or single quoted, with backslash escapes)
        if ch in ("\"", "'"):
            quote = ch
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == quote:
                    i += 1
                    break
                if src[i] == "\n":
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_balanced(src: str) -> list[str]:
    """Return a list of structural problems found in the QML source."""
    problems = []
    stripped = strip_qml_comments_and_strings(src)
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in stripped:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                problems.append(f"line {line}: unmatched closing {ch!r}")
            elif stack[-1][0] != pairs[ch]:
                op, ln = stack.pop()
                problems.append(
                    f"line {line}: {ch!r} closes {op!r} opened at line {ln}"
                )
            else:
                stack.pop()
    for op, ln in stack:
        problems.append(f"line {ln}: unclosed {op!r}")
    return problems


def count_unterminated_strings(src: str) -> list[str]:
    """Flag string literals that run to end-of-line without closing."""
    problems = []
    for lineno, line in enumerate(src.splitlines(), 1):
        # Ignore comment-only tails so `// don't` is not a false positive.
        code = line
        for marker in ("//",):
            idx = code.find(marker)
            if idx >= 0:
                # naive but adequate: no QML string spans a // boundary here
                code = code[:idx]
        # Remove balanced "..." pairs, then see what is left.
        rest = []
        i = 0
        while i < len(code):
            if code[i] == "\\":
                i += 2
                continue
            if code[i] == '"':
                j = code.find('"', i + 1)
                if j == -1:
                    problems.append(f"line {lineno}: unterminated string")
                    break
                i = j + 1
                continue
            rest.append(code[i])
            i += 1
    return problems


class TestQmlSyntax(unittest.TestCase):
    def test_qml_files_exist(self):
        self.assertTrue(QML_FILES, f"no .qml files found in {QML_DIR}")

    def test_braces_balance(self):
        for f in QML_FILES:
            with self.subTest(file=f.name):
                problems = check_balanced(f.read_text(encoding="utf-8"))
                self.assertEqual(problems, [],
                                 f"{f.name}: " + "; ".join(problems))

    def test_strings_terminate(self):
        for f in QML_FILES:
            with self.subTest(file=f.name):
                problems = count_unterminated_strings(
                    f.read_text(encoding="utf-8"))
                self.assertEqual(problems, [],
                                 f"{f.name}: " + "; ".join(problems))

    def test_qmllint_clean(self):
        """Full parse via qmllint when it is installed.

        Skipped (not failed) when Qt6 tools are absent, so the suite still runs
        on a machine without Qt -- the structural checks above still apply.
        """
        linter = find_linter()
        if not linter:
            self.skipTest("qmllint not installed; structural checks only")
        for f in QML_FILES:
            with self.subTest(file=f.name):
                p = subprocess.run(
                    [linter, str(f)],
                    capture_output=True, text=True, timeout=60,
                )
                output = (p.stdout + p.stderr).strip()
                # qmllint exits non-zero on warnings too; only treat actual
                # parse errors as failures so the suite is not brittle against
                # unrelated style warnings.
                fatal = [
                    ln for ln in output.splitlines()
                    if "Expected token" in ln
                    or "Unexpected token" in ln
                    or "syntax error" in ln.lower()
                ]
                self.assertEqual(
                    fatal, [],
                    f"{f.name} has a QML parse error:\n{output}",
                )


if __name__ == "__main__":
    linter = find_linter()
    print(f"qmllint: {linter or 'NOT FOUND (structural checks only)'}")
    print(f"checking {len(QML_FILES)} files in {QML_DIR}")
    print()
    unittest.main(verbosity=2)
