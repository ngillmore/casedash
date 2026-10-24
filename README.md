# Case Screen Dashboard (casedash)

A self-owned telemetry dashboard for the HYTE Y70 case screen (DP-1, 1100x3840,
rotated 90° CW), built to replace Conky.

## Why this exists

Conky broke on this machine three times in four months, each time from a
different system update:

| When | What broke | Root cause |
|---|---|---|
| ~2026-07 | Panel invisible after Xwayland update | Xwayland stopped compositing X11 to the secondary output |
| 2026-10-13 | Crash loop (`status=6/ABRT`) | Conky 1.25.2 Wayland `pango_fonts.size()` assertion |
| 2026-10-22 | Black screen, unit "active" | Update dropped `pacman.conf.pacnew`, erasing the `IgnorePkg = conky` pin → 1.25.2 reinstalled → silent console fallback |

The pattern is structural, not bad luck: Conky fuses data collection with its
display backend, and it cannot select which output to draw on (upstream issue
#2106). So every update is a dice roll on a non-standard vertical panel.

**The fix is architectural.** Split the data layer from the render layer:

    collector  --->  /run/user/1000/casedash/state.json  --->  renderer
    (Python,          (one atomic JSON blob)                  (Qt6/QML,
     systemd user                                               layer-shell,
     service)                                                   pinned DP-1)

The renderer is now the *only* component coupled to the display stack. If a
Wayland or KWin update breaks it, it can be rewritten without touching a line of
telemetry code. Qt6's layer-shell integration is the same stack KDE itself uses,
and it can address an output by name, which is precisely what Conky cannot do.

## What it shows

Clock and date, weather, CPU load/temp/per-core, GPU util/temp/VRAM, RAM and
swap, network rates plus history, UPS status, disk usage, and system info.
Everything is polled from local sources (`/proc`, `/sys`, `nvidia-smi`,
`apcaccess`, `fastfetch`, `wttr.in`).

## Layout

    collector/casedash_collector.py   telemetry daemon -> state.json
    renderer/src/host.cpp             Qt6 C++ QML host + LayerShellQt pinning
    renderer/qml/                     QML UI (Theme.qml is generated)
    renderer/qml/Ui.qml               layout + type metrics (the `scale` knob)
    renderer/build.sh                 compile script (plain g++, no cmake)
    systemd/                          user units
    verify.sh                         pixel/geometry verification
    theme/casedash-theme.py           matugen template driver + RGB sync
    theme/matugen-hook.py             matugen post-hook entry point
    archive/                          archived Conky setup (fallback reference)

## Resizing the panel text

Every font size, padding value and row pitch derives from one number: `scale` in
`renderer/qml/Ui.qml`. Change it, restart the renderer, done — nothing else needs
editing.

```bash
# edit renderer/qml/Ui.qml -> readonly property real scale: 1.55
systemctl --user restart casedash.service
```

Why a scale factor rather than bigger literals: the panel is 1100x3840 and every
size was hand-tuned against a real capture. Scaling from one number keeps those
tuned *proportions* intact, so the design looks the same, only larger.

Two notes when changing it:

- **`Ui.qml` is a QML singleton, not a context property.** A context property is
  not visible inside imported component files — `Card.qml`/`KeyValue.qml` cannot
  see it, and every binding silently evaluates to `undefined` instead of erroring
  usefully. The singleton (declared in `qmldir`) is the only form that crosses
  file boundaries without build machinery.
- **Gauges use a separate, gentler `gaugeScale`.** Two gauges plus the
  VRAM/RAM/POWER value stack must fit inside 1100px; at the full text scale the
  gauges starved the value column until `10726 / 24564 MB` elided. The gauges were
  never the readability problem, so they grow less and give the width back to text.

Practical ceiling is about `scale: 1.7`. The two `Layout.fillHeight` cards (CPU
core, GPU util) absorb the slack; past that, the STORAGE and SYSTEM value columns
start eliding.

## Install

Requires Qt 6 (Core, Gui, Qml, Quick, moc), `layer-shell-qt`, and Python 3.
Nothing else — the collector uses only the standard library.

```bash
# 1. build the renderer
./renderer/build.sh

# 2. install the socket resolver the renderer unit expects
install -Dm755 /dev/stdin ~/.local/bin/casedash-wayland-env.sh <<'EOF'
#!/usr/bin/env bash
# Resolve whichever wayland-N socket exists this boot and exec the renderer.
for s in /run/user/$(id -u)/wayland-*; do
    [ -S "$s" ] || continue
    case "$s" in *.lock) continue ;; esac
    export WAYLAND_DISPLAY="$(basename "$s")"
    break
done
exec "$HOME/projects/casedash/renderer/build/casedash"
EOF

# 3. install and start the units
cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now casedash-collector.service casedash.service
systemctl --user enable --now casedash-verify.timer
```

## Usage

Verify the panel is actually drawing:

```bash
./verify.sh
```

Never trust `systemctl is-active` alone. Conky taught us that a unit can report
`active (running)` with a fully populated journal while the panel is pure black.
`verify.sh` asserts the KWin window geometry (`3440,0 1100x3840`), its layer
(0 = background), the process, and the freshness of `state.json`. A
`casedash-verify.timer` runs it every 15 minutes.

Theme: `theme apply` (matugen) writes `renderer/qml/Theme.qml` via the post-hook;
the renderer watches that file and reloads colours live. The same accent is
pushed to the Lian Li RGB controller so the fans and the panel match.

## Caveats

- **Path assumptions.** The units hardcode `/home/yak/projects/casedash`. Edit
  `systemd/*.service` and `verify.sh` if you clone elsewhere.
- **`QT_WAYLAND_SHELL_INTEGRATION=layer-shell` is mandatory.** Without it Qt uses
  its default xdg-shell integration, LayerShellQt refuses to attach ("already has
  a shell integration"), and the panel silently lands on the primary monitor.
- **The output is pinned by name.** `renderer/src/host.cpp` targets `DP-1`. If
  your case screen enumerates differently, change it there.
- **`QWindow::setScreen()` is ignored before `show()`** on Qt's Wayland backend.
  Output pinning must go through `LayerShellQt::Window::setScreen()`, which sets
  it on the layer surface rather than the toplevel.
- **No cmake.** The whole build is one translation unit; plain `g++` +
  `pkg-config` is fewer moving parts and one less thing an update can break.
- Hardware-specific probes (7800X3D core count, apcupsd UPS fields, `enp77s0`)
  degrade to `null` rather than failing, but will show as empty on other systems.

## License

MIT
