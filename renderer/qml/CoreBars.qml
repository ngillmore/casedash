// CoreBars: one vertical bar per physical core.
import QtQuick
import "."

Item {
    id: bars

    property var values: []
    property var labels: []
    property color accent: (Backend.theme.accent || "#C86414")
    property color track: (Backend.theme.accentSoft || "#2a2a2a")
    property color textColor: (Backend.theme.muted || "#8a8a8a")
    property real warnAt: 0.80
    property color warnColor: "#e8b04b"

    implicitHeight: 66
    property real labelH: 14

    Row {
        id: row
        anchors.fill: parent
        spacing: 4

        Repeater {
            model: bars.values.length

            Item {
                width: (bars.width - (bars.values.length - 1) * row.spacing) / Math.max(1, bars.values.length)
                height: bars.height

                // Track
                Rectangle {
                    id: trackRect
                    anchors.top: parent.top
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(4, parent.width * 0.62)
                    height: parent.height - bars.labelH - 3
                    radius: width / 2
                    color: bars.track

                    // Value: grows from the bottom. radius is clamped so a tiny
                    // value does not render as a squashed pill.
                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        height: {
                            var v = bars.values[index]
                            if (!isFinite(v)) v = 0
                            return Math.max(0, Math.min(1, v / 100)) * parent.height
                        }
                        radius: Math.min(width / 2, height / 2)
                        color: {
                            var v = bars.values[index] || 0
                            return v >= 92 ? (Backend.theme.warn || "#ff6b6b") : (v >= bars.warnAt * 100 ? bars.warnColor : bars.accent)
                        }
                    }
                }

                Text {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: {
                        var l = bars.labels[index]
                        return l !== undefined ? l : (index + 1)
                    }
                    color: bars.textColor
                    font.family: "Noto Sans"
                    font.pixelSize: 11
                }
            }
        }
    }
}
