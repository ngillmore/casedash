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
MOC=$(command -v moc6 || command -v /usr/lib/qt6/moc || command -v moc || true)
if [ -z "$MOC" ]; then
    MOC=$(find /usr -name 'moc' -path '*qt6*' 2>/dev/null | head -1 || true)
fi
if [ -z "$MOC" ]; then
    echo "!! Qt6 moc not found" >&2
    exit 1
fi

echo ":: moc   $MOC"
"$MOC" "$HERE/src/host.cpp" -o "$BUILD/host.moc"

echo ":: g++   compiling"
g++ -std=c++17 -O2 -fPIC \
    -I"$BUILD" -I"$HERE/src" \
    $QT_INC $LS_CFLAGS \
    -o "$BUILD/casedash" "$HERE/src/host.cpp" \
    $QT_LIB $LS_LIBS

echo ":: built $BUILD/casedash"
ls -la "$BUILD/casedash"
