// Card: the section container. A heading rule plus content slot, so every
// section of the panel shares one visual language.
//
// All chrome (padding, header height, pip, radius) is driven by Ui so the card
// grows with the type instead of clipping it. implicitHeight is only a hint --
// main.qml sets explicit heights -- but it must still scale, because the two
// Layout.fillHeight cards derive their real height from the slack left over by
// the fixed ones, and a stale 52px chrome constant would silently mis-size them.
import QtQuick
import "."

Rectangle {
    id: card

    property string title: ""
    property string rightLabel: ""
    property color accent: (Backend.theme.accent || "#C86414")
    default property alias content: inner.data

    color: (Backend.theme.card || "#141414")
    radius: Ui.cardRadius
    border.color: Qt.rgba((Backend.theme.outline || "#333333").r, (Backend.theme.outline || "#333333").g, (Backend.theme.outline || "#333333").b, 0.35)
    border.width: 1
    implicitHeight: inner.implicitHeight + Ui.cardPadTop + Ui.cardHeadH + Ui.cardHeadGap + Ui.cardPadBot

    // Accent pip + title, and an optional right-aligned value/unit label.
    Item {
        id: head
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Ui.cardPad
        height: Ui.cardHeadH

        Rectangle {
            id: pip
            width: Ui.pipW
            height: Ui.pipH
            radius: Ui.pipW / 2
            color: card.accent
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            anchors.left: pip.right
            anchors.leftMargin: Ui.s(8)
            anchors.verticalCenter: parent.verticalCenter
            text: card.title.toUpperCase()
            color: (Backend.theme.muted || "#8a8a8a")
            font.family: "Noto Sans"
            font.pixelSize: Ui.fsCardTitle
            font.letterSpacing: Ui.s(2.0)
            font.bold: true
            elide: Text.ElideRight
            width: parent.width - pip.width - Ui.s(8) - rightText.width - Ui.s(10)
        }
        Text {
            id: rightText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: card.rightLabel
            color: card.accent
            font.family: "Noto Sans"
            font.pixelSize: Ui.fsCardRight
            font.bold: true
        }
    }

    Item {
        id: inner
        anchors.top: head.bottom
        anchors.topMargin: Ui.cardHeadGap
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Ui.cardPad
        anchors.rightMargin: Ui.cardPad
        anchors.bottomMargin: Ui.cardPadBot
    }
}
