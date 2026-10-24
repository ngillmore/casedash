# Contributing

Short version: this is a personal project that happens to be public. Issues and
PRs are welcome, but the panel is tuned to one specific screen, so anything that
changes the layout needs to say *why*.

## Ground rules

- **No cmake.** The whole renderer is one translation unit. `renderer/build.sh`
  (plain `g++` + `pkg-config`) is deliberate: fewer moving parts, one less thing
  an update can break. See the README.
- **Probes must degrade, not fail.** The collector runs on hardware that may not
  have an NVIDIA GPU, an APC UPS, or the same network interface. A missing source
  is `null` in the JSON, never an exception. A panel with blank fields is fine; a
  collector that dies takes the whole display with it.
- **Pixels are evidence.** If you change rendering, verify against a real capture,
  not against `systemctl is-active`. `./verify.sh` asserts KWin geometry and
  layer; extend it rather than trusting service state.
- **Keep the collector off the game's resources.** `Nice`/`CPUWeight`/`MemoryMax`
  in the units are load-bearing on a gaming box. Don't raise them.
- **Proportions are tuned by hand.** Layout numbers live in `renderer/qml/Ui.qml`
  behind one `scale`. Add a metric there rather than a new literal in a component,
  so the panel can't drift out of proportion.

## Before opening a PR

```bash
./renderer/build.sh          # must compile clean
./verify.sh                  # must report OK on a running panel
python3 -m py_compile collector/casedash_collector.py
qmllint renderer/qml/*.qml
```

CI runs the first and third of those, plus a collector import smoke test.

## Reporting a bug

The failure mode this project exists to prevent is a **black panel with a healthy
unit**. If you hit that, please include:

- output of `./verify.sh`
- `systemctl --user status casedash casedash-collector`
- `journalctl --user -u casedash -n 50`
- your output name (`kscreen-doctor -o`) and its geometry

## License

By contributing you agree your work is released under the MIT License.
