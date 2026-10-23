// casedash -- case screen dashboard root.
//
// Root MUST be a Window: the C++ host casts the root object to QQuickWindow.
// All layer-shell configuration (including the DP-1 output pin) is applied from
// C++ via LayerShellQt::Window::get() -- the QML attached property did not take
// effect on this Qt build.
//
// Sized 1100x3840 because DP-1 is rotated 90 degrees in KScreen and layer-shell
// hands us the already-rotated logical geometry. Nothing here rotates anything.
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import "."

Window {
    id: win
    // MUST be false: the C++ host attaches layer-shell before showing, and a
    // visible QML Window would have already created an xdg toplevel (which
    // makes LayerShellQt refuse to attach and strands the panel on the primary
    // output). main() shows the window itself.
    visible: false
    color: (Backend.theme.background || "#0a0a0a")
    width: 1100
    height: 3840

    // Colours come from Backend.theme, parsed from the generated Theme.qml.
    // A QML singleton would have needed qmldir/CMake machinery, and bare QML
    // ids do not cross file boundaries -- a context property does both jobs.

    // ---------------------------------------------------------------- data
    // Backend.state is the collector's JSON blob. A newer backend hands us the
    // clock too, so QML owns no timers of its own.
    readonly property var st: Backend.state || ({})
    readonly property var cpu: st.cpu || ({})
    readonly property var gpu: st.gpu || ({})
    readonly property var ram: st.ram || ({})
    readonly property var swap: st.swap || ({})
    readonly property var net: st.net || ({})
    readonly property var ups: st.ups || ({})
    readonly property var wx: st.weather || ({})
    readonly property var sys: st.system || ({})
    readonly property var hist: st.hist || ({})
    readonly property var disks: st.disks || []

    property bool stale: !Backend.healthy

    // ------------------------------------------------------------ formatting
    function pct(v, digits) {
        if (v === undefined || v === null || !isFinite(v)) return "--"
        return v.toFixed(digits === undefined ? 0 : digits) + "%"
    }
    function num(v, digits) {
        if (v === undefined || v === null || !isFinite(v)) return "--"
        return v.toFixed(digits === undefined ? 1 : digits)
    }
    function bytes(b) {
        if (b === undefined || b === null || !isFinite(b)) return "--"
        var u = ["B/s", "KB/s", "MB/s", "GB/s"]
        var i = 0
        var v = Math.abs(b)
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++ }
        return (b < 0 ? "-" : "") + v.toFixed(v < 10 ? 2 : 1) + " " + u[i]
    }
    // Cumulative totals use the same scale but no "/s".
    function sizeB(b) {
        if (b === undefined || b === null || !isFinite(b)) return "--"
        var u = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        var v = Math.abs(b)
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++ }
        return (b < 0 ? "-" : "") + v.toFixed(v < 10 ? 2 : 1) + " " + u[i]
    }
    function mb(v) {
        if (v === undefined || v === null || !isFinite(v)) return "--"
        if (v >= 1024) return (v / 1024).toFixed(1) + " GB"
        return Math.round(v) + " MB"
    }
    function heatColor(p) {
        if (!isFinite(p)) return (Backend.theme.muted || "#8a8a8a")
        if (p >= 80) return (Backend.theme.warn || "#ff6b6b")
        if (p >= 60) return "#e8b04b"
        return (Backend.theme.foreground || "#e8e8e8")
    }
    function uptime(sec) {
        if (!isFinite(sec) || sec <= 0) return "--"
        var d = Math.floor(sec / 86400)
        var h = Math.floor((sec % 86400) / 3600)
        var m = Math.floor((sec % 3600) / 60)
        if (d > 0) return d + "d " + h + "h " + m + "m"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }
    // Load average normalised by core count, so "is the box busy" is readable.
    function loadRatio(l) {
        var n = cpu.count || 8
        if (!isFinite(l)) return 0
        return Math.min(1, l / n)
    }
    function wxGlyph(code) {
        if (code === undefined) return "◌"
        if (code === 113) return "☀"
        if (code === 116) return "⛅"
        if (code === 119 || code === 122) return "☁"
        if (code >= 200 && code < 300) return "⛈"
        if (code >= 300 && code < 400) return "☂"
        if (code >= 400 && code < 600) return "❄"
        if (code >= 600 && code < 700) return "❄"
        if (code >= 700 && code < 800) return "≈"
        if (code === 800) return "☀"
        if (code === 801 || code === 802) return "⛅"
        if (code >= 803) return "☁"
        return "◌"
    }

    // ---------------------------------------------------------------- layout
    //
    // The panel is 1100 wide by 3840 tall -- a 3.5:1 portrait strip. There is no
    // scaling trick here: width is fixed and equal to the design width, so the
    // sections are simply authored tall enough to fill the full height. Sizes
    // below are tuned against a real 3840px capture, not guessed.
    readonly property real margin: 30

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: win.margin
        spacing: 18

            // ============================================ clock + date + weather
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 300

                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    spacing: -6

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Backend.clock
                        color: (Backend.theme.accent || "#C86414")
                        font.family: "Noto Sans"
                        font.pixelSize: 118
                        font.bold: true
                        font.letterSpacing: -3
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Backend.datestr
                        color: (Backend.theme.foreground || "#e8e8e8")
                        font.family: "Noto Sans"
                        font.pixelSize: 30
                        font.letterSpacing: 1
                    }
                }

                // Weather, right under the date.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.wxGlyph(win.wx.code)
                        color: (Backend.theme.accent || "#C86414")
                        font.pixelSize: 40
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.wx.temp_f !== undefined ? win.wx.temp_f + "°F" : "--"
                        color: (Backend.theme.foreground || "#e8e8e8")
                        font.family: "Noto Sans"
                        font.pixelSize: 38
                        font.bold: true
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: (win.wx.desc || "") + (win.wx.area ? "  ·  " + win.wx.area : "")
                        color: (Backend.theme.muted || "#8a8a8a")
                        font.family: "Noto Sans"
                        font.pixelSize: 22
                    }
                }
            }

            // ================================================== CPU + GPU gauges
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 300
                spacing: 8

                CircularGauge {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 186
                    Layout.preferredHeight: 186
                    label: "CPU LOAD"
                    value: (win.cpu.load || 0) / 100
                    unit: "%"
                    subtext: win.cpu.temp !== undefined && win.cpu.temp !== null
                             ? Math.round(win.cpu.temp) + "°C" : "--"
                    midtext: win.cpu.count ? win.cpu.count + "C / " + (win.cpu.logical || 16) + "T" : ""
                }

                CircularGauge {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 186
                    Layout.preferredHeight: 186
                    label: "GPU LOAD"
                    value: (win.gpu.util || 0) / 100
                    unit: "%"
                    subtext: win.gpu.temp !== undefined ? Math.round(win.gpu.temp) + "°C" : "--"
                    midtext: win.gpu.clock !== undefined ? win.gpu.clock + " MHz" : ""
                }

                // VRAM / RAM / temps stack fills the leftover width.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 9

                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 90
                        label: "VRAM"
                        value: win.gpu.vram_used !== undefined
                               ? (win.gpu.vram_used + " / " + win.gpu.vram_total + " MB") : "--"
                        trailing: win.pct(win.gpu.vram_pct, 0)
                        valueColor: (Backend.theme.foreground || "#e8e8e8")
                        labelSize: 14
                        valueSize: 14
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.gpu.vram_pct || 0) / 100
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 90
                        label: "RAM"
                        value: win.mb(win.ram.used_mb) + " / " + win.mb(win.ram.total_mb)
                        trailing: win.pct(win.ram.pct, 0)
                        labelSize: 14
                        valueSize: 14
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.ram.pct || 0) / 100
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 90
                        label: "POWER"
                        value: win.gpu.power !== undefined ? win.num(win.gpu.power, 0) + " W" : "--"
                        trailing: win.gpu.power_limit !== undefined
                                  ? "of " + win.num(win.gpu.power_limit, 0) + "W" : ""
                        labelSize: 14
                        valueSize: 14
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: win.gpu.power_limit ? (win.gpu.power / win.gpu.power_limit) : 0
                    }
                }
            }

            // ================================================ per-core CPU bars
            Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 300
                title: win.cpu.model || "CPU"
                rightLabel: win.pct(win.cpu.load, 1)

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 6

                    CoreBars {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 150
                        values: win.cpu.cores || []
                    }
                    Sparkline {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 90
                        samples: win.hist.cpu || []
                        floorMax: 100
                        ceiling: 100
                        showGrid: false
                    }
                }
            }

            // ============================================ GPU utilisation chart
            Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 260
                title: "GPU UTILISATION  ·  " + (win.sys.gpu_model || "RTX 4090")
                rightLabel: win.pct(win.gpu.util, 0)

                Sparkline {
                    anchors.fill: parent
                    samples: win.hist.gpu || []
                    floorMax: 100
                    ceiling: 100
                }
            }

            // ======================================================== network
            Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: 340
                title: "NETWORK  ·  " + (win.net.iface || "")

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▼ DOWN"
                            value: win.bytes(win.net.rx_rate)
                            valueColor: (Backend.theme.accent || "#C86414")
                            labelSize: 15
                            valueSize: 17
                        }
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▲ UP"
                            value: win.bytes(win.net.tx_rate)
                            valueColor: (Backend.theme.secondary || "#C86414")
                            labelSize: 15
                            valueSize: 17
                        }
                    }

                    Sparkline {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 140
                        samples: win.hist.net_down || []
                        floorMax: 131072          // 128 KB/s floor so idle is not a flat line
                        line: (Backend.theme.accent || "#C86414")
                        fill: (Backend.theme.accentSoft || "#2a2a2a")
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▼ TOTAL"
                            value: win.sizeB(win.net.rx_total)
                            labelSize: 14
                            valueSize: 14
                        }
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▲ TOTAL"
                            value: win.sizeB(win.net.tx_total)
                            labelSize: 14
                            valueSize: 14
                        }
                    }
                }
            }

            // ============================================================ UPS
            Card {
                Layout.fillWidth: true
                Layout.preferredHeight: 300
                title: "UPS  ·  " + (win.ups.status || "--")
                accent: (win.ups.status || "").indexOf("ONBATT") >= 0 ? (Backend.theme.warn || "#ff6b6b") : (Backend.theme.ok || "#7dd87d")

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        KeyValue {
                            Layout.fillWidth: true
                            labelWidth: 96
                            label: "LINE"
                            value: win.num(win.ups.linev, 1)
                            unit: "V"
                            labelSize: 15
                            valueSize: 16
                        }
                        KeyValue {
                            Layout.fillWidth: true
                            labelWidth: 96
                            label: "LOAD"
                            value: win.ups.watts !== undefined ? String(win.ups.watts) : "--"
                            unit: "W"
                            trailing: win.pct(win.ups.load_pct, 0)
                            labelSize: 15
                            valueSize: 16
                        }
                    }

                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 120
                        label: "CHARGE"
                        value: win.pct(win.ups.charge, 0)
                        trailing: win.ups.runtime !== undefined
                                  ? win.num(win.ups.runtime, 1) + " min left" : ""
                        valueColor: (win.ups.charge || 0) < 50 ? (Backend.theme.warn || "#ff6b6b") : (Backend.theme.ok || "#7dd87d")
                        labelSize: 15
                        valueSize: 16
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.ups.charge || 0) / 100
                        fillColor: (Backend.theme.ok || "#7dd87d")
                        alertAt: 1.1
                        warnAt: 1.1
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.ups.load_pct || 0) / 100
                        barHeight: 6
                    }
                }
            }

            // ====================================================== disk usage
            Card {
                Layout.fillWidth: true
                Layout.preferredHeight: 50 + 84 * Math.max(1, win.disks.length)
                title: "STORAGE"
                // Show both directions; the old label was just the write rate
                // with no indication of what it was.
                rightLabel: "▼ " + win.bytes(win.st.disk_io ? win.st.disk_io.read : 0)
                           + "   ▲ " + win.bytes(win.st.disk_io ? win.st.disk_io.write : 0)

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 7

                    Repeater {
                        model: win.disks

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3

                            KeyValue {
                                Layout.fillWidth: true
                                label: modelData.mount
                                value: modelData.used_gb + " / " + modelData.total_gb + " GB"
                                trailing: modelData.pct + "%"
                                valueColor: win.heatColor(modelData.pct)
                                labelSize: 14
                                valueSize: 14
                            }
                            ProgressBar {
                                Layout.fillWidth: true
                                value: modelData.pct / 100
                                barHeight: 6
                            }
                        }
                    }
                }
            }

            // ==================================================== system info
            Card {
                Layout.fillWidth: true
                Layout.preferredHeight: 30 + 46 * 10
                title: "SYSTEM"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 2

                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "OS"
                        value: (win.sys.os || "--") + "  ·  " + (win.st.kernel || win.sys.kernel || "")
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "HOST"
                        value: win.sys.host || "--"
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "UPTIME"
                        value: win.uptime(win.st.uptime_s)
                        trailing: "load " + win.num((win.cpu.load_avg || [0])[0], 2)
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "SHELL"
                        value: win.sys.shell || "--"
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "DESKTOP"
                        value: (win.sys.de || "") + " / " + (win.sys.wm || "")
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "PACKAGES"
                        value: win.sys.packages !== undefined ? String(win.sys.packages) : "--"
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "SWAP"
                        value: win.mb(win.swap.used_mb) + " / " + win.mb(win.swap.total_mb)
                        trailing: win.pct(win.swap.pct, 0)
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "LOCAL IP"
                        value: win.net.ip || "--"
                        labelSize: 14
                        valueSize: 14
                        mono: true
                    }
                    // Displays: stacked, because there are two of them.
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: "DISPLAYS"
                        value: (win.sys.displays || []).length > 0
                               ? (win.sys.displays[0] || "").replace(" (primary)", "") : "--"
                        labelSize: 14
                        valueSize: 14
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: 150
                        label: ""
                        value: (win.sys.displays || []).length > 1
                               ? (win.sys.displays[1] || "").replace(" (primary)", "") : ""
                        labelSize: 14
                        valueSize: 14
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 20 }
    }

    // ------------------------------------------------------------ stale banner
    // If the collector stops writing, say so loudly instead of showing frozen
    // numbers. This is the exact failure mode that made Conky's black panel look
    // healthy: live-looking telemetry with nothing behind it.
    Rectangle {
        visible: win.stale
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 12
        width: staleText.implicitWidth + 24
        height: 30
        radius: 6
        color: (Backend.theme.warn || "#ff6b6b")
        opacity: 0.92

        Text {
            id: staleText
            anchors.centerIn: parent
            text: "⚠  " + (Backend.status || "collector down")
            color: (Backend.theme.background || "#0a0a0a")
            font.family: "Noto Sans"
            font.pixelSize: 14
            font.bold: true
        }
    }
}
