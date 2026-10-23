// Card: the section container. A heading rule plus content slot, so every
// section of the panel shares one visual language.
import QtQuick
import "."

Rectangle {
    id: card

    property string title: ""
    property string rightLabel: ""
    property color accent: (Backend.theme.accent || "#C86414")
    default property alias content: inner.data

    color: (Backend.theme.card || "#141414")
    radius: 10
    border.color: Qt.rgba((Backend.theme.outline || "#333333").r, (Backend.theme.outline || "#333333").g, (Backend.theme.outline || "#333333").b, 0.35)
    border.width: 1
    implicitHeight: inner.implicitHeight + 52

    // Accent pip + title, and an optional right-aligned value/unit label.
    Item {
        id: head
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 14
        height: 22

        Rectangle {
            id: pip
            width: 4
            height: 14
            radius: 2
            color: card.accent
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            anchors.left: pip.right
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: card.title.toUpperCase()
            color: (Backend.theme.muted || "#8a8a8a")
            font.family: "Noto Sans"
            font.pixelSize: 13
            font.letterSpacing: 2.0
            font.bold: true
        }
        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: card.rightLabel
            color: card.accent
            font.family: "Noto Sans"
            font.pixelSize: 14
            font.bold: true
        }
    }

    Item {
        id: inner
        anchors.top: head.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        anchors.bottomMargin: 12
    }
}
