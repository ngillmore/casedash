// Sparkline: filled area chart over a rolling history array.
//
// Canvas rather than QtGraphs because these are simple area plots with no axes
// or interaction, and the history arrays are already in the collector's JSON.
// Handles an arbitrary data range (network rates span 0..100MB/s) by taking the
// max of the window with a sensible floor, so the line does not sit flat on the
// axis when the machine is idle.
import QtQuick
import "."

Item {
    id: spark

    property var samples: []            // array of numbers, oldest first
    property color line: (Backend.theme.accent || "#C86414")
    property color fill: (Backend.theme.accentSoft || "#2a2a2a")
    property color gridColor: (Backend.theme.grid || "#333333")
    property real floorMax: 1.0         // minimum scale ceiling
    property real ceiling: -1           // fixed ceiling, or -1 for auto
    property int gridLines: 3
    property bool showGrid: true
    property real lineWidth: 2.5
    property real headroom: 1.25        // leave space above the peak

    property real _max: {
        var m = floorMax
        for (var i = 0; i < samples.length; i++) {
            var v = samples[i]
            if (isFinite(v) && v > m) m = v
        }
        if (ceiling > 0) return ceiling
        return m * headroom
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative

        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            var n = spark.samples.length
            ctx.reset()
            if (n < 2) return

            var mx = spark._max
            if (mx <= 0) mx = 1

            if (spark.showGrid) {
                ctx.strokeStyle = spark.gridColor
                ctx.lineWidth = 1
                for (var g = 1; g <= spark.gridLines; g++) {
                    var y = h - (h * g / (spark.gridLines + 1))
                    ctx.beginPath()
                    ctx.moveTo(0, y + 0.5)
                    ctx.lineTo(w, y + 0.5)
                    ctx.stroke()
                }
            }

            var stepX = w / (n - 1)
            var pts = []
            for (var i = 0; i < n; i++) {
                var v = spark.samples[i]
                if (!isFinite(v)) v = 0
                var ratio = Math.max(0, Math.min(1, v / mx))
                pts.push([i * stepX, h - ratio * (h - 4) - 2])
            }

            // Filled area
            ctx.beginPath()
            ctx.moveTo(pts[0][0], h)
            for (var j = 0; j < pts.length; j++) ctx.lineTo(pts[j][0], pts[j][1])
            ctx.lineTo(pts[pts.length - 1][0], h)
            ctx.closePath()
            ctx.fillStyle = spark.fill
            ctx.fill()

            // Line on top
            ctx.beginPath()
            ctx.moveTo(pts[0][0], pts[0][1])
            for (var k = 1; k < pts.length; k++) ctx.lineTo(pts[k][0], pts[k][1])
            ctx.strokeStyle = spark.line
            ctx.lineWidth = spark.lineWidth
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            ctx.stroke()
        }

        Connections {
            target: spark
            function onSamplesChanged() { canvas.requestPaint() }
            function onLineChanged() { canvas.requestPaint() }
            function onFillChanged() { canvas.requestPaint() }
            function onGridColorChanged() { canvas.requestPaint() }
        }
        onWidthChanged: canvas.requestPaint()
        onHeightChanged: canvas.requestPaint()
    }
}
