import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire  // 导入Pipewire服务模块

import QtQuick
import QtQuick.Layouts

ShellRoot {
    // 主题颜色 (Tokyo Night 风格)
    property color colBg:       "#1a1b26"
    property color colFg:       "#a9b1d6"
    property color colMuted:    "#444b6a"
    property color colActive:   "#7aa2f7"
    property color colUrgent:   "#f7768e"
    property color colHasWin:   "#a9b1d6"
    property color colEmpty:    "#444b6a"
    property color colYellow:   "#e0af68"
    property color colCyan:     "#0db9d7"
    property color colGreen:    "#9ece6a"
    property color colRed:      "#f7768e"

    property string fontName:  "JetBrainsMono Nerd Font"
    property int fontSize:     13

    // ----- 系统信息属性 -----

    // CPU 跟踪
    property int cpuUsage: 0
    property var lastCpuIdle: 0
    property var lastCpuTotal: 0

    // 内存
    property int memUsage: 0

    // 音量
    property int volPercent: 0
    property bool volMuted: false

    // 电量
    property int batPercent: -1
    property bool batCharging: false

    // 输入法
    property string imDisplayName: "EN"

    // 刷新电量
    function refreshBattery() {
        var dev = UPower?.displayDevice
        if (dev?.isPresent) {
            var raw = dev.percentage
            batPercent = Math.round(raw <= 1 ? raw * 100 : raw)
            batCharging = dev.state === UPowerDeviceState.Charging
                || dev.state === UPowerDeviceState.FullyCharged
        } else {
            batPercent = -1
            batCharging = false
        }
    }

    // ----- 进程 -----

    // CPU 使用率
    Process {
        id: cpuProc
        command: ["sh", "-c", "head -1 /proc/stat"]
        stdout: SplitParser {
            onRead: data => {
                if (!data) return
                var parts = data.trim().split(/\s+/)
                var user  = parseInt(parts[1]) || 0
                var nice  = parseInt(parts[2]) || 0
                var sys   = parseInt(parts[3]) || 0
                var idle  = parseInt(parts[4]) || 0
                var iowait = parseInt(parts[5]) || 0
                var irq   = parseInt(parts[6]) || 0
                var soft  = parseInt(parts[7]) || 0

                var total = user + nice + sys + idle + iowait + irq + soft
                var idleTime = idle + iowait

                if (lastCpuTotal > 0) {
                    var totalDiff = total - lastCpuTotal
                    var idleDiff  = idleTime - lastCpuIdle
                    if (totalDiff > 0) {
                        cpuUsage = Math.round(100 * (totalDiff - idleDiff) / totalDiff)
                    }
                }
                lastCpuTotal = total
                lastCpuIdle  = idleTime
            }
        }
    }

    // 内存使用率 (解析 /proc/meminfo 避免 locale 问题)
    Process {
        id: memProc
        command: ["sh", "-c", "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t,a}' /proc/meminfo"]
        stdout: SplitParser {
            onRead: data => {
                if (!data) return
                var parts = data.trim().split(/\s+/)
                var total = parseInt(parts[0]) || 1
                var avail = parseInt(parts[1]) || 0
                memUsage = Math.round(100 * (total - avail) / total)
            }
        }
    }

    // pavucontrol
    Process {
        id: pavuProc
        command: ["pavucontrol"]
    }

    // ===== 音量（Pipewire）=====

    // 当前默认音频输出节点
    property var audioSink: null

    // 监听默认音频输出变化
    Connections {
        target: Pipewire
        function onDefaultAudioSinkChanged() {
            audioSink = Pipewire.defaultAudioSink
        }
    }

    // 绑定节点，使 audio.volume / audio.muted 可读
    PwObjectTracker {
        objects: [audioSink]
    }

    // 输入法状态
    Process {
        id: imProc
        command: ["fcitx5-remote", "-n"]
        stdout: SplitParser {
            onRead: data => {
                if (!data) return
                var raw = data.trim()
                var map = {
                    "keyboard-us": "EN",
                    "pinyin": "拼音",
                    "shuangpin": "双拼",
                    "wubi": "五笔",
                    "wbpx": "五笔拼音",
                    "erbi": "二笔",
                    "rime": "中州韵",
                    "cangjie": "仓颉"
                }
                imDisplayName = map[raw] || raw
            }
        }
    }

    // 定时更新系统信息
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            cpuProc.running = true
            memProc.running = true
            imProc.running = true
            refreshBattery()
        }
    }

    // 启动时初始化
    Component.onCompleted: {
        refreshBattery()
        cpuProc.running = true
        memProc.running = true
        imProc.running = true
        if (Pipewire.defaultAudioSink)
            audioSink = Pipewire.defaultAudioSink
    }

    // ===== Bar =====

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            property var modelData
            screen: modelData

            anchors { top: true; left: true; right: true }
            exclusiveZone: 30
            height: 30
            color: colBg

            RowLayout {
                anchors.fill: parent
                spacing: 0

                Item { width: 8 }

                // 工作区 1-10
                Repeater {
                    model: 10

                    Item {
                        Layout.preferredWidth: index === 9 ? 36 : 28
                        Layout.preferredHeight: parent.height

                        property var ws: Hyprland.workspaces.values.find(
                            w => w.id === index + 1) ?? null
                        property bool isActive: Hyprland.focusedWorkspace?.id === (index + 1)
                        property bool hasWindows: ws !== null && ws.toplevels.length > 0
                        property bool isUrgent: ws?.urgent ?? false

                        Text {
                            text: index + 1
                            color: isActive   ? colActive
                                 : isUrgent   ? colUrgent
                                 : hasWindows ? colHasWin
                                              : colEmpty
                            font.pixelSize: fontSize
                            font.family: fontName
                            font.bold: isActive
                            anchors.centerIn: parent
                        }

                        Rectangle {
                            width: 16; height: 3
                            radius: 1.5
                            color: isActive ? colActive : "transparent"
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 3
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Hyprland.dispatch("hl.dsp.focus({workspace = " + (index + 1) + "})")
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                // ----- 系统托盘 -----
                Row {
                    Layout.rightMargin: 8
                    spacing: 2

                    Repeater {
                        model: SystemTray.items

                        Item {
                            width: 28
                            height: bar.height

                            required property SystemTrayItem modelData

                            property string trayId: modelData.id.toLowerCase()
                            property string trayIcon: modelData.icon.toLowerCase()
                            property bool isFcitx: trayId.indexOf("fcitx") >= 0
                                || trayIcon.indexOf("fcitx") >= 0
                                || trayIcon.indexOf("input-keyboard") >= 0
                            visible: !isFcitx

                            Image {
                                anchors.centerIn: parent
                                source: modelData.icon
                                sourceSize { width: 20; height: 20 }
                            }

                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    if (mouse.button === Qt.RightButton && modelData.hasMenu)
                                        modelData.display(trayItem, mouse.x, mouse.y)
                                    else
                                        modelData.activate()
                                }
                            }
                        }
                    }
                }

                // 输入法
                Text {
                    text: imDisplayName
                    color: colFg
                    font.pixelSize: fontSize
                    font.family: fontName
                    font.bold: true
                    Layout.rightMargin: 10
                    Layout.minimumWidth: 24
                    horizontalAlignment: Text.AlignHCenter
                }

                // ----- 分隔线 -----
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // CPU
                Text {
                    text: " " + cpuUsage + "%"
                    color: colYellow
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 10
                }

                // 分隔线
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // 内存
                Text {
                    text: " " + memUsage + "%"
                    color: colCyan
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 10
                }

                // 分隔线
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // 电量（仅在有电池时显示）
                Text {
                    visible: batPercent >= 0
                    text: batCharging ? " " + batPercent + "%" : " " + batPercent + "%"
                    color: batPercent <= 15 ? colRed : colGreen
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 10
                }

                // 分隔线（仅在电量可见时显示前分隔线）
                Rectangle {
                    visible: batPercent >= 0
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // 分隔线
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // 音量
                Text {
                    id: volText
                    text: {
                        var a = audioSink?.audio
                        var pct = a ? Math.round(a.volume * 100) : 0
                        var muted = a?.muted ?? false
                        var icon = muted ? "" : pct > 66 ? "" : pct > 33 ? "" : ""
                        return icon + " " + pct + "%"
                    }
                    color: (audioSink?.audio?.muted ?? false) ? colMuted : colFg
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 10

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            pavuProc.running = true
                        }
                    }
                }

                // 分隔线
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // 时钟
                Text {
                    id: clock
                    text: Qt.formatDateTime(new Date(), "HH:mm")
                    color: colFg
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 12

                    Timer {
                        interval: 1000
                        running: true
                        repeat: true
                        onTriggered: {
                            clock.text = Qt.formatDateTime(new Date(), "HH:mm")
                        }
                    }
                }
            }
        }
    }
}
