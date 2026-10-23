// KeyValue: a label/value row with a trailing unit or secondary value.
//
// Layout note: labels are left-aligned with a FIXED label column so values line
// up down a card, values hug that column, and only the optional trailing value
// is pushed to the right edge. An earlier version gave the value a fixed 40-46%
// width, which on this 1100px panel threw it halfway across the row and left a
// conspicuous hole in the middle of every line.
import QtQuick
import "."

Item {
    id: kv

    property string label: ""
    property string value: ""
    property string unit: ""
    property string trailing: ""
    property color valueColor: (Backend.theme.foreground || "#e8e8e8")
    property color labelColor: (Backend.theme.muted || "#8a8a8a")
    property int labelSize: 15
    property int valueSize: 15
    property bool mono: false
    property real labelWidth: 300

    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight) + 2

    Text {
        id: labelText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(kv.labelWidth, parent.width * 0.45)
        text: kv.label
        color: kv.labelColor
        font.family: "Noto Sans"
        font.pixelSize: kv.labelSize
        elide: Text.ElideRight
    }

    // Value hugs the label column instead of stretching across the row.
    Text {
        id: valueText
        anchors.left: labelText.right
        anchors.leftMargin: 12
        anchors.right: trailingText.visible ? trailingText.left : parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: kv.value + (kv.unit !== "" ? " " + kv.unit : "")
        color: kv.valueColor
        font.family: kv.mono ? "Noto Sans Mono" : "Noto Sans"
        font.pixelSize: kv.valueSize
        font.bold: true
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignLeft
    }

    Text {
        id: trailingText
        visible: kv.trailing !== ""
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: kv.trailing
        color: kv.labelColor
        font.family: "Noto Sans"
        font.pixelSize: kv.labelSize - 1
        horizontalAlignment: Text.AlignRight
    }
}
