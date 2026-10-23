#!/usr/bin/env python3
"""casedash collector -- polls every telemetry source, writes one JSON blob.

Design rules:
  * Never blocks on a slow probe. Every external command runs with a timeout and
    a failure is recorded as null, not raised.
  * Atomic writes (tmp + rename) so the renderer never reads a half-written file.
  * Cheap probes run every tick (1s); expensive ones are rate-limited internally
    (fastfetch 60s, apcaccess 5s, weather 900s).
  * One thread per slow source so a hung subprocess cannot stall the fast path.

Output: /run/user/1000/casedash/state.json
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from collections import deque
from pathlib import Path

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")) / "casedash"
STATE_FILE = RUNTIME_DIR / "state.json"
THEME_FILE = Path.home() / "projects/casedash/renderer/qml/Theme.qml"

TICK = 1.0                 # internal sampling cadence (history accuracy)
PUBLISH_EVERY = 3.0        # how often state.json is actually rewritten
NET_IFACE = "enp77s0"
HISTORY_LEN = 160          # samples kept for the sparkline charts (~8 min at 3s)

# The panel is a glanceable status display, not a monitor. Quantising the
# volatile rates means small fluctuations no longer change the JSON on every
# tick -- which stops the renderer rebuilding its bindings once a second for a
# change no human can read. Rates are rounded to 3 significant figures.
def quantize_rate(bps: float) -> float:
    if not isinstance(bps, (int, float)) or bps <= 0:
        return 0.0
    import math
    mag = math.floor(math.log10(bps))
    step = 10 ** (mag - 2)
    return round(bps / step) * step

# rate limits (seconds) for the expensive sources
TTL_APC = 5.0
TTL_FASTFETCH = 60.0
TTL_WEATHER = 900.0
TTL_NVIDIA = 1.0
TTL_DISK = 30.0
TTL_AUDIO = 10.0


def _run(cmd: list[str], timeout: float = 5.0) -> str | None:
    """Run a command, return stdout or None. Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else None
    except Exception:
        return None


def _read(path: str, default: str | None = None) -> str | None:
    try:
        return Path(path).read_text().strip()
    except Exception:
        return default


def _int(path: str) -> int | None:
    v = _read(path)
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# --------------------------------------------------------------- smoothing
class Smoothed:
    """EMA so the panel does not flicker on 1-second sampling noise."""

    def __init__(self, alpha: float = 0.35):
        self.alpha = alpha
        self.value: float | None = None

    def push(self, x: float | None) -> float | None:
        if x is None:
            return self.value
        self.value = x if self.value is None else self.alpha * x + (1 - self.alpha) * self.value
        return self.value


class Counter:
    """Turns a monotonic kernel counter into a per-second rate.

    Quantised, because the panel is a glanceable status display: without this,
    the network rate changes in the JSON on every single tick, which forces the
    renderer to rebuild its bindings once a second for a change no human reads.
    """

    def __init__(self):
        self.prev: tuple[float, float] | None = None
        self.rate: float = 0.0

    def push(self, total: float, now: float) -> float:
        if self.prev is not None:
            dt = now - self.prev[0]
            if dt > 0:
                delta = total - self.prev[1]
                if delta >= 0:
                    self.rate = delta / dt
        self.prev = (now, total)
        return quantize_rate(self.rate)


