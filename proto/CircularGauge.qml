import QtQuick

// A real GPU-drawn gauge: background arc, value arc, centred readout.
// This is the visual upgrade over Conky's block-character graphs, and it costs
// nothing extra -- QtQuick renders it on the GPU.
Item {
    id: gauge
    property string label: "CPU"
    property real value: 0.0        // 0.0 .. 1.0
    property string unit: "%"
    property string subtext: ""
    property color accent: "#C86414"

    width: 280
    height: 300

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            var ctx = getContext("2d")
            var cx = width / 2
            var cy = width / 2
            var r = width / 2 - 18
            var start = Math.PI * 0.75
            var span = Math.PI * 1.5

            ctx.reset()

            // Track
            ctx.beginPath()
            ctx.lineWidth = 18
            ctx.strokeStyle = "#242424"
            ctx.arc(cx, cy, r, start, start + span, false)
            ctx.stroke()

            // Value arc
            ctx.beginPath()
            ctx.lineWidth = 18
            ctx.strokeStyle = gauge.accent
            ctx.lineCap = "round"
            ctx.arc(cx, cy, r, start, start + span * gauge.value, false)
            ctx.stroke()
        }

        Connections {
            target: gauge
            function onValueChanged() { canvas.requestPaint() }
        }
        Component.onCompleted: requestPaint()
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: width / 2 - 62
        spacing: 4
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Math.round(gauge.value * 100) + gauge.unit
            color: "#e8e8e8"
            font.family: "DejaVu Sans Mono"
            font.pixelSize: 52
            font.bold: true
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: gauge.subtext
            color: gauge.accent
            font.family: "DejaVu Sans Mono"
            font.pixelSize: 26
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        text: gauge.label
        color: "#888888"
        font.family: "DejaVu Sans Mono"
        font.pixelSize: 28
    }
}
