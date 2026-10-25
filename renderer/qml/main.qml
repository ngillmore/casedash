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
    readonly property real margin: Ui.margin

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: win.margin
        spacing: Ui.colSpacing

            // ============================================ clock + date + weather
            // Sized to content rather than a fixed 465px. The old fixed height
            // left ~100px of dead space between the weather line and the gauges,
            // which is space the fillHeight cards below need more than this
            // block does. Column drives the height via implicitHeight.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: headCol.implicitHeight

                Column {
                    id: headCol
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    spacing: 0

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Backend.clock
                        color: (Backend.theme.accent || "#C86414")
                        font.family: "Noto Sans"
                        font.pixelSize: Ui.fsClock
                        font.bold: true
                        font.letterSpacing: Ui.s(-3)
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Backend.datestr
                        color: (Backend.theme.foreground || "#e8e8e8")
                        font.family: "Noto Sans"
                        font.pixelSize: Ui.fsDate
                        font.letterSpacing: Ui.s(1)
                    }

                    // Weather, below the date. The old layout anchored this to
                    // the bottom of a fixed-height Item, which put it flush under
                    // the date with no breathing room once the block was resized
                    // to content. headerWxGap is now the single knob for it.
                    Item {
                        width: 1
                        height: Ui.headerWxGap
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Ui.s(10)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: win.wxGlyph(win.wx.code)
                            color: (Backend.theme.accent || "#C86414")
                            font.pixelSize: Ui.fsWxGlyph
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: win.wx.temp_f !== undefined ? win.wx.temp_f + "°F" : "--"
                            color: (Backend.theme.foreground || "#e8e8e8")
                            font.family: "Noto Sans"
                            font.pixelSize: Ui.fsWxTemp
                            font.bold: true
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: (win.wx.desc || "") + (win.wx.area ? "  ·  " + win.wx.area : "")
                            color: (Backend.theme.muted || "#8a8a8a")
                            font.family: "Noto Sans"
                            font.pixelSize: Ui.fsWxDesc
                        }
                    }
                }
            }

            // ================================================== CPU + GPU gauges
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Ui.s(Ui.hGaugeRow)
                spacing: Ui.s(8)

                CircularGauge {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Ui.gaugeSize
                    Layout.preferredHeight: Ui.gaugeSize
                    label: "CPU LOAD"
                    value: (win.cpu.load || 0) / 100
                    unit: "%"
                    subtext: win.cpu.temp !== undefined && win.cpu.temp !== null
                             ? Math.round(win.cpu.temp) + "°C" : "--"
                    midtext: win.cpu.count ? win.cpu.count + "C / " + (win.cpu.logical || 16) + "T" : ""
                }

                CircularGauge {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Ui.gaugeSize
                    Layout.preferredHeight: Ui.gaugeSize
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
                    spacing: Ui.s(9)

                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(72)
                        label: "VRAM"
                        value: win.gpu.vram_used !== undefined
                               ? (win.gpu.vram_used + " / " + win.gpu.vram_total + " MB") : "--"
                        trailing: win.pct(win.gpu.vram_pct, 0)
                        valueColor: (Backend.theme.foreground || "#e8e8e8")
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.gpu.vram_pct || 0) / 100
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(90)
                        label: "RAM"
                        value: win.mb(win.ram.used_mb) + " / " + win.mb(win.ram.total_mb)
                        trailing: win.pct(win.ram.pct, 0)
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.ram.pct || 0) / 100
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(90)
                        label: "POWER"
                        value: win.gpu.power !== undefined ? win.num(win.gpu.power, 0) + " W" : "--"
                        trailing: win.gpu.power_limit !== undefined
                                  ? "of " + win.num(win.gpu.power_limit, 0) + "W" : ""
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        value: win.gpu.power_limit ? (win.gpu.power / win.gpu.power_limit) : 0
                    }
                }
            }

            // ================================================ per-core CPU bars
            // Layout.fillHeight: this card takes a share of whatever vertical
            // space the fixed sections leave. The preferredHeight below is only
            // a hint for the initial pass -- the real height comes from the
            // leftover distribution. It MUST stay small enough that the sum of
            // all hints fits the panel, or QML resolves the overflow by letting
            // cards overlap (which is how the CPU sparkline ended up sliding
            // under the GPU card). See layoutBudget() in Ui.qml.
            Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Ui.s(Ui.hCpuCard)
                title: win.cpu.model || "CPU"
                rightLabel: win.pct(win.cpu.load, 1)

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Ui.s(6)

                    CoreBars {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Ui.s(120)
                        values: win.cpu.cores || []
                    }
                    Sparkline {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: Ui.s(50)
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
                Layout.preferredHeight: Ui.s(Ui.hGpuCard)
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
                Layout.preferredHeight: Ui.s(Ui.hNetCard)
                title: "NETWORK  ·  " + (win.net.iface || "")

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Ui.s(4)

                    RowLayout {
                        Layout.fillWidth: true
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▼ DOWN"
                            value: win.bytes(win.net.rx_rate)
                            valueColor: (Backend.theme.accent || "#C86414")
                        }
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▲ UP"
                            value: win.bytes(win.net.tx_rate)
                            valueColor: (Backend.theme.secondary || "#C86414")
                        }
                    }

                    // Fills the space between the rate rows rather than taking a
                    // fixed height. The old fixed 140px left a visible dead gap
                    // above and below the graph on a card that had too much
                    // height to begin with.
                    Sparkline {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: Ui.s(70)
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
                        }
                        KeyValue {
                            Layout.fillWidth: true
                            label: "▲ TOTAL"
                            value: win.sizeB(win.net.tx_total)
                        }
                    }
                }
            }

            // ============================================================ UPS
            Card {
                Layout.fillWidth: true
                Layout.preferredHeight: Ui.s(Ui.hUps)
                title: "UPS  ·  " + (win.ups.status || "--")
                accent: (win.ups.status || "").indexOf("ONBATT") >= 0 ? (Backend.theme.warn || "#ff6b6b") : (Backend.theme.ok || "#7dd87d")

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Ui.s(4)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Ui.s(10)

                        KeyValue {
                            Layout.fillWidth: true
                            labelWidth: Ui.s(96)
                            label: "LINE"
                            value: win.num(win.ups.linev, 1)
                            unit: "V"
                        }
                        KeyValue {
                            Layout.fillWidth: true
                            labelWidth: Ui.s(96)
                            label: "LOAD"
                            value: win.ups.watts !== undefined ? String(win.ups.watts) : "--"
                            unit: "W"
                            trailing: win.pct(win.ups.load_pct, 0)
                        }
                    }

                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(120)
                        label: "CHARGE"
                        value: win.pct(win.ups.charge, 0)
                        trailing: win.ups.runtime !== undefined
                                  ? win.num(win.ups.runtime, 1) + " min left" : ""
                        valueColor: (win.ups.charge || 0) < 50 ? (Backend.theme.warn || "#ff6b6b") : (Backend.theme.ok || "#7dd87d")
                    }
                    // One bar only. The old second bar duplicated the LOAD
                    // percentage that the row above already prints as a trailing
                    // value, and cost vertical space the CPU chart needed.
                    ProgressBar {
                        Layout.fillWidth: true
                        value: (win.ups.charge || 0) / 100
                        fillColor: (Backend.theme.ok || "#7dd87d")
                        alertAt: 1.1
                        warnAt: 1.1
                    }
                }
            }

            // ====================================================== disk usage
            Card {
                Layout.fillWidth: true
                Layout.preferredHeight: Ui.s(Ui.hStorageBase) + Ui.s(Ui.hStoragePerDisk) * Math.max(1, win.disks.length)
                title: "STORAGE"
                // Show both directions; the old label was just the write rate
                // with no indication of what it was.
                rightLabel: "▼ " + win.bytes(win.st.disk_io ? win.st.disk_io.read : 0)
                           + "   ▲ " + win.bytes(win.st.disk_io ? win.st.disk_io.write : 0)

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Ui.s(7)

                    Repeater {
                        model: win.disks

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Ui.s(3)

                            KeyValue {
                                Layout.fillWidth: true
                                label: modelData.mount
                                value: modelData.used_gb + " / " + modelData.total_gb + " GB"
                                trailing: modelData.pct + "%"
                                valueColor: win.heatColor(modelData.pct)
                            }
                            ProgressBar {
                                Layout.fillWidth: true
                                value: modelData.pct / 100
                                barHeight: Ui.barHThin
                            }
                        }
                    }
                }
            }

            // ==================================================== system info
            Card {
                Layout.fillWidth: true
                // Height DERIVED from the rows this card actually contains, via
                // Ui.rowsCardH. The old hand-written literal was 31px short and
                // the DISPLAYS row rendered with its lower half off the card.
                // If you add or remove a row, update Ui.hSystemRows to match.
                Layout.preferredHeight: Ui.rowsCardH(Ui.hSystemRows)
                title: "SYSTEM"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Ui.s(2)

                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "OS"
                        value: (win.sys.os || "--") + "  ·  " + (win.st.kernel || win.sys.kernel || "")
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "HOST"
                        value: win.sys.host || "--"
                    }
                    // No trailing load average here: the CPU card header already
                    // shows load as a large percentage, so this was the same
                    // number twice in a less readable format.
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "UPTIME"
                        value: win.uptime(win.st.uptime_s)
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "SHELL"
                        value: win.sys.shell || "--"
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "DESKTOP"
                        value: (win.sys.de || "") + " / " + (win.sys.wm || "")
                    }
                    // No trailing percentage: the value already reads
                    // "3.1 GB / 61.9 GB", so "5%" was noise on a line that is
                    // never the interesting one.
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "SWAP"
                        value: win.mb(win.swap.used_mb) + " / " + win.mb(win.swap.total_mb)
                    }
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "LOCAL IP"
                        value: win.net.ip || "--"
                        mono: true
                    }
                    // One row, both displays, comma-separated. The old layout used
                    // a second KeyValue with a blank label, which left an orphan
                    // row when only one display was connected.
                    KeyValue {
                        Layout.fillWidth: true
                        labelWidth: Ui.s(150)
                        label: "DISPLAYS"
                        value: (win.sys.displays || []).length > 0
                               ? (win.sys.displays || []).join(", ").replace(/ \(primary\)/g, "")
                               : "--"
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Ui.s(Ui.hSpacer) }
    }

    // ------------------------------------------------------------ stale banner
    // If the collector stops writing, say so loudly instead of showing frozen
    // numbers. This is the exact failure mode that made Conky's black panel look
    // healthy: live-looking telemetry with nothing behind it.
    Rectangle {
        visible: win.stale
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Ui.s(12)
        width: staleText.implicitWidth + Ui.s(24)
        height: Ui.s(30)
        radius: Ui.s(6)
        color: (Backend.theme.warn || "#ff6b6b")
        opacity: 0.92

        Text {
            id: staleText
            anchors.centerIn: parent
            text: "⚠  " + (Backend.status || "collector down")
            color: (Backend.theme.background || "#0a0a0a")
            font.family: "Noto Sans"
            font.pixelSize: Ui.fsStale
            font.bold: true
        }
    }
}