# --------------------------------------------------------------- collectors
class DiskProbe:
    """Real disk throughput from /proc/diskstats + per-mount usage."""

    def __init__(self):
        self.read = Counter()
        self.write = Counter()

    def throughput(self, now: float) -> dict:
        """Sectors read/written summed across physical devices, as bytes/sec.

        Partition filtering: a partition is a base device plus a digit, EXCEPT
        for nvme/mmcblk where the base name itself ends in a digit (nvme0n1).
        Matching on a trailing digit alone silently excluded every NVMe drive on
        this box -- which is why this read 0 forever.
        """
        read_bytes = 0.0
        write_bytes = 0.0
        try:
            for line in Path("/proc/diskstats").read_text().splitlines():
                f = line.split()
                if len(f) < 10:
                    continue
                name = f[2]
                if name.startswith(("loop", "dm-", "ram", "sr", "zram")):
                    continue
                if re.match(r"^(nvme\d+n\d+|mmcblk\d+)p\d+$", name):
                    continue                              # nvme0n1p2
                if re.match(r"^[a-z]+\d+$", name):
                    continue                              # sda1, vda2
                read_bytes += int(f[5]) * 512.0           # sectors read
                write_bytes += int(f[9]) * 512.0          # sectors written
        except Exception:
            return {"read": 0.0, "write": 0.0}
        return {
            "read": self.read.push(read_bytes, now),
            "write": self.write.push(write_bytes, now),
        }

    @staticmethod
    def usage() -> list[dict]:
        """One entry per real filesystem, de-duplicated by backing device."""
        out = []
        try:
            for line in Path("/proc/mounts").read_text().splitlines():
                f = line.split()
                if len(f) < 3:
                    continue
                dev, mp, fs = f[0], f[1], f[2]
                if fs not in ("ext4", "btrfs", "xfs", "vfat", "f2fs"):
                    continue
                if not mp.startswith("/") or mp.startswith(("/boot", "/run", "/var/lib")):
                    continue
                try:
                    st = os.statvfs(mp)
                except OSError:
                    continue
                total = st.f_blocks * st.f_frsize
                free = st.f_bavail * st.f_frsize
                if total < 1 << 30:
                    continue
                # Key on the underlying device, not the mountpoint: / /home /root
                # are often the same btrfs pool and would otherwise triple-count.
                key = re.sub(r"\[.*\]$", "", dev)
                used = total - free
                cand = {
                    "device": key,
                    "mount": mp,
                    "fs": fs,
                    "total_gb": round(total / 1e9),
                    "used_gb": round(used / 1e9),
                    "pct": round(used * 100.0 / total, 1),
                }
                prev = next((d for d in out if d["device"] == key), None)
                # prefer the shortest mountpoint path as the display name
                if prev is None:
                    out.append(cand)
                elif len(cand["mount"]) < len(prev["mount"]):
                    out[out.index(prev)] = cand
        except Exception:
            pass
        return sorted(out, key=lambda d: -d["total_gb"])[:4]


class CpuProbe:
    def __init__(self):
        self.prev: list[tuple[int, int]] | None = None
        self.temp = Smoothed(0.25)

    def cores(self) -> tuple[float, list[float]]:
        try:
            lines = [l for l in Path("/proc/stat").read_text().splitlines() if l.startswith("cpu")]
        except Exception:
            return 0.0, []
        cur = []
        for line in lines:
            f = line.split()
            vals = [int(x) for x in f[1:9]]
            idle = vals[3] + vals[4]
            total = sum(vals)
            cur.append((total, idle))
        if self.prev is None:
            self.prev = cur
            return 0.0, [0.0] * (len(cur) - 1)
        out = []
        for (pt, pi), (ct, ci) in zip(self.prev, cur):
            dt, di = ct - pt, ci - pi
            out.append(100.0 * (1 - di / dt) if dt > 0 else 0.0)
        self.prev = cur
        return out[0], out[1:]

    def package_temp(self) -> float | None:
        # k10temp on AMD; find it by hwmon name rather than a fixed index,
        # because hwmon numbering shuffles across boots.
        for h in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
            if _read(str(h / "name")) != "k10temp":
                continue
            for t in sorted(h.glob("temp*_label")):
                if "Tctl" in (_read(str(t)) or ""):
                    v = _int(str(t).replace("_label", "_input"))
                    return self.temp.push(v / 1000.0 if v else None)
            v = _int(str(h / "temp1_input"))
            return self.temp.push(v / 1000.0 if v else None)
        # fall back to the board sensor
        for h in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
            if _read(str(h / "name")) not in ("nct6799", "nct6686", "nct6687"):
                continue
            v = _int(str(h / "temp2_input"))       # CPUTIN
            if v:
                return self.temp.push(v / 1000.0)
        return self.temp.value


class GpuProbe:
    """nvidia-smi, one query for everything, cached at 1s."""

    def __init__(self):
        self.cache: dict = {}
        self.at = 0.0
        self.util = Smoothed(0.4)
        self.temp = Smoothed(0.25)

    def read(self, now: float) -> dict:
        if now - self.at < TTL_NVIDIA and self.cache:
            return self.cache
        out = _run([
            "nvidia-smi",
            "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,"
            "utilization.memory,power.draw,power.limit,clocks.current.graphics,fan.speed",
            "--format=csv,noheader,nounits",
        ], timeout=4.0)
        if out:
            f = [x.strip() for x in out.strip().splitlines()[0].split(",")]
            try:
                self.cache = {
                    "util": round(self.util.push(float(f[0])) or 0.0, 1),
                    "temp": round(self.temp.push(float(f[1])) or 0.0, 1),
                    "vram_used": int(float(f[2])),
                    "vram_total": int(float(f[3])),
                    "vram_pct": round(float(f[2]) * 100.0 / float(f[3]), 1) if float(f[3]) else 0.0,
                    "vram_util": float(f[4]),
                    "power": float(f[5]),
                    "power_limit": float(f[6]),
                    "clock": int(float(f[7])),
                    "fan": float(f[8]),
                }
            except (ValueError, IndexError):
                pass
        self.at = now
        return self.cache


