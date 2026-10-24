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

# layer-shell-qt has shipped THREE different ways to pin a surface to an output,
# and the headers expose no version macro (and often no .pc file) to tell them
# apart. Guessing from a version number is not viable: Ubuntu 24.04's
# liblayershellqtinterface-dev is 5.27.11 -- a Plasma 5 build whose API differs
# from every Plasma 6 release.
#
#   setScreen(QScreen*)                          >= 6.7   (current)
#   setScreenConfiguration(ScreenFromQWindow)      6.0-6.6 (deprecated shim)
#   setDesiredOutput(QScreen*)                     5.x      (Plasma 5)
#
# So: compile a probe for each, in newest-first order, and define whichever
# applies. Doing this wrong is expensive to diagnose -- the failure is a bare
# "'Window' has no member named 'setScreen'", which reads like a typo rather than
# a version gap, and sends you hunting for an API bug that isn't there.
LS_DEFS=""
probe_ls() {   # $1 = macro name, $2 = C++ body
    if printf '#include <LayerShellQt/Window>\nint main(){ auto *w = (LayerShellQt::Window*)nullptr; %s }\n' "$2" \
       | g++ -std=c++17 -fsyntax-only -x c++ - $LS_CFLAGS \
             $(pkg-config --cflags Qt6Gui 2>/dev/null) - 2>/dev/null
    then
        LS_DEFS="-D$1=1"
        return 0
    fi
    return 1
}

echo ":: probe  layer-shell-qt output-pinning API"
if probe_ls CASEDASH_LS_SETSCREEN 'w->setScreen(nullptr);'; then
    echo "::        setScreen()                (layer-shell-qt >= 6.7)"
elif probe_ls CASEDASH_LS_SCREENCONFIG 'w->setScreenConfiguration(LayerShellQt::Window::ScreenFromQWindow);'; then
    echo "::        setScreenConfiguration()   (6.0 - 6.6, deprecated)"
elif probe_ls CASEDASH_LS_DESIREDOUTPUT 'w->setDesiredOutput(nullptr);'; then
    echo "::        setDesiredOutput()         (Plasma 5 / 5.x)"
else
    echo "!! No known layer-shell-qt output-pinning API found." >&2
    echo "   The dashboard cannot pin itself to a specific output without one," >&2
    echo "   so it would land on whatever the compositor picks." >&2
    exit 1
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
    $QT_INC $LS_CFLAGS $LS_DEFS \
    -o "$BUILD/casedash" "$HERE/src/host.cpp" \
    $QT_LIB $LS_LIBS

echo ":: built $BUILD/casedash"
ls -la "$BUILD/casedash"
