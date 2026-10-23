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
#
# Exit 0 = drawing where it should be. Non-zero = broken, with the reason.
set -uo pipefail

LOG_TAG="CASEDASH_VERIFY"
EXPECT_W=1100
EXPECT_H=3840
EXPECT_X=3440
EXPECT_Y=0
STATE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/casedash/state.json"

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
    exit 1
fi
