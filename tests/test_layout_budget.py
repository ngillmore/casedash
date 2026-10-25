#!/usr/bin/env python3
"""Verify the case screen's vertical layout budget.

The panel is a fixed 3840px tall with no scrolling. When the sum of the section
heights exceeds the content box, QML does not clip or shrink -- it lets adjacent
cards overlap, and the content of one card renders on top of the next. That is
invisible in the source and only shows up as a visual glitch (a sparkline sliding
out from under the card below it).

This script does two things:

  1. Parses Ui.qml and main.qml and asserts that every section height in main.qml
     references the matching constant in Ui.qml. Hand-editing one without the
     other is how the budget silently drifts.
  2. Computes the budget at the configured scale for a range of disk counts and
     fails if any of them overflows.

Run standalone (`python3 tests/test_layout_budget.py`) or under pytest. No
third-party dependencies.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

QML_DIR = Path(__file__).resolve().parent.parent / "renderer" / "qml"
UI_QML = QML_DIR / "Ui.qml"
MAIN_QML = QML_DIR / "main.qml"

# The panel's fixed geometry, mirrored from main.qml's Window.
PANEL_H = 3840


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def parse_ui_constants(src: str) -> dict:
    """Pull numeric constants out of Ui.qml.

    Handles both plain literals (`readonly property int hUps: 105`) and the
    rounded expressions used for scaled geometry
    (`readonly property real margin: Math.round(30 * scale)`), which reduce to a
    constant multiplier of `scale`.
    """
    out = {}
    # Plain literals, allowing a trailing // comment.
    for m in re.finditer(
        r"readonly\s+property\s+(?:int|real)\s+(\w+)\s*:\s*([0-9.]+)\s*(?://.*)?$",
        src, re.M,
    ):
        out[m.group(1)] = float(m.group(2))
    # Math.round(<n> * scale) and bare <n> * scale forms.
    for m in re.finditer(
        r"readonly\s+property\s+(?:int|real)\s+(\w+)\s*:\s*"
        r"(?:Math\.round\(\s*)?([0-9.]+)\s*\*\s*scale",
        src,
    ):
        out.setdefault(m.group(1), float(m.group(2)))
    return out


def parse_scale(src: str) -> float:
    m = re.search(r"readonly\s+property\s+real\s+scale\s*:\s*([0-9.]+)", src)
    if not m:
        raise AssertionError("could not find `scale` in Ui.qml")
    return float(m.group(1))


def s(v: float, scale: float) -> int:
    """Mirror Ui.qml's s() helper."""
    return round(v * scale)


class Budget:
    """The layout arithmetic, reimplemented from Ui.qml's constants."""

    def __init__(self, ui: dict, scale: float):
        self.c = ui
        self.scale = scale

    def compute(self, disk_count: int) -> dict:
        c, sc = self.c, self.scale
        disks = max(1, disk_count)
        fixed = (
            s(c["hHeaderMeasured"], sc)
            + s(c["hGaugeRow"], sc)
            + s(c["hUps"], sc)
            + s(c["hStorageBase"], sc)
            + s(c["hStoragePerDisk"], sc) * disks
            + s(c["hSystem"], sc)
            + s(c["hSpacer"], sc)
        )
        hints = s(c["hCpuCard"], sc) + s(c["hGpuCard"], sc) + s(c["hNetCard"], sc)
        gaps = s(c["colSpacing"], sc) * (int(c["sectionCount"]) - 1)
        content = PANEL_H - 2 * s(c["margin"], sc)
        needed = fixed + hints + gaps
        leftover = content - fixed - gaps
        return {
            "fixed": fixed,
            "hints": hints,
            "leftover": leftover,
            "gaps": gaps,
            "content": content,
            "needed": needed,
            "slack": content - needed,
            "fits": needed <= content and leftover > 0,
            "disks": disks,
        }


