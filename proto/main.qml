import QtQuick
import QtQuick.Window
import QtQuick.Layouts

// Root MUST be a Window for the C++ host (it casts the root object to
// QQuickWindow). Layer-shell configuration is applied from C++ via
// LayerShellQt::Window::get() -- the QML attached property is not used because
// it did not take effect here.
Window {
    id: win
    visible: true
    color: "#0a0a0a"
    width: 1100
    height: 3840

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 40
        spacing: 28

        Text {
            Layout.alignment: Qt.AlignHCenter
            color: "#C86414"
            font.family: "DejaVu Sans Mono"
            font.pixelSize: 92
            font.bold: true
            text: Qt.formatTime(new Date(), "hh:mm:ss AP")
            Timer {
                interval: 1000; running: true; repeat: true
                onTriggered: parent.text = Qt.formatTime(new Date(), "hh:mm:ss AP")
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            color: "#C86414"
            font.family: "DejaVu Sans Mono"
            font.pixelSize: 34
            text: Qt.formatDate(new Date(), "dddd, MMMM d, yyyy")
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 60
            CircularGauge { label: "CPU"; value: 0.37; unit: "%"; subtext: "54°C" }
            CircularGauge { label: "GPU"; value: 0.05; unit: "%"; subtext: "39°C" }
        }

        Rectangle { Layout.fillWidth: true; height: 2; color: "#333333" }

        Text {
            Layout.alignment: Qt.AlignHCenter
            color: "#888888"
            font.family: "DejaVu Sans Mono"
            font.pixelSize: 26
            text: "PROTOTYPE OK — layer-shell, output-pinned"
        }

        Item { Layout.fillHeight: true }
    }
}
