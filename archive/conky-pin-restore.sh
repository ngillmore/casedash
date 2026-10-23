#!/bin/bash
# Restore the known-good conky on a box that system updates keep breaking.
#
# Idempotent: safe to run any time, does nothing if already correct.
# Requires root (edits /etc/pacman.conf and installs a package).
#
# ROBUSTNESS NOTES (learned the hard way, 2026-10-22):
#   1. Do NOT use `set -e` here. A verification grep that finds nothing returns
#      exit 1, which aborts the script *silently* mid-run -- the user sees
#      step 2 start and then nothing, with the pin unwritten and the package
#      not installed. Verify-and-report instead of verify-and-die.
#   2. The IgnorePkg *option line* may be missing ENTIRELY -- not merely
#      commented out. Accepting a .pacnew can drop it, leaving only the prose
#      comment "# Pacman won't upgrade packages listed in IgnorePkg...". A
#      script that greps for "^#IgnorePkg" finds nothing and does nothing, so
#      the pin never gets written. Handle all three states: present,
#      commented, absent (insert it).

set -uo pipefail   # deliberately NOT -e (see note 1)

CONF="/etc/pacman.conf"
GOOD_PKG="/var/cache/pacman/pkg/conky-1.24.2-1.1-x86_64_v4.pkg.tar.zst"
GOOD_VER="1.24.2"
PIN_VAL="conky"
rc=0

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0" >&2
    exit 1
fi

if [ ! -f "$GOOD_PKG" ]; then
    echo "known-good package missing: $GOOD_PKG" >&2
    echo "check: ls /var/cache/pacman/pkg/ | grep conky" >&2
    exit 1
fi

echo "[1/4] backing up $CONF"
cp -n "$CONF" "${CONF}.bak-$(date +%F-%H%M%S)" || true

echo "[2/4] applying IgnorePkg pin"
if grep -qE "^[[:space:]]*IgnorePkg[[:space:]]*=" "$CONF"; then
    sed -i "s|^[[:space:]]*IgnorePkg[[:space:]]*=.*|IgnorePkg = ${PIN_VAL}|" "$CONF"
    echo "      updated existing IgnorePkg line"
elif grep -qE "^#IgnorePkg" "$CONF"; then
    sed -i "s|^#IgnorePkg.*|IgnorePkg = ${PIN_VAL}|" "$CONF"
    echo "      uncommented #IgnorePkg"
elif grep -qE "^# Pacman won't upgrade packages listed in IgnorePkg" "$CONF"; then
    # Option line absent entirely -- insert it after the explanatory comment.
    sed -i "/^# Pacman won't upgrade packages listed in IgnorePkg/a IgnorePkg = ${PIN_VAL}" "$CONF"
    echo "      inserted IgnorePkg after the explanatory comment"
else
    sed -i "/^\[options\]/a IgnorePkg = ${PIN_VAL}" "$CONF"
    echo "      appended IgnorePkg to the [options] section"
fi

# Verify -- REPORT, do not die.
if grep -qE "^[[:space:]]*IgnorePkg[[:space:]]*=[[:space:]]*${PIN_VAL}" "$CONF"; then
    grep -nE "^[[:space:]]*IgnorePkg" "$CONF" | sed 's/^/      /'
else
    echo "      ERROR: pin still not present after edit" >&2
    rc=1
fi

echo "[3/4] installing conky $GOOD_VER from cache"
if pacman -Q conky 2>/dev/null | grep -q "$GOOD_VER"; then
    echo "      already on $GOOD_VER, skipping"
else
    if pacman -U --noconfirm "$GOOD_PKG"; then
        echo "      installed"
    else
        echo "      ERROR: package install failed" >&2
        rc=1
    fi
fi

echo "[4/4] restarting the panel (as user yak)"
sudo -u yak env XDG_RUNTIME_DIR=/run/user/1000 \
    systemctl --user restart conky.service || echo "      (restart reported an error)"
sleep 3
echo -n "      unit state: "
sudo -u yak env XDG_RUNTIME_DIR=/run/user/1000 \
    systemctl --user is-active conky.service || true

echo
if [ "$rc" -eq 0 ]; then
    echo "Done. NOW VERIFY THE PIXELS -- an active unit does NOT mean a lit screen:"
else
    echo "Finished WITH ERRORS (rc=$rc) -- read the messages above."
fi
cat <<'EOF'
  ~/.local/bin/conky-pin-audit.sh
  # or capture the panel directly:
  DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 \
    XAUTHORITY=$(ls /run/user/1000/xauth_* | head -1) \
    spectacle -b -n -f -o /tmp/full.png
  # then confirm the case-screen region (x=3440..4540) is not pure black
EOF

exit $rc
