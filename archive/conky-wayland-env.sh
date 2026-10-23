#!/bin/bash
# Resolve the real Wayland socket for the current session and exec conky with it.
#
# WHY THIS EXISTS
# The compositor socket is not guaranteed to be wayland-0. Under Plasma it is
# wayland-1 whenever anything already owned wayland-0 when the session started
# (commonly a leftover process from the previous boot). Hardcoding
# WAYLAND_DISPLAY=wayland-0 in a systemd unit therefore overrides the correct
# per-boot value, and conky fails with:
#
#   [error] display-wayland.cc:649 wl_display_connect failed: No such file or directory
#   [warn ] unable to initialize any outputs, falling back to console output
#
# which does NOT crash and does NOT set a non-zero exit status -- the unit stays
# "active (running)" while the panel renders nothing at all. Silent and maddening.
#
# This wrapper picks the socket that actually exists, so any boot works.

set -u

CONF="${1:-$HOME/.config/conky/conky.conf}"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# 1. Component socket of the *current* session, if systemd knows it.
if [ -z "${WAYLAND_DISPLAY:-}" ] && command -v systemctl >/dev/null 2>&1; then
    WAYLAND_DISPLAY="$(systemctl --user show-environment 2>/dev/null \
        | sed -n 's/^WAYLAND_DISPLAY=//p')"
fi

# 2. Validate it; if it does not point at a live socket, scan for one.
if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$RUNTIME/$WAYLAND_DISPLAY" ]; then
    for sock in "$RUNTIME"/wayland-[0-9]*; do
        [ -S "$sock" ] || continue
        # Skip *.lock sidecar files and any non-primary socket names.
        case "$(basename "$sock")" in
            wayland-[0-9]) WAYLAND_DISPLAY="$(basename "$sock")"; break ;;
        esac
    done
fi

if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$RUNTIME/$WAYLAND_DISPLAY" ]; then
    echo "conky-wayland-env: no Wayland socket in $RUNTIME" >&2
    exit 1
fi

export WAYLAND_DISPLAY
export XDG_RUNTIME_DIR="$RUNTIME"
export DISPLAY="${DISPLAY:-:0}"

# XAUTHORITY is needed by a few ${execi} helpers that still touch X11 tooling.
if [ -z "${XAUTHORITY:-}" ]; then
    for f in "$RUNTIME"/xauth_* "$RUNTIME"/.mutter-Xwaylandauth.*; do
        [ -f "$f" ] && XAUTHORITY="$f" && break
    done
fi
[ -n "${XAUTHORITY:-}" ] && export XAUTHORITY

exec /usr/bin/conky -c "$CONF" -d
