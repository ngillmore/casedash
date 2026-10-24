// ProgressBar: a horizontal bar for VRAM / RAM / disk usage.
import QtQuick
import "."

Item {
    id: pb

    property real value: 0.0            // 0.0 .. 1.0
    property color fillColor: (Backend.theme.accent || "#C86414")
    property color trackColor: (Backend.theme.accentSoft || "#2a2a2a")
    property real barHeight: Ui.barH
    property real radius: barHeight / 2
    property real warnAt: 0.85
    property real alertAt: 0.94

    implicitHeight: barHeight
    property real _v: Math.max(0.0, Math.min(1.0, isFinite(value) ? value : 0.0))
    property color _fill: _v >= alertAt ? (Backend.theme.warn || "#ff6b6b") : (_v >= warnAt ? "#e8b04b" : fillColor)

    Rectangle {
        anchors.fill: parent
        radius: pb.radius
        color: pb.trackColor

        Rectangle {
            width: parent.width * pb._v
            height: parent.height
            radius: Math.min(pb.radius, width / 2)
            color: pb._fill

            Behavior on width {
                NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
            }
        }
    }
}
