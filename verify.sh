#!/usr/bin/env bash
# Verify the dashboard is ACTUALLY drawing on the case screen.
#
# This exists because Conky burned us: a unit can be `active (running)` with a
# fully populated journal while the panel shows nothing but black. Service
# status is not evidence. Pixels are evidence.
#
# Strategy (no portal/screenshot protocol needed):
#   1. Ask KWin where the `casedash` window is and what layer it is on.
#   2. Confirm it is on DP-1's geometry (3440,0 1100x3840) at layer 0.
#   3. Confirm the process is alive and the collector's state.json is fresh.
#   4. Confirm the telemetry CONTENT is plausible -- not just present.
#
# Exit 0 = drawing where it should be. Non-zero = broken, with the reason.
set -uo pipefail

LOG_TAG="CASEDASH_VERIFY"
EXPECT_W=1100
EXPECT_H=3840
EXPECT_X=3440
EXPECT_Y=0
STATE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/casedash/state.json"

# Expected weather coordinates, "lat,lon". Freshness alone cannot catch a
# weather reading that is live but WRONG -- wttr.in's IP geolocation once put
# this panel in Argentina while state.json was perfectly fresh. Set this in the
# timer/service environment. Unset (or "auto") = skip the check, so a stranger's
# clone does not fail verification for living somewhere else.
EXPECT_WX_LATLON="${CASEDASH_VERIFY_WX_LATLON:-}"
# How far off is still "the same place". ~60km at mid-latitudes; generous enough
# that wttr.in switching between nearby stations never trips it.
WX_TOLERANCE_DEG="${CASEDASH_VERIFY_WX_TOLERANCE:-0.5}"

fail=0
note() { printf '  %-14s %s\n' "$1" "$2"; }

echo "casedash verification $(date '+%Y-%m-%d %H:%M:%S')"
echo

# ---------------------------------------------------------------- 1. process
if pgrep -u "$(id -u)" -x casedash >/dev/null 2>&1; then
    note "process" "ok (pid $(pgrep -u "$(id -u)" -x casedash | tr '\n' ' '))"
else
    note "process" "NOT RUNNING"
    fail=1
fi

# ------------------------------------------------------------- 2. state file
if [ -f "$STATE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$STATE") ))
    # The collector publishes every 3s, so anything under ~10s is healthy; a
    # shorter window would flag the normal gap between publishes as a failure.
    if [ "$age" -le 10 ]; then
        note "state.json" "fresh (${age}s old)"
    else
        note "state.json" "STALE (${age}s old) -- collector wedged?"
        fail=1
    fi
else
    note "state.json" "MISSING -- collector not writing"
    fail=1
fi

# ------------------------------------------------------- 3. KWin geometry
# Load a probe script into KWin and read the result back from the journal.
PROBE=/tmp/casedash_verify_probe.js
BEFORE=$(journalctl --user -t kwin_wayland --since "-2s" --no-pager 2>/dev/null | wc -l)
cat > "$PROBE" <<'EOF'
var ws = workspace.windowList();
for (var i = 0; i < ws.length; i++) {
    var w = ws[i];
    var n = "";
    try { n = w.resourceClass || w.caption || ""; } catch (e) {}
    if (String(n).toLowerCase().indexOf("casedash") >= 0) {
        var g = w.frameGeometry;
        console.info("CASEDASH_VERIFY",
            "geom=" + g.x + "," + g.y + " " + g.width + "x" + g.height,
            "layer=" + w.layer);
    }
}
EOF
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript casedashverify >/dev/null 2>&1
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$PROBE" casedashverify >/dev/null 2>&1
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1
sleep 1

LINE=$(journalctl --user -t kwin_wayland --since "-6s" --no-pager 2>/dev/null \
       | grep "CASEDASH_VERIFY" | tail -1)

if [ -z "$LINE" ]; then
    note "kwin window" "not found -- surface never mapped"
    fail=1
else
    GEOM=$(printf '%s' "$LINE" | sed -n 's/.*geom=\([0-9-]*,[0-9-]* [0-9]*x[0-9]*\).*/\1/p')
    LAYER=$(printf '%s' "$LINE" | sed -n 's/.*layer=\([0-9]*\).*/\1/p')
    want="$EXPECT_X,$EXPECT_Y ${EXPECT_W}x${EXPECT_H}"
    if [ "$GEOM" = "$want" ]; then
        note "geometry" "ok ($GEOM)"
    else
        note "geometry" "WRONG: got '$GEOM', want '$want'"
        fail=1
    fi
    if [ "$LAYER" = "0" ]; then
        note "layer" "ok (background, 0)"
    else
        note "layer" "unexpected: $LAYER (want 0 = background)"
        fail=1
    fi
fi

# ------------------------------------------------------- 4. weather content
# The panel can be live, fresh, correctly placed, and still be lying. This is
# the check that would have caught "Campo Salles, Argentina" in 15 minutes
# instead of a human noticing it days later.
if [ -z "$EXPECT_WX_LATLON" ] || [ "$EXPECT_WX_LATLON" = "auto" ]; then
    note "weather" "skipped (CASEDASH_VERIFY_WX_LATLON unset)"
elif [ -f "$STATE" ]; then
    WX=$(python3 - "$STATE" "$EXPECT_WX_LATLON" "$WX_TOLERANCE_DEG" <<'PY'
import json, sys
state, want, tol = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    wx = json.load(open(state)).get("weather") or {}
except Exception as e:
    print(f"unreadable: {e}")
    raise SystemExit(0)

area = wx.get("area") or "?"
lat, lon = wx.get("lat"), wx.get("lon")
if lat is None or lon is None:
    print(f"no coordinates in state.json (area={area!r})")
    raise SystemExit(0)

try:
    wlat, wlon = (float(x) for x in want.split(","))
except ValueError:
    print(f"bad CASEDASH_VERIFY_WX_LATLON={want!r}, want 'lat,lon'")
    raise SystemExit(0)

dlat, dlon = abs(lat - wlat), abs(lon - wlon)
if dlat <= tol and dlon <= tol:
    print(f"ok ({area} {lat},{lon}, {max(dlat, dlon):.2f}deg from expected)")
else:
    print(f"WRONG PLACE: {area} {lat},{lon} is {max(dlat, dlon):.2f}deg "
          f"from expected {wlat},{wlon} (tolerance {tol}deg)")
PY
)
    case "$WX" in
        ok\ *)   note "weather" "$WX" ;;
        skipped*) note "weather" "$WX" ;;
        *)       note "weather" "$WX"; fail=1 ;;
    esac
fi

# ------------------------------------------------------------------ verdict
echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT: OK -- dashboard is live on the case screen."
    exit 0
else
    echo "RESULT: FAILED -- see above. Common causes:"
    echo "  * QT_WAYLAND_SHELL_INTEGRATION=layer-shell unset  -> lands on primary"
    echo "  * WAYLAND_DISPLAY hardcoded to a dead socket      -> silent fallback"
    echo "  * collector not running                           -> state.json stale"
    echo "  * CASEDASH_WX_LOCATION=auto mis-geolocated        -> weather shows"
    echo "    another continent; pin a place name or 'lat,lon'"
    exit 1
fi
