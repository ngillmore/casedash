#!/usr/bin/env python3
"""matugen post-hook: keep the case screen and the RGB in sync with the theme.

Wired into ~/.config/matugen/config.toml as the post_hook for the KDE template,
so every `theme apply` / `theme random` / `theme wallpaper` recolours the case
panel and re-tunes the Lian Li RGB in the same step.

Writes the resolved palette to the runtime dir (so the renderer can read a
machine-readable copy) and hands off to the casedash theme bridge.

Deliberately never exits non-zero: a theming side-effect must not be able to
break `theme apply`. Failures are logged and swallowed.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
BRIDGE = HOME / "projects/casedash/theme/casedash-theme.py"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "casedash"
SCHEME = HOME / ".local/share/color-schemes/MatugenDynamic.colors"


def log(msg: str) -> None:
    print(f"casedash-theme-hook: {msg}", file=sys.stderr)


def palette_from_scheme() -> dict:
    """Pull the M3 roles we care about out of the generated KDE scheme."""
    if not SCHEME.exists():
        return {}
    sections: dict[str, dict[str, str]] = {}
    cur = ""
    for line in SCHEME.read_text().splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1]
            sections[cur] = {}
        elif "=" in line and cur:
            k, _, v = line.partition("=")
            sections[cur][k.strip()] = v.strip()

    def get(sec: str, key: str) -> str:
        v = sections.get(sec, {}).get(key, "")
        return v if re.fullmatch(r"#[0-9a-fA-F]{6}", v) else ""

    return {
        "primary": get("Colors:Selection", "BackgroundNormal"),
        "onPrimary": get("Colors:Selection", "ForegroundNormal"),
        "surface": get("Colors:View", "BackgroundNormal"),
        "surfaceContainer": get("Colors:Window", "BackgroundNormal"),
        "surfaceContainerHigh": get("Colors:Button", "BackgroundNormal"),
        "onSurface": get("Colors:View", "ForegroundNormal"),
        "onSurfaceVariant": get("Colors:Window", "ForegroundInactive"),
        "outline": get("Colors:Window", "DecorationFocus"),
        "error": get("Colors:Window", "ForegroundNegative"),
        "success": get("Colors:Window", "ForegroundPositive"),
    }


def main() -> int:
    if not BRIDGE.exists():
        log(f"bridge not found at {BRIDGE}; skipping")
        return 0

    # 1. Publish a machine-readable palette next to the collector's state.
    try:
        pal = palette_from_scheme()
        if pal.get("primary"):
            RUNTIME.mkdir(parents=True, exist_ok=True)
            tmp = RUNTIME / "theme.json.tmp"
            tmp.write_text(json.dumps(pal, indent=2))
            tmp.replace(RUNTIME / "theme.json")
            log(f"published palette (accent {pal['primary']})")
    except Exception as e:
        log(f"palette publish failed: {e}")

    # 2. Regenerate Theme.qml + push the accent to the RGB + nudge the renderer.
    try:
        r = subprocess.run(
            [sys.executable, str(BRIDGE), "sync", "--no-reload"],
            capture_output=True, text=True, timeout=30,
        )
        for line in (r.stdout or "").splitlines():
            log(line)
        if r.returncode != 0:
            log(f"bridge exited {r.returncode}: {(r.stderr or '').strip()}")
    except Exception as e:
        log(f"bridge failed: {e}")

    # 3. The renderer watches Theme.qml, so it picks up colours live. Restart it
    #    only if it is not running (a restart would be visible as a flash).
    try:
        p = subprocess.run(["systemctl", "--user", "is-active", "casedash.service"],
                           capture_output=True, text=True)
        if p.stdout.strip() != "active":
            subprocess.run(["systemctl", "--user", "start", "casedash.service"],
                           capture_output=True)
            log("renderer was not running; started it")
    except Exception:
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
