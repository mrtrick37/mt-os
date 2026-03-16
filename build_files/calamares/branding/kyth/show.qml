/* Kyth installer slideshow — shown during the exec (installation) phase. */

import QtQuick 2.15
import QtQuick.Controls 2.15

Rectangle {
    anchors.fill: parent
    color: "#1e1e2e"

    Column {
        anchors.centerIn: parent
        spacing: 28

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Installing Kyth"
            font.pixelSize: 28
            font.bold: true
            color: "#c0caf5"
        }

        // Spinner
        Canvas {
            id: spinner
            width: 48
            height: 48
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
                var r = 20

                // Dim track
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                ctx.strokeStyle = "#313244"
                ctx.lineWidth = 3
                ctx.stroke()

                // Spinning arc
                var start = (angle - 90) * Math.PI / 180
                var end   = start + 1.4 * Math.PI   // ~250 degrees
                ctx.beginPath()
                ctx.arc(cx, cy, r, start, end)
                ctx.strokeStyle = "#7aa2f7"
                ctx.lineWidth = 3
                ctx.lineCap = "round"
                ctx.stroke()
            }
        }

        // Phase-aware status messages.
        // Each entry is [message, duration in ms].  The sequence mirrors the
        // actual bootc install phases so the displayed text roughly tracks what
        // is happening on disk.  The last message loops until install finishes.
        Text {
            id: statusText
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: 14
            color: "#9aa5ce"
            horizontalAlignment: Text.AlignHCenter

            property var phases: [
                ["Preparing target disk…",            3000],
                ["Partitioning and formatting…",      4000],
                ["Extracting OS image — this takes a few minutes…", 120000],
                ["Writing filesystem layers…",        30000],
                ["Committing ostree deployment…",     8000],
                ["Installing bootloader…",            6000],
                ["Configuring system…",               5000],
                ["Finalizing installation…",          5000]
            ]
            property int phaseIndex: 0
            text: phases[0][0]

            Timer {
                id: phaseTimer
                interval: statusText.phases[0][1]
                running: true
                repeat: false
                onTriggered: {
                    var next = statusText.phaseIndex + 1
                    if (next < statusText.phases.length) {
                        statusText.phaseIndex = next
                        statusText.text = statusText.phases[next][0]
                        phaseTimer.interval = statusText.phases[next][1]
                        // Loop on the last phase until Calamares closes the slideshow
                        phaseTimer.repeat = (next === statusText.phases.length - 1)
                        phaseTimer.restart()
                    }
                }
            }
        }

        // Sub-progress bar — driven by /tmp/kyth-install-progress written by
        // the Python install module every 1.5 s.  First line is a 0.0–1.0 float.
        Rectangle {
            id: subProgressTrack
            anchors.horizontalCenter: parent.horizontalCenter
            width: 320
            height: 4
            radius: 2
            color: "#313244"

            property real fraction: 0.0

            Timer {
                interval: 1500
                running: true
                repeat: true
                onTriggered: {
                    var xhr = new XMLHttpRequest()
                    xhr.open("GET", "file:///tmp/kyth-install-progress", false)
                    try {
                        xhr.send()
                        var val = parseFloat(xhr.responseText) || 0
                        if (val > 0) subProgressTrack.fraction = Math.min(val, 1.0)
                    } catch(e) {}
                }
            }

            Rectangle {
                width: subProgressTrack.width * subProgressTrack.fraction
                height: parent.height
                radius: parent.radius
                color: "#7aa2f7"
                Behavior on width { SmoothedAnimation { velocity: 6 } }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: 11
            color: "#565f89"
            text: Math.round(subProgressTrack.fraction * 100) + "% complete"
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Kyth is a gaming and development desktop\nbuilt on Fedora Kinoite with the CachyOS kernel."
            font.pixelSize: 13
            color: "#a9b1d6"
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
