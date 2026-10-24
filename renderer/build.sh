#!/usr/bin/env bash
# Build the casedash renderer.
#
# Deliberately no cmake: it was removed from this box by an update, and the
# whole build is one translation unit. Plain g++ + pkg-config is fewer moving
# parts and one less thing an update can break.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
mkdir -p "$BUILD"

QT_INC=$(pkg-config --cflags Qt6Core Qt6Gui Qt6Qml Qt6Quick 2>/dev/null || true)
QT_LIB=$(pkg-config --libs Qt6Core Qt6Gui Qt6Qml Qt6Quick 2>/dev/null || true)

if [ -z "$QT_LIB" ]; then
    echo "!! Qt6 dev packages not found via pkg-config" >&2
    exit 1
fi

# layer-shell-qt does not always ship a .pc file; probe the usual names.
LS_CFLAGS=""
LS_LIBS=""
for pc in LayerShellQtInterface layer-shell-qt; do
    if pkg-config --exists "$pc" 2>/dev/null; then
        LS_CFLAGS+=" $(pkg-config --cflags "$pc")"
        LS_LIBS+=" $(pkg-config --libs "$pc")"
    fi
done
if [ -z "$LS_LIBS" ]; then
    if [ -f /usr/include/LayerShellQt/Window ]; then
        LS_CFLAGS="-I/usr/include/LayerShellQt"
        LS_LIBS="-lLayerShellQtInterface"
    else
        echo "!! layer-shell-qt headers/libs not found" >&2
        exit 1
    fi
fi

# Qt6 moc is needed for the Q_OBJECT in host.cpp.
#
# Getting the RIGHT moc matters more than it looks. A Qt5 moc generating the .moc
# for Qt6 headers fails with a wall of misleading errors ("#error This file was
# generated using the moc from 5.15.13", then spurious "class has no member named
# setScreen" further down) -- the real problem is invisible behind them. On Arch,
# /usr/bin/moc is Qt6; on Debian/Ubuntu, /usr/bin/moc is Qt5's and wins a naive
# `command -v` race. So: probe candidates and VERIFY each one's version rather
# than trusting PATH order.
moc_is_qt6() {
    [ -x "$1" ] || return 1
    "$1" --version 2>/dev/null | grep -q '^moc 6\.'
}

MOC=""
for cand in \
    "$(command -v moc6 2>/dev/null || true)" \
    "$(command -v moc-qt6 2>/dev/null || true)" \
    /usr/lib/qt6/moc /usr/lib64/qt6/moc \
    /usr/lib/qt6/libexec/moc /usr/lib/x86_64-linux-gnu/qt6/libexec/moc \
    "$(command -v moc 2>/dev/null || true)"
do
    [ -n "$cand" ] || continue
    if moc_is_qt6 "$cand"; then MOC="$cand"; break; fi
done

# Last resort: any moc on the system that reports itself as Qt6.
if [ -z "$MOC" ]; then
    for cand in $(find /usr -name 'moc*' -type f 2>/dev/null | head -40); do
        if moc_is_qt6 "$cand"; then MOC="$cand"; break; fi
    done
fi

if [ -z "$MOC" ]; then
    echo "!! Qt6 moc not found (a Qt5 moc will NOT work -- it fails with" >&2
    echo "   misleading errors deep in the generated file)." >&2
    echo "   Debian/Ubuntu: apt install qt6-base-dev-tools" >&2
    echo "   Arch:          pacman -S qt6-base" >&2
    exit 1
fi

echo ":: moc   $MOC ($("$MOC" --version 2>/dev/null | head -1))"
"$MOC" "$HERE/src/host.cpp" -o "$BUILD/host.moc"

echo ":: g++   compiling"
g++ -std=c++17 -O2 -fPIC \
    -I"$BUILD" -I"$HERE/src" \
    $QT_INC $LS_CFLAGS \
    -o "$BUILD/casedash" "$HERE/src/host.cpp" \
    $QT_LIB $LS_LIBS

echo ":: built $BUILD/casedash"
ls -la "$BUILD/casedash"