class TestLayoutBudget(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ui_src = _read(UI_QML)
        cls.main_src = _read(MAIN_QML)
        cls.ui = parse_ui_constants(cls.ui_src)
        cls.scale = parse_scale(cls.ui_src)
        cls.budget = Budget(cls.ui, cls.scale)

    # ------------------------------------------------------------- parsing
    def test_constants_present(self):
        for name in [
            "hHeaderMeasured", "hGaugeRow", "hUps", "hSystem",
            "hStorageBase", "hStoragePerDisk", "hSpacer",
            "hUpsRows", "barH",
            "hCpuCard", "hGpuCard", "hNetCard",
            "panelHeight", "sectionCount",
        ]:
            with self.subTest(name=name):
                self.assertIn(name, self.ui, f"{name} missing from Ui.qml")

    def test_panel_height_matches_main_qml(self):
        # Ui.panelHeight and main.qml's Window.height must not drift apart, or
        # the budget check validates a panel that is not the one being drawn.
        m = re.search(r"^\s*height:\s*(\d+)", self.main_src, re.M)
        self.assertIsNotNone(m, "could not find Window height in main.qml")
        self.assertEqual(int(m.group(1)), int(self.ui["panelHeight"]),
                         "Ui.panelHeight and main.qml Window.height disagree")
        self.assertEqual(int(self.ui["panelHeight"]), PANEL_H)

    # ------------------------------------------------- main.qml uses Ui values
    def test_every_section_height_references_a_ui_constant(self):
        """No section may hardcode its height -- that is how drift starts."""
        # Every Layout.preferredHeight in the section ColumnLayout must be
        # expressed via Ui.* (or a content-derived implicitHeight), never a bare
        # number. A hardcoded literal is how the heights desynced from `scale`.
        heights = re.findall(r"Layout\.preferredHeight:\s*(.+)", self.main_src)
        self.assertGreaterEqual(len(heights), 9, "expected at least 9 sections")
        for h in heights:
            with self.subTest(height=h.strip()):
                self.assertTrue(
                    "Ui." in h or "implicitHeight" in h,
                    f"hardcoded section height: {h.strip()!r}",
                )

    def test_expected_constants_are_actually_used(self):
        # These are consumed by main.qml's Layout.preferredHeight bindings.
        for name in ["hGaugeRow", "hCpuCard", "hGpuCard", "hNetCard", "hUps",
                     "hStorageBase", "hStoragePerDisk", "hSpacer",
            "hUpsRows", "barH",
                     "hSystemRows", "headerWxGap"]:
            with self.subTest(name=name):
                self.assertIn(f"Ui.{name}", self.main_src,
                              f"Ui.{name} is defined but never used in main.qml")
        # hSystem and hHeaderMeasured feed the budget arithmetic in Ui.qml
        # itself rather than a main.qml binding, so check them against Ui.qml.
        for name in ["hSystem", "hHeaderMeasured"]:
            with self.subTest(name=name):
                self.assertIn(name, self.ui_src,
                              f"{name} is missing from Ui.qml")

    def test_fillheight_card_count_matches_budget(self):
        # The budget assumes exactly three top-level Layout.fillHeight SECTIONS.
        # Count only those at the section indent level -- inner layout items
        # (e.g. the CPU card's sparkline) may also fill, and must not be counted.
        lines = self.main_src.splitlines()
        n = 0
        for i, line in enumerate(lines):
            if "Layout.fillHeight: true" not in line:
                continue
            # Section-level entries are indented 16 spaces in main.qml.
            indent = len(line) - len(line.lstrip())
            if indent <= 16:
                n += 1
        self.assertEqual(
            n, 3,
            f"budget assumes 3 top-level fillHeight sections, found {n}",
        )

    # --------------------------------------------------------- the arithmetic
    def test_fits_at_current_scale_for_typical_disk_counts(self):
        for disks in range(1, 7):
            with self.subTest(disks=disks):
                b = self.budget.compute(disks)
                self.assertTrue(
                    b["fits"],
                    f"{disks} disks overflow by {-b['slack']}px "
                    f"(needed {b['needed']}, content {b['content']})",
                )

    def test_the_original_regression_is_gone(self):
        """The bug that started this: 191px over budget at scale 1.55.

        Pin the specific numbers so a future edit that reintroduces the overflow
        fails loudly rather than being rediscovered by eye on the panel.
        """
        b = self.budget.compute(2)
        self.assertGreater(b["slack"], 0,
                           "layout no longer fits with 2 disks")
        # And confirm we are not merely scraping by -- a few px of slack would
        # break again the moment anything grows.
        self.assertGreaterEqual(
            b["slack"], 100,
            f"only {b['slack']}px of slack; too tight to survive a small change",
        )

    def test_headroom_survives_a_scale_bump(self):
        """The reclaimed space should buy room for a larger scale.

        Not a requirement of the current design, but if the slack is real it
        should show up here -- and if a future edit spends it all, this tells us.
        """
        for bump in (1.60, 1.65):
            with self.subTest(scale=bump):
                b = Budget(self.ui, bump).compute(2)
                self.assertTrue(
                    b["fits"],
                    f"scale {bump} overflows by {-b['slack']}px; "
                    f"the reclaimed headroom was spent elsewhere",
                )

    def test_no_section_is_absurdly_small(self):
        # A budget that "fits" by starving a section is not a fix. Guard the
        # floors so a future edit cannot buy slack by collapsing a card.
        for name, floor in [("hCpuCard", 150), ("hGpuCard", 150),
                            ("hNetCard", 200), ("hSystem", 150), ("hUps", 80)]:
            with self.subTest(name=name):
                self.assertGreaterEqual(
                    self.ui[name], floor,
                    f"{name}={self.ui[name]} is below the usable floor {floor}",
                )

    # ------------------------------------------------- content fits the card
    def test_system_card_is_tall_enough_for_its_rows(self):
        """The SYSTEM card must not clip its last row.

        This is the bug that produced DISPLAYS with its lower half off the card:
        the card's height was a hand-written literal (230) while the real demand
        was 8 rows * 35px + chrome = 388. A budget that fits the panel is not
        enough -- each card must also fit its own content.
        """
        chrome = self._chrome()
        row_h = self._row_h()
        rows = int(self.ui["hSystemRows"])
        gap = s(2, self.scale)
        needed = chrome + rows * row_h + (rows - 1) * gap
        have = s(self.ui["hSystem"], self.scale)
        # Ui.hSystem must be at least what rowsCardH computes, or the card is
        # declared shorter than its own contents.
        self.assertGreaterEqual(
            have, needed,
            f"SYSTEM card is {needed - have}px too short for {rows} rows "
            f"(has {have}, needs {needed}) -- the last row will be clipped",
        )

    def test_system_rows_matches_the_actual_row_count(self):
        """Ui.hSystemRows must equal the number of KeyValue rows in the card.

        Cheap to get wrong when adding or removing a line, and the symptom is a
        clipped card rather than an error.
        """
        block = self._card_block("SYSTEM")
        self.assertIsNotNone(block, "could not locate the SYSTEM card in main.qml")
        assert block is not None  # narrow for the type checker
        # Count KeyValue instances that are direct children of the card's
        # ColumnLayout: those are indented one level deeper than the layout.
        rows = len(re.findall(r"^\s+KeyValue \{", block, re.M))
        self.assertEqual(
            rows, int(self.ui["hSystemRows"]),
            f"SYSTEM card has {rows} rows but Ui.hSystemRows is "
            f"{int(self.ui['hSystemRows'])}",
        )

    def test_ups_card_is_tall_enough_for_rows_and_bar(self):
        """The UPS card must fit its rows AND its trailing progress bar.

        The charge bar hung off the bottom of the card background because the
        height was a literal (105 = 163px) that ignored both the bar's height and
        the spacing before it. 185px were needed.
        """
        chrome = self._chrome()
        row_h = self._row_h()
        rows = int(self.ui["hUpsRows"])
        bars = 1
        sp = s(4, self.scale)
        needed = chrome + rows * row_h + bars * s(self.ui["barH"], self.scale) \
                 + (rows + bars - 1) * sp
        have = s(self.ui["hUps"], self.scale)
        self.assertGreaterEqual(
            have, needed,
            f"UPS card is {needed - have}px too short for {rows} rows + "
            f"{bars} bar (has {have}, needs {needed}) -- the bar will overflow",
        )

    def test_ups_card_declares_a_bar(self):
        """Guard against the bar being dropped without updating the height.

        If the charge bar is ever removed, hUps must shrink to match -- a card
        sized for a bar it no longer has is wasted space, and this test is the
        reminder to update both.
        """
        block = self._card_block("UPS")
        self.assertIsNotNone(block, "could not locate the UPS card in main.qml")
        assert block is not None
        bars = len(re.findall(r"^\s+ProgressBar \{", block, re.M))
        self.assertEqual(
            bars, 1,
            f"UPS card has {bars} ProgressBar(s); Ui.hUps/hUpsRows are sized "
            f"for exactly 1 -- update both if this is intentional",
        )

    def _chrome(self) -> int:
        return (
            s(self.ui["cardPadTop"], self.scale)
            + s(self.ui["cardHeadH"], self.scale)
            + s(self.ui["cardHeadGap"], self.scale)
            + s(self.ui["cardPadBot"], self.scale)
        )

    def _row_h(self) -> int:
        return round(s(15, self.scale) * 1.39) + s(self.ui["kvPad"], self.scale)

    def _card_block(self, title: str) -> str | None:
        """Extract the source of the Card whose title starts with `title`.

        Matches a title that is either the bare literal (`title: "SYSTEM"`) or
        the start of an interpolated one (`title: "UPS  ·  " + ...`).
        """
        m = re.search(
            rf'title:\s*"{re.escape(title)}',
            self.main_src,
        )
        if not m:
            return None
        # Walk back to the enclosing `Card {` and forward to its matching brace.
        start = self.main_src.rfind("Card {", 0, m.start())
        if start < 0:
            return None
        depth = 0
        for i in range(start, len(self.main_src)):
            if self.main_src[i] == "{":
                depth += 1
            elif self.main_src[i] == "}":
                depth -= 1
                if depth == 0:
                    return self.main_src[start:i + 1]
        return None


if __name__ == "__main__":
    # Print the budget table for humans, then run the assertions.
    _ui = parse_ui_constants(_read(UI_QML))
    _scale = parse_scale(_read(UI_QML))
    _b = Budget(_ui, _scale)
    print(f"scale = {_scale}")
    print(f"{'disks':>6} {'fixed':>7} {'hints':>6} {'gaps':>6} "
          f"{'leftover':>9} {'perCard':>8} {'needed':>7} {'content':>8}  fits")
    for d in range(1, 7):
        r = _b.compute(d)
        print(f"{d:>6} {r['fixed']:>7} {r['hints']:>6} {r['gaps']:>6} "
              f"{r['leftover']:>9} {r['leftover'] // 3:>8} "
              f"{r['needed']:>7} {r['content']:>8}  "
              f"{'yes' if r['fits'] else 'NO -- OVERFLOW'}")
    print()
    print("fillHeight cards absorb the leftover, so 'leftover' is the space the")
    print("CPU/GPU/NET cards actually share and 'hints' is only a lower bound.")
    print()
    unittest.main(verbosity=2)
