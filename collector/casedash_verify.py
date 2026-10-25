#!/usr/bin/env python3
"""Content-plausibility checks for casedash telemetry.

`verify.sh` proves the panel is *drawn* and that `state.json` is *fresh*. Neither
says the numbers are *right*. This module is the missing third question: a panel
can be live, correctly placed, and freshly updated while displaying the wrong
continent -- which is exactly what happened when wttr.in's IP geolocation put
this machine in Campo Salles, Argentina for an extended period while every
existing check reported healthy.

The comparison is deliberately isolated here rather than inlined in shell so it
can be unit-tested. A verification script whose own logic is unverified is just
a second thing that can silently lie to you.

Run directly to check a state file, or import `check_weather`.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# ~60km at mid-latitudes. Wide enough that wttr.in moving between nearby
# reporting stations never trips it, narrow enough that a different country
# always does. Callers can override via CASEDASH_VERIFY_WX_TOLERANCE.
DEFAULT_TOLERANCE_DEG = 0.5

# Returned as (ok, message). `ok` is None for "could not evaluate", which the
# caller should treat as a skip rather than a pass -- an unparseable config is
# not evidence that the location is correct.
OK = True
BAD = False
UNKNOWN = None


def parse_latlon(text: str) -> tuple[float, float] | None:
    """Parse "lat,lon". Returns None if it is not a usable pair.

    Tolerates surrounding whitespace. Rejects the empty string, a missing
    component, a non-numeric component, and any value outside the valid range --
    a typo like "347.46,-92.289" should be reported, not silently compared as a
    latitude that cannot exist.
    """
    if not isinstance(text, str):
        return None
    parts = text.strip().split(",")
    if len(parts) != 2:
        return None
    try:
        lat, lon = (float(p) for p in parts)
    except ValueError:
        return None
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        return None
    return lat, lon


def check_weather(
    weather: dict | None,
    expected: str,
    tolerance: float | str = DEFAULT_TOLERANCE_DEG,
) -> tuple[bool | None, str]:
    """Compare a state.json `weather` object against an expected location.

    Returns (ok, message):
      (True,  ...)  within tolerance
      (False, ...)  a definite mismatch -- a different place
      (None,  ...)  could not evaluate (missing fields, bad config)

    Only a definite mismatch should fail a verification run. Missing data is a
    skip, because a probe that has not populated yet is not the same failure as
    a probe reporting the wrong continent, and conflating them trains people to
    ignore the check.
    """
    expected_pair = parse_latlon(expected)
    if expected_pair is None:
        return UNKNOWN, f"bad expected location {expected!r} (want 'lat,lon')"
    wlat_want, wlon_want = expected_pair

    try:
        tolerance = float(tolerance)
    except (TypeError, ValueError):
        return UNKNOWN, f"bad tolerance {tolerance!r}"
    if tolerance < 0:
        return UNKNOWN, f"bad tolerance {tolerance!r}"

    if not isinstance(weather, dict) or not weather:
        return UNKNOWN, "no weather in state.json (collector still starting?)"

    area = weather.get("area") or "?"
    lat, lon = weather.get("lat"), weather.get("lon")
    if lat is None or lon is None:
        # An older collector, or a probe that has not resolved yet. Reported
        # rather than passed, so the gap is visible.
        return UNKNOWN, f"no coordinates in state.json (area={area!r})"

    try:
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return UNKNOWN, f"non-numeric coordinates in state.json (area={area!r})"

    dlat, dlon = abs(lat - wlat_want), abs(lon - wlon_want)
    worst = max(dlat, dlon)
    if dlat <= tolerance and dlon <= tolerance:
        return OK, f"ok ({area} {lat},{lon}, {worst:.2f}deg from expected)"
    return BAD, (
        f"WRONG PLACE: {area} {lat},{lon} is {worst:.2f}deg from expected "
        f"{wlat_want},{wlon_want} (tolerance {tolerance}deg)"
    )


def check_state_file(
    path: str | Path,
    expected: str,
    tolerance: float | str = DEFAULT_TOLERANCE_DEG,
) -> tuple[bool | None, str]:
    """Load a state.json and check its weather block."""
    try:
        state = json.loads(Path(path).read_text())
    except FileNotFoundError:
        return UNKNOWN, f"state file not found: {path}"
    except (OSError, json.JSONDecodeError) as e:
        return UNKNOWN, f"unreadable state file: {e}"
    if not isinstance(state, dict):
        return UNKNOWN, "state file is not a JSON object"
    return check_weather(state.get("weather"), expected, tolerance)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            f"usage: {argv[0]} STATE.json EXPECTED_LATLON [TOLERANCE_DEG]",
            file=sys.stderr,
        )
        return 2
    tolerance = argv[3] if len(argv) > 3 else DEFAULT_TOLERANCE_DEG
    ok, message = check_state_file(argv[1], argv[2], tolerance)
    print(message)
    # Exit 1 only on a definite mismatch. UNKNOWN exits 0 so a caller with
    # `set -e` does not treat "not enough data" as a hard failure.
    return 1 if ok is BAD else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
