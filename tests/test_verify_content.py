#!/usr/bin/env python3
"""Tests for the casedash content-plausibility checks.

Runnable with or without pytest:

    python3 tests/test_verify_content.py     # standalone, exit 0/1
    pytest tests/                            # if you have pytest

No third-party dependencies on purpose -- the collector itself is stdlib-only
and the test suite should not raise the bar for contributing.

These exist because the weather check is the one piece of the project that can
catch a *live but wrong* reading, and a check nobody tests is a check that
silently stops working. Every case below is a real way the comparison could be
broken by a well-meaning edit.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "collector"))

import casedash_verify as cv  # noqa: E402

# Little Rock, Arkansas. The location this panel is actually configured for.
LR = "34.746,-92.289"
# Campo Salles, Argentina -- what wttr.in's IP geolocation returned instead.
AR = "Campo Salles"
AR_LAT, AR_LON = -33.4, -60.233


def wx(area="Little Rock", lat=34.746, lon=-92.289, **extra):
    d = {"area": area, "lat": lat, "lon": lon}
    d.update(extra)
    return d


class TestParseLatLon(unittest.TestCase):
    def test_accepts_a_normal_pair(self):
        self.assertEqual(cv.parse_latlon("34.746,-92.289"), (34.746, -92.289))

    def test_accepts_whitespace_and_integers(self):
        self.assertEqual(cv.parse_latlon("  34, -92  "), (34.0, -92.0))

    def test_accepts_the_extremes(self):
        self.assertEqual(cv.parse_latlon("90,180"), (90.0, 180.0))
        self.assertEqual(cv.parse_latlon("-90,-180"), (-90.0, -180.0))

    def test_rejects_missing_or_extra_components(self):
        for bad in ["", "34.746", "34.746,-92.289,5", "34.746;", ",", "auto"]:
            with self.subTest(bad=bad):
                self.assertIsNone(cv.parse_latlon(bad))

    def test_rejects_non_numeric(self):
        for bad in ["north,west", "34.746,abc", "auto,auto"]:
            with self.subTest(bad=bad):
                self.assertIsNone(cv.parse_latlon(bad))

    def test_rejects_out_of_range(self):
        # A transposed decimal -- 347.46 instead of 34.746 -- must be reported
        # as bad config, not compared as a latitude that cannot exist.
        for bad in ["347.46,-92.289", "34.746,-920.289", "91,0", "0,-181"]:
            with self.subTest(bad=bad):
                self.assertIsNone(cv.parse_latlon(bad))

    def test_rejects_non_string(self):
        for bad in [None, 34.746, ["34", "-92"], {"lat": 1}]:
            with self.subTest(bad=bad):
                self.assertIsNone(cv.parse_latlon(bad))


class TestCheckWeather(unittest.TestCase):
    def test_match_passes(self):
        ok, msg = cv.check_weather(wx(), LR)
        self.assertIs(ok, cv.OK)
        self.assertIn("Little Rock", msg)

    def test_the_argentina_regression(self):
        # The actual bug. Same shape of data, wrong continent. This must fail.
        ok, msg = cv.check_weather(wx(AR, AR_LAT, AR_LON), LR)
        self.assertIs(ok, cv.BAD)
        self.assertIn("WRONG PLACE", msg)
        self.assertIn(AR, msg)

    def test_nearby_station_passes(self):
        # wttr.in reporting a station a little way off is not a failure.
        ok, _ = cv.check_weather(wx("North Little Rock", 34.8, -92.2), LR)
        self.assertIs(ok, cv.OK)

    def test_boundary_is_inclusive(self):
        # Exactly at tolerance passes; a hair past it fails. Pins the comparison
        # operator so a future edit cannot quietly flip <= to <.
        ok, _ = cv.check_weather(wx(lat=34.746 + 0.5), LR)
        self.assertIs(ok, cv.OK)
        ok, _ = cv.check_weather(wx(lat=34.746 + 0.5001), LR)
        self.assertIs(ok, cv.BAD)

    def test_longitude_is_checked_too(self):
        # A lat-only comparison would pass this. It must not.
        ok, msg = cv.check_weather(wx(lat=34.746, lon=-92.289 + 10), LR)
        self.assertIs(ok, cv.BAD)
        self.assertIn("WRONG PLACE", msg)

    def test_sign_is_significant(self):
        # Northern vs southern hemisphere, eastern vs western. A naive
        # abs()-free or string comparison would let one of these through.
        for lat, lon in [(34.746, 92.289), (-34.746, -92.289), (-34.746, 92.289)]:
            with self.subTest(lat=lat, lon=lon):
                ok, _ = cv.check_weather(wx(lat=lat, lon=lon), LR)
                self.assertIs(ok, cv.BAD)

    def test_custom_tolerance_is_honoured(self):
        far = wx(AR, AR_LAT, AR_LON)
        self.assertIs(cv.check_weather(far, LR, tolerance=100.0)[0], cv.OK)
        self.assertIs(cv.check_weather(far, LR, tolerance=0.1)[0], cv.BAD)

    def test_tolerance_zero_requires_exact(self):
        self.assertIs(cv.check_weather(wx(), LR, tolerance=0)[0], cv.OK)
        self.assertIs(cv.check_weather(wx(lat=34.75), LR, tolerance=0)[0], cv.BAD)

    def test_missing_weather_is_unknown_not_a_failure(self):
        # The collector not having published yet is not the same failure as
        # reporting another continent. Conflating them trains people to ignore
        # the check, which is how the original bug survived so long.
        for empty in [None, {}, {"area": "Little Rock"}]:
            with self.subTest(empty=empty):
                ok, msg = cv.check_weather(empty, LR)
                self.assertIs(ok, cv.UNKNOWN)
                self.assertNotIn("WRONG PLACE", msg)

    def test_partial_coordinates_are_unknown(self):
        ok, _ = cv.check_weather({"area": "x", "lat": 34.746}, LR)
        self.assertIs(ok, cv.UNKNOWN)
        ok, _ = cv.check_weather({"area": "x", "lon": -92.289}, LR)
        self.assertIs(ok, cv.UNKNOWN)

    def test_bad_config_is_unknown_not_a_pass(self):
        # An unparseable expectation is not evidence the location is right.
        for bad in ["", "auto", "nonsense", "34.746", "999,999"]:
            with self.subTest(bad=bad):
                ok, msg = cv.check_weather(wx(), bad)
                self.assertIs(ok, cv.UNKNOWN)
                self.assertIn("bad expected location", msg)

    def test_bad_tolerance_is_unknown(self):
        for bad in ["wide", None, -1]:
            with self.subTest(bad=bad):
                ok, _ = cv.check_weather(wx(), LR, tolerance=bad)
                self.assertIs(ok, cv.UNKNOWN)

    def test_non_numeric_coordinates_are_unknown(self):
        ok, _ = cv.check_weather({"area": "x", "lat": "n/a", "lon": "n/a"}, LR)
        self.assertIs(ok, cv.UNKNOWN)

    def test_weather_that_is_not_a_dict_is_unknown(self):
        for bad in [[], "sunny", 42]:
            with self.subTest(bad=bad):
                ok, _ = cv.check_weather(bad, LR)
                self.assertIs(ok, cv.UNKNOWN)


class TestCheckStateFile(unittest.TestCase):
    def _write(self, payload) -> str:
        fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        fh.write(payload if isinstance(payload, str) else json.dumps(payload))
        fh.close()
        self.addCleanup(Path(fh.name).unlink, missing_ok=True)
        return fh.name

    def test_reads_a_real_state_shape(self):
        path = self._write({"ts": 1, "weather": wx()})
        ok, _ = cv.check_state_file(path, LR)
        self.assertIs(ok, cv.OK)

    def test_missing_file_is_unknown(self):
        ok, msg = cv.check_state_file("/nonexistent/state.json", LR)
        self.assertIs(ok, cv.UNKNOWN)
        self.assertIn("not found", msg)

    def test_corrupt_json_is_unknown(self):
        path = self._write("{not json")
        ok, msg = cv.check_state_file(path, LR)
        self.assertIs(ok, cv.UNKNOWN)
        self.assertIn("unreadable", msg)

    def test_state_without_weather_is_unknown(self):
        path = self._write({"ts": 1, "cpu": {}})
        ok, _ = cv.check_state_file(path, LR)
        self.assertIs(ok, cv.UNKNOWN)

    def test_non_object_state_is_unknown(self):
        path = self._write("[1, 2, 3]")
        ok, _ = cv.check_state_file(path, LR)
        self.assertIs(ok, cv.UNKNOWN)


class TestExitCodes(unittest.TestCase):
    """The CLI contract verify.sh depends on: only a mismatch is exit 1."""

    def _run(self, payload, expected=LR):
        fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        fh.write(json.dumps(payload))
        fh.close()
        self.addCleanup(Path(fh.name).unlink, missing_ok=True)
        return cv.main(["casedash_verify.py", fh.name, expected])

    def test_match_exits_zero(self):
        self.assertEqual(self._run({"weather": wx()}), 0)

    def test_mismatch_exits_one(self):
        self.assertEqual(self._run({"weather": wx(AR, AR_LAT, AR_LON)}), 1)

    def test_unknown_exits_zero(self):
        # So `set -e` callers do not die on "collector still starting".
        self.assertEqual(self._run({}), 0)

    def test_bad_usage_exits_two(self):
        self.assertEqual(cv.main(["prog"]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
