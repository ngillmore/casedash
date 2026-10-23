#!/bin/bash
# conky-pin-audit — verify the conky version pin survived system updates.
#
# WHY THIS EXISTS
# Conky 1.25.2 aborts on startup under Wayland with:
#   display-wayland.cc:1032: set_font(): Assertion `f < pango_fonts.size()' failed
# so this box must stay on 1.24.2 (last known-good). The pin lives in
# /etc/pacman.conf as `IgnorePkg = conky`.
#
# That pin silently vanishes whenever an update drops /etc/pacman.conf.pacnew
# (pacman never merges it, and any tool that accepts the .pacnew wholesale
# restores the default commented `#IgnorePkg   =`). The result is the exact
# symptom this script exists to catch: conky "runs" (unit active), the case
# screen is pure black, and nothing logs an error the user would notice.
#
# Run by conky-pin-audit.timer daily, and callable ad hoc.

set -u

PIN_KEY="IgnorePkg"
PIN_VAL="conky"
CONF="/etc/pacman.conf"

problems=()
exit_code=0

# 1. Is the installed version the known-good one?
installed="$(pacman -Q conky 2>/dev/null | awk '{print $2}')"
if [ -n "$installed" ]; then
    case "$installed" in
        1.24.2*) ;;
        *)
            problems+=("conky is $installed, expected 1.24.2.x (1.25.2 aborts under Wayland)")
            exit_code=1
            ;;
    esac
else
    problems+=("conky is not installed at all")
    exit_code=1
fi

# 2. Is the pin actually present and active?
if grep -qE "^[[:space:]]*${PIN_KEY}[[:space:]]*=[[:space:]]*.*\b${PIN_VAL}\b" "$CONF" 2>/dev/null; then
    :
else
    problems+=("${PIN_KEY} = ${PIN_VAL} is MISSING from $CONF (an update likely dropped a .pacnew)")
    exit_code=1
fi

# 3. Is there an unmerged .pacnew that would drop the pin again?
if [ -f "${CONF}.pacnew" ]; then
    problems+=("${CONF}.pacnew exists and is unmerged — merging it will erase the pin again")
    exit_code=1
fi

# 4. Is the panel actually rendering? (unit active is NOT proof — see header)
if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl --user is-active --quiet conky.service; then
        problems+=("conky.service is not active")
        exit_code=1
    fi
fi

if [ "${#problems[@]}" -eq 0 ]; then
    echo "conky-pin-audit: OK (conky $installed, pin present, no .pacnew)"
    exit 0
fi

echo "conky-pin-audit: PROBLEMS FOUND"
for p in "${problems[@]}"; do
    echo "  - $p"
done
echo
echo "Fix (preferred -- handles all cases, including a MISSING option line):"
echo "  sudo ~/.local/bin/conky-pin-restore.sh"
echo
echo "Manual equivalent (the IgnorePkg option line may be absent entirely, not"
echo "just commented -- check with: grep -n IgnorePkg $CONF):"
echo "  sudo cp $CONF ${CONF}.bak-\$(date +%F)"
echo "  sudo sed -i '/^# Pacman .*IgnorePkg/a ${PIN_KEY} = ${PIN_VAL}' $CONF"
echo "  sudo grep -nE '^[[:space:]]*${PIN_KEY}' $CONF   # verify it landed"
echo "  sudo pacman -U /var/cache/pacman/pkg/conky-1.24.2-1.1-x86_64_v4.pkg.tar.zst"
echo "  # if a .pacnew exists, merge it FIRST, then re-apply the pin"
echo "  systemctl --user restart conky.service"
echo
echo "Then VERIFY PIXELS (an active unit does not mean a lit screen):"
echo "  DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 \\"
echo "    XAUTHORITY=\$(ls /run/user/1000/xauth_* | head -1) \\"
echo "    spectacle -b -n -f -o /tmp/full.png"

exit $exit_code
