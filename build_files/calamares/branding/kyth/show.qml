/* Kyth installer slideshow — shown during the exec (installation) phase. */

import QtQuick 2.15
import QtQuick.Controls 2.15

Rectangle {
    anchors.fill: parent
    color: "#000000"

    Column {
        anchors.centerIn: parent
        spacing: 32

        // Kyth K logo
        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: "kyth-logo.svg"
            width: 96
            height: 96
            smooth: true
            mipmap: true
        }

        // Arc spinner — matches the Calamares arc style
        Canvas {
            id: spinner
            width: 44
            height: 44
            anchors.horizontalCenter: parent.horizontalCenter

            property real angle: 0

            NumberAnimation on angle {
                from: 0
                to: 360
                duration: 1100
                loops: Animation.Infinite
                running: true
            }

            onAngleChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = width / 2
                var cy = height / 2
                var r = 18

                // Dim track
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                ctx.strokeStyle = "#1e1e2e"
                ctx.lineWidth = 3
                ctx.stroke()

                // Spinning arc
                var start = (angle - 90) * Math.PI / 180
                var end   = start + 1.4 * Math.PI
                ctx.beginPath()
                ctx.arc(cx, cy, r, start, end)
                ctx.strokeStyle = "#7aa2f7"
                ctx.lineWidth = 3
                ctx.lineCap = "round"
                ctx.stroke()
            }
        }

        // Live status from /tmp/kyth-install-progress
        Text {
            id: statusText
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: 13
            color: "#6b7280"
            horizontalAlignment: Text.AlignHCenter
            text: "Preparing installation…"

            Timer {
                interval: 800
                running: true
                repeat: true
                onTriggered: {
                    var xhr = new XMLHttpRequest()
                    xhr.open("GET", "file:///tmp/kyth-install-progress", true)
                    xhr.onreadystatechange = function() {
                        if (xhr.readyState !== XMLHttpRequest.DONE) return
                        if (!xhr.responseText) return
                        var lines = xhr.responseText.split("\n")
                        if (lines.length >= 2 && lines[1].trim() !== "") {
                            statusText.text = lines[1].trim()
                        }
                    }
                    xhr.send()
                }
            }
        }
    }
}