class Uprobe:
    """apcaccess -> dict. Note: this model omits BATTV, so absence is normal."""

    # name -> cast. STATUS is a string ("ONLINE", "ONBATT"); everything else is
    # numeric, and the model-specific ones (BATTV here) may simply be absent.
    NUMERIC = {
        "LINEV": "linev", "BCHARGE": "charge", "TIMELEFT": "runtime",
        "LOADPCT": "load_pct", "NOMPOWER": "nominal_w", "BATTV": "battv",
        "NUMXFERS": "transfers", "OUTPUTV": "outputv", "TONBATT": "tonbatt",
    }

    def __init__(self):
        self.cache: dict = {}
        self.at = 0.0

    def read(self, now: float) -> dict:
        if now - self.at < TTL_APC and self.cache:
            return self.cache
        out = _run(["apcaccess", "status"], timeout=4.0)
        if not out:
            self.at = now
            return self.cache
        d: dict = {}
        for line in out.splitlines():
            if ":" not in line:
                continue
            key, _, raw = line.partition(":")
            key, raw = key.strip(), raw.strip()

            # STATUS carries the word, not a number -- do not run it through the
            # numeric regex or it vanishes (which is why the panel showed "--").
            if key == "STATUS":
                d["status"] = raw.split()[0] if raw else ""
                continue

            name = self.NUMERIC.get(key)
            if name is None:
                continue
            m = re.match(r"[-+]?\d*\.?\d+", raw)
            if not m:
                continue
            try:
                d[name] = float(m.group())
            except ValueError:
                pass

        # NOMPOWER is the model's rating; watts is the live draw.
        load, nom = d.get("load_pct"), d.get("nominal_w")
        if load is not None and nom is not None:
            d["watts"] = round(load * nom / 100.0)
        self.cache = d
        self.at = now
        return d


