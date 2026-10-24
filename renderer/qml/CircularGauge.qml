// Circular gauge: track arc, value arc, centred readout, label underneath.
//
// Drawn on a Canvas (GPU-backed via QtQuick's renderer). Deliberately not
// QtGraphs: a gauge is one arc, and a declarative Canvas keeps the component
// self-contained and re-themeable without touching a chart backend.
import QtQuick
import "."

Item {
    id: gauge

    property string label: "CPU"
    property real value: 0.0            // 0.0 .. 1.0
    property string unit: "%"
    property string subtext: ""
    property string midtext: ""         // optional text next to the subtext
    property color accent: (Backend.theme.accent || "#C86414")
    property color track: (Backend.theme.accentSoft || "#2a2a2a")
    property color textColor: (Backend.theme.foreground || "#e8e8e8")
    property color labelColor: (Backend.theme.muted || "#8a8a8a")
    property real startAngle: Math.PI * 0.75
    property real sweep: Math.PI * 1.5
    // Warning thresholds: the arc recolours rather than adding more chrome.
    property real warnAt: 0.80
    property real alertAt: 0.92
    property color warnColor: "#e8b04b"
    property color alertColor: (Backend.theme.warn || "#ff6b6b")

    property real _v: Math.max(0.0, Math.min(1.0, isFinite(value) ? value : 0.0))
    property color _arc: _v >= alertAt ? alertColor : (_v >= warnAt ? warnColor : accent)

    // Arc thickness scales with the gauge so the ring does not turn into a hairline.
    property real thickness: Ui.s(16)

    width: Ui.gaugeSize
    height: Ui.gaugeSize

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative

        onPaint: {
            var ctx = getContext("2d")
            var cx = width / 2
            var cy = width / 2
            var r = width / 2 - gauge.thickness / 2 - 2
            var start = gauge.startAngle
            var span = gauge.sweep

            ctx.reset()
            ctx.lineCap = "round"

            // Track
            ctx.beginPath()
            ctx.lineWidth = gauge.thickness
            ctx.strokeStyle = gauge.track
            ctx.arc(cx, cy, r, start, start + span, false)
            ctx.stroke()

            // Value
            if (gauge._v > 0.001) {
                ctx.beginPath()
                ctx.lineWidth = gauge.thickness
                ctx.strokeStyle = gauge._arc
                ctx.arc(cx, cy, r, start, start + span * gauge._v, false)
                ctx.stroke()
            }
        }

        Connections {
            target: gauge
            function onValueChanged() { canvas.requestPaint() }
            function onAccentChanged() { canvas.requestPaint() }
            function onTrackChanged() { canvas.requestPaint() }
        }
        Component.onCompleted: requestPaint()
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -2
        spacing: 0

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Math.round(gauge._v * 100)
            color: gauge._arc
            font.family: "Noto Sans"
            font.pixelSize: Math.round(gauge.width * 0.26)
            font.bold: true
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: gauge.subtext !== ""
            text: gauge.subtext
            color: gauge.textColor
            font.family: "Noto Sans"
            font.pixelSize: Math.round(gauge.width * 0.13)
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: gauge.midtext !== ""
            text: gauge.midtext
            color: gauge.labelColor
            font.family: "Noto Sans"
            font.pixelSize: Math.round(gauge.width * 0.10)
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.bottom
        anchors.topMargin: 2
        text: gauge.label
        color: gauge.labelColor
        font.family: "Noto Sans"
        font.pixelSize: Math.round(gauge.width * 0.13)
        font.letterSpacing: 1.5
    }
}
