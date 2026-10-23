#!/usr/bin/env python3
"""casedash theme bridge.

Keeps the dashboard's colours in lockstep with the system Material You theme
and with the Lian Li RGB lighting, so the case screen, Plasma and the fans all
agree on one accent.

    casedash-theme.py generate        regen Theme.qml from the current scheme
    casedash-theme.py rgb             push the accent to the Lian Li controller
    casedash-theme.py sync            generate + rgb + nudge the renderer
    casedash-theme.py show            print the resolved palette

Source of truth, in order:
  1. /run/user/1000/casedash/theme.json  -- written by the matugen template hook
  2. ~/.local/share/color-schemes/MatugenDynamic.colors  -- live KDE scheme
  3. built-in fallback palette

The renderer watches renderer/qml/Theme.qml directly, so rewriting that file is
all it takes to retheme a running dashboard -- no restart.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")) / "casedash"
THEME_JSON = RUNTIME_DIR / "theme.json"
SCHEME = HOME / ".local/share/color-schemes/MatugenDynamic.colors"
OUT_QML = HOME / "projects/casedash/renderer/qml/Theme.qml"
LIANLI_CONF = HOME / ".config/lianli/config.json"
LIANLI_HINT = HOME / ".local/state/casedash/lianli-applied.json"

# Fallback: the amber the old Conky panel used, so a missing theme degrades to
# something that still looks deliberate rather than to grey.
FALLBACK = {
    "primary": "#C86414",
    "onPrimary": "#000000",
    "secondary": "#C86414",
    "tertiary": "#C86414",
    "surface": "#0a0a0a",
    "surfaceContainer": "#141414",
    "surfaceContainerHigh": "#1c1c1c",
    "onSurface": "#e8e8e8",
    "onSurfaceVariant": "#8a8a8a",
    "outline": "#333333",
    "error": "#ff6b6b",
    "success": "#7dd87d",
}

# Theme.qml property name -> (hex source key, alpha 0-255)
QML_KEYS = [
    ("primary", "primary"),
    ("onPrimary", "onPrimary"),
    ("secondary", "secondary"),
    ("accent", "primary"),
    ("accentDim", "surfaceContainerHigh"),
    ("background", "surface"),
    ("card", "surfaceContainer"),
    ("cardHigh", "surfaceContainerHigh"),
    ("foreground", "onSurface"),
    ("muted", "onSurfaceVariant"),
    ("outline", "outline"),
    ("warn", "error"),
    ("ok", "success"),
]


def say(m: str) -> None:
    print(f":: {m}")


def die(m: str, code: int = 1) -> None:
    print(f"!! {m}", file=sys.stderr)
    sys.exit(code)


# ------------------------------------------------------------------ sources
def from_theme_json() -> dict:
    try:
        d = json.loads(THEME_JSON.read_text())
        out = {}
        for k, v in d.items():
            if isinstance(v, str) and v.startswith("#"):
                out[k] = v
        return out
    except Exception:
        return {}


def from_kde_scheme() -> dict:
    """Derive a palette from the live KDE colour scheme.

    The scheme is the thing the user actually sees in Plasma, so reading it
    back means the panel matches the desktop even if the matugen hook never ran.
    """
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

    def pick(section: str, key: str) -> str | None:
        v = sections.get(section, {}).get(key, "")
        return v if re.fullmatch(r"#[0-9a-fA-F]{6}", v) else None

    out = {}
    out["primary"] = pick("Colors:Selection", "BackgroundNormal") or FALLBACK["primary"]
    out["onPrimary"] = pick("Colors:Selection", "ForegroundNormal") or FALLBACK["onPrimary"]
    out["secondary"] = pick("Colors:Window", "ForegroundActive") or out["primary"]
    out["tertiary"] = pick("Colors:Window", "ForegroundActive") or out["primary"]
    out["surface"] = pick("Colors:View", "BackgroundNormal") or FALLBACK["surface"]
    out["surfaceContainer"] = pick("Colors:Window", "BackgroundNormal") or FALLBACK["surfaceContainer"]
    out["surfaceContainerHigh"] = pick("Colors:Button", "BackgroundNormal") or FALLBACK["surfaceContainerHigh"]
    out["onSurface"] = pick("Colors:View", "ForegroundNormal") or FALLBACK["onSurface"]
    out["onSurfaceVariant"] = pick("Colors:Window", "ForegroundInactive") or FALLBACK["onSurfaceVariant"]
    # DecorationFocus reads on top of the card background, which is what we
    # want for hairlines; the button background is often too close to the card.
    out["outline"] = pick("Colors:Window", "DecorationFocus") or FALLBACK["outline"]
    out["error"] = pick("Colors:Window", "ForegroundNegative") or FALLBACK["error"]
    out["success"] = pick("Colors:Window", "ForegroundPositive") or FALLBACK["ok"]
    return out


def resolve() -> dict:
    pal = dict(FALLBACK)
    pal.update(from_kde_scheme())
    pal.update(from_theme_json())      # hook output wins if present
    return pal


# ------------------------------------------------------------------ derive
def _rgb(hexv: str) -> tuple[int, int, int]:
    h = hexv.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def _hex(r: int, g: int, b: int) -> str:
    clamp = lambda x: max(0, min(255, int(x)))
    return f"#{clamp(r):02X}{clamp(g):02X}{clamp(b):02X}"


def mix(a: str, b: str, t: float) -> str:
    """Blend two hex colours. t=0 gives a, t=1 gives b."""
    ar, ag, ab = _rgb(a)
    br, bg, bb = _rgb(b)
    return _hex(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)


def luminance(hexv: str) -> float:
    r, g, b = _rgb(hexv)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


# ------------------------------------------------------------------ outputs
def write_qml(pal: dict, path: Path = OUT_QML) -> dict:
    """Write Theme.qml. Values are additionally tuned for legibility on a
    physically small, bright vertical panel: accents get an explicit dim
    variant and graph tracks get a visible but quiet line."""
    bg = pal["surface"]
    accent = pal["primary"]

    # On a very dark background, a mid-tone accent carries better than the raw
    # Material primary, which is often tuned for contrast against white cards.
    if luminance(bg) < 0.15 and luminance(accent) < 0.45:
        accent = mix(accent, "#ffffff", 0.22)
    muted = pal["onSurfaceVariant"]
    if luminance(muted) < 0.3:
        muted = mix(muted, "#ffffff", 0.25)

    # An alpha-tinted accent for chart tracks: the accent at low opacity on the
    # card colour, pre-blended because Canvas has no reliable alpha compositing
    # in this Qt version.
    accent_soft = mix(bg, accent, 0.28)
    grid = mix(bg, pal["outline"], 0.55)

    values = {
        "primary": accent,
        "onPrimary": pal["onPrimary"],
        "secondary": pal["secondary"],
        "accent": accent,
        "accentSoft": accent_soft,
        "accentDim": mix(bg, accent, 0.55),
        "background": bg,
        "card": mix(bg, pal["surfaceContainerHigh"], 0.85),
        "cardHigh": pal["surfaceContainerHigh"],
        "foreground": pal["onSurface"],
        "muted": muted,
        "outline": grid,
        "grid": grid,
        "warn": pal["error"],
        "ok": pal["success"],
    }

    lines = [
        "// GENERATED by casedash-theme.py -- do not edit by hand.",
        "// The renderer watches this file and reloads colours live.",
        "// Deliberately NOT a QML singleton: that needs qt_add_qml_module / qmldir",
        "// machinery we are not using. main.qml instantiates it as `Theme`.",
        "import QtQuick",
        "QtObject {",
    ]
    lines += [f'    readonly property color {k}: "{v}"' for k, v in values.items()]
    lines.append("}")
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".qml.tmp")
    tmp.write_text("\n".join(lines))
    tmp.replace(path)
    return values


def write_qmldir(path: Path) -> None:
    d = path.parent / "qmldir"
    d.write_text("Theme 1.0 Theme.qml\n")


def push_rgb(accent: str, dry: bool = False) -> bool:
    """Set every Lian Li RGB zone to the accent colour.

    lianli-linux reads its config on start and on SIGHUP, so we edit the config
    and reload rather than depending on a CLI that may not exist.
    """
    if not LIANLI_CONF.exists():
        say("lianli config not found; skipping RGB")
        return False
    r, g, b = _rgb(accent)
    # lianli-linux expresses colour as HSV-ish [hue 0-360, sat 0-100, val 0-100].
    import colorsys
    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    val = [int(round(h * 360)), int(round(s * 100)), int(round(v * 100))]

    try:
        cfg = json.loads(LIANLI_CONF.read_text())
    except Exception as e:
        say(f"could not read lianli config: {e}")
        return False

    changed = 0
    for dev in cfg.get("rgb", {}).get("devices", []):
        for zone in dev.get("zones", []):
            eff = zone.get("effect")
            if not isinstance(eff, dict):
                continue
            eff["colors"] = [list(val) for _ in eff.get("colors", [[]])]
            changed += 1

    if not changed:
        say("no RGB zones found in lianli config")
        return False

    if dry:
        say(f"[dry-run] {changed} zones -> {accent} {val}")
        return True

    LIANLI_HINT.parent.mkdir(parents=True, exist_ok=True)
    LIANLI_HINT.write_text(json.dumps({"accent": accent, "hsv": val, "zones": changed}))
    tmp = LIANLI_CONF.with_suffix(".json.casedash-tmp")
    tmp.write_text(json.dumps(cfg, indent=2))
    tmp.replace(LIANLI_CONF)

    # Reload: prefer the daemon's own signal, fall back to a restart.
    ok = False
    if shutil.which("lianli-cli"):
        ok = subprocess.run(["lianli-cli", "reload"], capture_output=True).returncode == 0
    if not ok:
        for cmd in (["systemctl", "--user", "reload-or-restart", "lianli-daemon"],
                    ["systemctl", "--user", "try-reload-or-restart", "lianli-daemon"]):
            if subprocess.run(cmd, capture_output=True).returncode == 0:
                ok = True
                break
    if not ok:
        say("could not reload the lianli daemon -- RGB config written but not applied")
        return False
    say(f"RGB set to {accent} across {changed} zones")
    return True


def nudge_renderer() -> None:
    """Theme.qml is watched by the renderer, so a rewrite is usually enough.
    Restart the unit as a belt-and-braces fallback if it is running."""
    p = subprocess.run(["systemctl", "--user", "is-active", "casedash.service"],
                       capture_output=True, text=True)
    if p.stdout.strip() == "active":
        subprocess.run(["systemctl", "--user", "restart", "casedash.service"],
                       capture_output=True)
        say("casedash.service restarted with the new palette")


# ------------------------------------------------------------------ commands
def cmd_generate(args) -> None:
    pal = resolve()
    vals = write_qml(pal)
    write_qmldir(OUT_QML)
    say(f"wrote {OUT_QML}")
    for k, v in vals.items():
        print(f"   {k:<12} {v}")


def cmd_show(_args) -> None:
    pal = resolve()
    src = "theme.json" if from_theme_json() else ("kde scheme" if from_kde_scheme() else "fallback")
    say(f"source: {src}")
    for k in sorted(pal):
        print(f"   {k:<20} {pal[k]}")


def cmd_rgb(args) -> None:
    push_rgb(resolve()["primary"], dry=args.dry_run)


def cmd_sync(args) -> None:
    pal = resolve()
    write_qml(pal)
    write_qmldir(OUT_QML)
    say(f"palette written ({pal['primary']})")
    push_rgb(pal["primary"], dry=args.dry_run)
    if not args.no_reload:
        nudge_renderer()


def main() -> None:
    ap = argparse.ArgumentParser(prog="casedash-theme", description="case screen theming bridge")
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("generate", help="regenerate Theme.qml only")
    p.set_defaults(func=cmd_generate)

    p = sub.add_parser("rgb", help="push the accent to the Lian Li RGB controller")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_rgb)

    p = sub.add_parser("sync", help="palette + RGB + reload the renderer")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-reload", action="store_true")
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("show", help="print the resolved palette")
    p.set_defaults(func=cmd_show)

    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return
    args.func(args)


if __name__ == "__main__":
    main()