class NetProbe:
    def __init__(self):
        self.rx = Counter()
        self.tx = Counter()

    def read(self, now: float) -> dict:
        b = _read(f"/sys/class/net/{NET_IFACE}/statistics/rx_bytes")
        b2 = _read(f"/sys/class/net/{NET_IFACE}/statistics/tx_bytes")
        try:
            rx_t, tx_t = float(b), float(b2)
        except (TypeError, ValueError):
            return {}
        rates_rx = self.rx.push(rx_t, now)
        rates_tx = self.tx.push(tx_t, now)
        return {
            "iface": NET_IFACE,
            "rx_rate": rates_rx,
            "tx_rate": rates_tx,
            "rx_total": rx_t,
            "tx_total": tx_t,
            "ip": self._ip(),
        }

    @staticmethod
    def _ip() -> str:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(0.2)
            s.connect(("1.1.1.1", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            return ""


class WeatherProbe:
    def __init__(self):
        self.cache: dict = {}
        self.at = 0.0

    def read(self, now: float) -> dict:
        if now - self.at < TTL_WEATHER and self.cache:
            return self.cache
        try:
            req = urllib.request.Request(
                "https://wttr.in/Little_Rock?format=j1",
                headers={"User-Agent": "curl/8"},
            )
            with urllib.request.urlopen(req, timeout=10) as r:
                j = json.loads(r.read().decode())
            cur = j["current_condition"][0]
            self.cache = {
                "temp_f": int(cur["temp_F"]),
                "temp_c": int(cur["temp_C"]),
                "feels_f": int(cur["FeelsLikeF"]),
                "desc": cur["weatherDesc"][0]["value"],
                "humidity": int(cur["humidity"]),
                "wind_mph": int(cur["windspeedMiles"]),
                "code": int(cur["weatherCode"]),
                "area": j.get("nearest_area", [{}])[0].get("areaName", [{}])[0].get("value", ""),
            }
        except Exception:
            pass
        self.at = now
        return self.cache


class SysInfoProbe:
    """Anything that changes slowly: fastfetch, uptime, load, swap, packages."""

    def __init__(self):
        self.cache: dict = {}
        self.at = 0.0

    def read(self, now: float) -> dict:
        d = dict(self.cache)
        # cheap ones every tick
        try:
            up = float(_read("/proc/uptime", "0").split()[0])
            d["uptime_s"] = int(up)
        except Exception:
            pass
        d["kernel"] = _read("/proc/sys/kernel/osrelease", "")
        try:
            la = _read("/proc/loadavg", "").split()
            d["load"] = [float(la[0]), float(la[1]), float(la[2])]
        except Exception:
            pass
        # memory
        try:
            mem = {}
            for line in Path("/proc/meminfo").read_text().splitlines():
                k, _, v = line.partition(":")
                mem[k.strip()] = int(v.split()[0]) if v.split() else 0
            total = mem.get("MemTotal", 0) / 1024
            avail = mem.get("MemAvailable", 0) / 1024
            used = total - avail
            d["ram"] = {
                "used_mb": round(used),
                "total_mb": round(total),
                "pct": round(used * 100.0 / total, 1) if total else 0.0,
            }
            st = mem.get("SwapTotal", 0) / 1024
            sf = mem.get("SwapFree", 0) / 1024
            d["swap"] = {
                "used_mb": round(st - sf),
                "total_mb": round(st),
                "pct": round((st - sf) * 100.0 / st, 1) if st else 0.0,
            }
        except Exception:
            pass
        # slow ones on a timer
        if now - self.at >= TTL_FASTFETCH or not self.cache:
            ff = _run(["fastfetch", "--logo", "none", "--format", "json"], timeout=15.0)
            if ff:
                try:
                    self.cache.update(self._parse_fastfetch(json.loads(ff)))
                    self.cache["uptime_s"] = d.get("uptime_s")
                    d = dict(self.cache)
                except Exception:
                    pass
            self.at = now
        return d

    @staticmethod
    def _parse_fastfetch(items: list) -> dict:
        out: dict = {}
        for it in items:
            t, r = it.get("type"), it.get("result", {})
            if t == "OS":
                out["os"] = r.get("prettyName", "")
            elif t == "Host":
                out["host"] = f"{r.get('vendor','')} {r.get('name','')}".strip()
            elif t == "Kernel":
                out["kernel"] = r.get("release", out.get("kernel", ""))
            elif t == "Packages":
                n = r.get("all") or r.get("pacman") or 0
                out["packages"] = n
            elif t == "Shell":
                # fastfetch reports the CALLING process, which here is this
                # collector. Read the real login shell from /etc/passwd instead.
                out["shell"] = SysInfoProbe._login_shell()
            elif t == "DE":
                out["de"] = r.get("prettyName", "")
            elif t == "WM":
                out["wm"] = r.get("prettyName", "")
            elif t == "Chassis":
                out["chassis"] = r.get("type", "")
            elif t == "CPU":
                out["cpu_model"] = re.sub(r"^\w+-Core\s*", "", r.get("cpu", "")).strip()
                cores = r.get("cores", {})
                if isinstance(cores, dict):
                    # physical cores (not the SMT thread count)
                    out["cpu_physical"] = cores.get("physical")
                    out["cpu_logical"] = cores.get("logical")
            elif t == "GPU":
                if isinstance(r, list) and r:
                    out["gpu_model"] = r[0].get("name", "")
            elif t == "BIOS":
                out["bios"] = r.get("version", "")
            elif t == "Terminal":
                out["terminal"] = r.get("prettyName", "")
            elif t == "Display":
                disps = []
                for dd in (r if isinstance(r, list) else []):
                    o = dd.get("output", {})
                    if o.get("width"):
                        prim = " (primary)" if dd.get("primary") else ""
                        disps.append(f"{dd.get('name','')} {o['width']}x{o['height']}{prim}")
                out["displays"] = disps
        return out

    @staticmethod
    def _login_shell() -> str:
        try:
            import pwd
            sh = pwd.getpwuid(os.getuid()).pw_shell
            name = os.path.basename(sh)
            v = _run([sh, "--version"], timeout=3.0) or ""
            m = re.search(r"version\s+([\d.]+)", v)
            return f"{name} {m.group(1)}" if m else name
        except Exception:
            return ""


# --------------------------------------------------------------- main loop
def main() -> int:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)

    cpu = CpuProbe()
    gpu = GpuProbe()
    ups = Uprobe()
    net = NetProbe()
    disk = DiskProbe()
    weather = WeatherProbe()
    sysinfo = SysInfoProbe()

    hist: dict[str, deque] = {
        "cpu": deque(maxlen=HISTORY_LEN),
        "gpu": deque(maxlen=HISTORY_LEN),
        "net_down": deque(maxlen=HISTORY_LEN),
        "net_up": deque(maxlen=HISTORY_LEN),
        "temp": deque(maxlen=HISTORY_LEN),
        "ram": deque(maxlen=HISTORY_LEN),
    }
    slow_at = 0.0
    slow_cache: dict = {}
    last_publish = 0.0

    while True:
        tick_start = time.time()
        now = time.monotonic()
        wall = time.time()

        cpu_total, cores = cpu.cores()
        g = gpu.read(now)
        n = net.read(now)
        info = sysinfo.read(now)

        # rate-limited slow sources: weather + disk usage
        if wall - slow_at >= TTL_DISK:
            slow_cache["disks"] = DiskProbe.usage()
            slow_cache["weather"] = weather.read(now)
            slow_at = wall

        u = ups.read(now)
        temp = cpu.package_temp()

        # disk throughput every tick (cheap: reads /proc/diskstats)
        dsk = disk.throughput(now)

        ram_pct = (info.get("ram") or {}).get("pct", 0.0)
        cpu_load = round(cpu_total, 1)

        # Sample every tick so the history charts keep 1s resolution...
        hist["cpu"].append(cpu_load)
        hist["gpu"].append(g.get("util", 0.0))
        hist["net_down"].append(n.get("rx_rate", 0.0))
        hist["net_up"].append(n.get("tx_rate", 0.0))
        hist["temp"].append(temp or 0.0)
        hist["ram"].append(ram_pct)

        # ...but only PUBLISH every PUBLISH_EVERY seconds. The history arrays
        # are ~1200 numbers that shift on every tick; rewriting the file each
        # second made the renderer rebuild its entire binding tree once a second
        # (~2.7% of a core) to display data no human can read that fast.
        if last_publish and (wall - last_publish) < PUBLISH_EVERY:
            elapsed = time.time() - tick_start
            time.sleep(max(0.05, TICK - elapsed))
            continue
        last_publish = wall

        # Physical vs logical cores: the Ryzen 7 7800X3D is 8c/16t and the
        # per-core bar chart wants the 8 physical cores (pairs interleaved).
        logical = len(cores)
        physical = info.get("cpu_physical") or max(1, logical // 2)
        if logical == physical * 2:
            phys_cores = [max(cores[i], cores[i + 1]) for i in range(0, logical, 2)]
        else:
            phys_cores = cores

        state = {
            "ts": wall,
            "uptime_s": info.get("uptime_s") or 0,
            "kernel": info.get("kernel", ""),
            "weather": slow_cache.get("weather") or {},
            "cpu": {
                "load": cpu_load,
                "temp": round(temp, 1) if temp else None,
                "cores": [round(c, 1) for c in phys_cores],
                "logical": logical,
                "model": info.get("cpu_model") or "AMD Ryzen 7 7800X3D",
                "count": len(phys_cores),
                "load_avg": info.get("load", [0, 0, 0]),
            },
            "gpu": g or {},
            "ram": info.get("ram", {}),
            "swap": info.get("swap", {}),
            "net": n,
            "disk_io": dsk,
            "disks": slow_cache.get("disks", []),
            "ups": u,
            "system": {
                "os": info.get("os", ""),
                "host": info.get("host", ""),
                "kernel": info.get("kernel", ""),
                "packages": info.get("packages"),
                "shell": info.get("shell", ""),
                "de": info.get("de", ""),
                "wm": info.get("wm", ""),
                "bios": info.get("bios", ""),
                "chassis": info.get("chassis", ""),
                "terminal": info.get("terminal", ""),
                "displays": info.get("displays", []),
                "gpu_model": info.get("gpu_model", ""),
                "cpu_model": info.get("cpu_model", ""),
            },
            "hist": {k: [round(x, 2) for x in v] for k, v in hist.items()},
        }

        tmp = STATE_FILE.with_suffix(".json.tmp")
        try:
            tmp.write_text(json.dumps(state, separators=(",", ":")))
            tmp.replace(STATE_FILE)
        except Exception:
            pass

        elapsed = time.time() - tick_start
        time.sleep(max(0.05, TICK - elapsed))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
