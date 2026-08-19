//@ pragma UseQApplication

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
    property color colHasWin:   "#6f8fe0"
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

    // DeepSeek 余额/用量
    property string dsText: "DS 未配置deepseek密钥"

    // 火山方舟 Coding Plan 用量
    property string arkText: "Ark 加载中..."
    property var arkDetail: []
    property real arkMax: 0
    property string arkError: ""

    function arkPctAt(i) {
        if (arkDetail && arkDetail[i]) return arkDetail[i].percent
        return 0
    }
    function arkColorAt(i) {
        if (arkError.length > 0) return colRed
        var p = arkPctAt(i)
        if (p >= 80) return colRed
        if (p >= 50) return colYellow
        return colGreen
    }
    function arkColor() {
        if (arkError.length > 0) return colRed
        if (arkMax >= 80) return colRed
        if (arkMax >= 50) return colYellow
        return colGreen
    }

    // 节假日数据 (date -> "off" | "work")
    property var holidayMap: ({})

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

    // DeepSeek 余额/用量查询（每 60 秒刷新）
    Process {
        id: dsProc
        command: ["python3", Quickshell.shellDir + "/ds_usage.py"]
        stdout: SplitParser {
            onRead: data => {
                if (data) dsText = data.trim()
            }
        }
    }

    // 火山方舟 Coding Plan 用量查询（每 60 秒刷新）
    Process {
        id: arkProc
        command: ["python3", Quickshell.shellDir + "/ark_usage.py"]
        stdout: SplitParser {
            onRead: data => {
                if (!data) return
                try {
                    var obj = JSON.parse(data.trim())
                    arkText = obj.text || "Ark --"
                    arkDetail = obj.detail || []
                    arkMax = obj.max || 0
                    arkError = obj.error || ""
                } catch (e) {
                    arkText = "Ark 解析失败"
                    arkDetail = []
                    arkMax = 0
                    arkError = "bad_json"
                }
            }
        }
    }

    // 节假日数据查询（按年份）
    Process {
        id: holidayProc
        stdout: SplitParser {
            onRead: data => {
                try {
                    holidayMap = JSON.parse(data.trim())
                } catch (e) {
                    holidayMap = ({})
                }
            }
        }
    }

    function refreshHoliday(year) {
        holidayProc.command = ["python3", Quickshell.shellDir + "/holiday.py", String(year)]
        holidayProc.running = true
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            dsProc.running = true
            arkProc.running = true
        }
    }

    // 启动时初始化
    Component.onCompleted: {
        refreshBattery()
        cpuProc.running = true
        memProc.running = true
        imProc.running = true
        dsProc.running = true
        arkProc.running = true
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
            implicitHeight: 30
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
                        property bool hasWindows: ws !== null && ws.toplevels.values.length > 0
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

                // 火山方舟 Coding Plan 用量（在 DeepSeek 左边）
                Text {
                    id: arkTextEl
                    text: {
                        if (arkError.length > 0)
                            return '<font color="' + colRed + '">' + arkText + '</font>'
                        var p0 = arkDetail[0] ? arkDetail[0].percent.toFixed(1) : "--"
                        var p1 = arkDetail[1] ? arkDetail[1].percent.toFixed(1) : "--"
                        var p2 = arkDetail[2] ? arkDetail[2].percent.toFixed(1) : "--"
                        return '<font color="' + colCyan + '">Ark </font>'
                             + '<font color="' + arkColor() + '">'
                             + p0 + '% | ' + p1 + '% | ' + p2 + '%</font>'
                    }
                    textFormat: Text.StyledText
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 8
                    Layout.alignment: Qt.AlignBaseline

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: arkProc.running = true
                        onEntered: arkDetailPopup.open()
                        onExited: arkCloseTimer.start()
                    }
                }

                // Ark / DS 之间的分隔线
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 8
                    color: colMuted
                }

                // DeepSeek 余额/用量（点击立即刷新）
                Text {
                    text: {
                        if (dsText.indexOf("未配置") >= 0 || dsText.indexOf("失败") >= 0)
                            return '<font color="' + colRed + '">' + dsText + '</font>'
                        var m = dsText.match(/^DS\s+/)
                        var rest = m ? dsText.slice(m[0].length) : dsText
                        return '<font color="' + colCyan + '">DS </font>'
                             + '<font color="' + colGreen + '">' + rest + '</font>'
                    }
                    textFormat: Text.StyledText
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 8
                    Layout.alignment: Qt.AlignBaseline

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            dsProc.running = true
                            Qt.openUrlExternally("https://platform.deepseek.com/usage")
                        }
                    }
                }

                // ----- 系统托盘 -----
                Row {
                    Layout.rightMargin: 8
                    spacing: 2

                    Repeater {
                        model: SystemTray.items

                        Item {
                            id: trayItem
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
                                    if (mouse.button === Qt.RightButton && modelData.hasMenu) {
                                        var pos = trayItem.mapToItem(bar.contentItem, mouse.x, mouse.y)
                                        console.log("tray menu:", modelData.title || modelData.id, "pos:", pos.x, pos.y)
                                        modelData.display(bar, pos.x, pos.y)
                                    } else {
                                        modelData.activate()
                                    }
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

                // 时钟：日期 + 周几 + 时间（hover 展开日历）
                Text {
                    id: clockText
                    property var currentDate: new Date()
                    property var weeks: ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
                    text: currentDate.getFullYear() + "年"
                        + (currentDate.getMonth() + 1) + "月"
                        + currentDate.getDate() + "日 "
                        + weeks[currentDate.getDay()]
                        + " " + Qt.formatTime(currentDate, "HH:mm")
                    color: colFg
                    font.pixelSize: fontSize
                    font.family: fontName
                    Layout.rightMargin: 12

                    Timer {
                        interval: 1000
                        running: true
                        repeat: true
                        onTriggered: {
                            clockText.currentDate = new Date()
                        }
                    }

                    MouseArea {
                        id: clockArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: {
                            calendarPopup.open()
                        }
                        onExited: {
                            closeTimer.start()
                        }
                    }
                }
            }

            // ===== Ark 用量详情浮层 =====
            PopupWindow {
                id: arkDetailPopup
                visible: false
                grabFocus: false
                anchor.window: bar
                anchor.rect.x: {
                    var pt = arkTextEl.mapToItem(bar.contentItem, 0, 0)
                    var x = pt.x + arkTextEl.width - width
                    if (x < 0) x = 0
                    if (x + width > bar.width) x = bar.width - width
                    return x
                }
                anchor.rect.y: bar.height + 4
                width: 230
                height: 120
                color: "transparent"

                function periodColor(pct) {
                    if (pct >= 80) return colRed
                    if (pct >= 50) return colYellow
                    return colGreen
                }
                function periodName(lbl) {
                    if (lbl === "5h") return "5小时"
                    if (lbl === "W")  return "本周"
                    if (lbl === "M")  return "本月"
                    return lbl
                }
                function barWidth(pct) {
                    var v = Math.max(0, Math.min(100, pct))
                    return v * 1.4
                }
                function open() {
                    visible = true
                    arkCloseTimer.stop()
                }

                Timer {
                    id: arkCloseTimer
                    interval: 300
                    onTriggered: arkDetailPopup.visible = false
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: arkCloseTimer.stop()
                    onExited: arkCloseTimer.start()
                }

                Rectangle {
                    anchors.fill: parent
                    color: colBg
                    border.color: colMuted
                    border.width: 1
                    radius: 8

                    Column {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 6

                        Text {
                            text: "火山方舟 Coding Plan"
                            color: colCyan
                            font.pixelSize: fontSize - 1
                            font.family: fontName
                            font.bold: true
                        }

                        Repeater {
                            model: arkDetail

                            Column {
                                width: arkDetailPopup.width - 20
                                spacing: 2

                                required property var modelData

                                Row {
                                    width: parent.width
                                    Text {
                                        text: arkDetailPopup.periodName(modelData.label)
                                        color: colFg
                                        font.pixelSize: fontSize - 2
                                        font.family: fontName
                                        width: 48
                                    }
                                    Text {
                                        text: modelData.percent.toFixed(1) + "%"
                                        color: arkDetailPopup.periodColor(modelData.percent)
                                        font.pixelSize: fontSize - 2
                                        font.family: fontName
                                        font.bold: true
                                        width: 56
                                    }
                                    Text {
                                        text: "重置 " + modelData.reset
                                        color: colMuted
                                        font.pixelSize: fontSize - 3
                                        font.family: fontName
                                        horizontalAlignment: Text.AlignRight
                                        width: parent.width - 48 - 56
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 4
                                    radius: 2
                                    color: colMuted
                                    Rectangle {
                                        width: arkDetailPopup.barWidth(modelData.percent)
                                        height: parent.height
                                        radius: 2
                                        color: arkDetailPopup.periodColor(modelData.percent)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ===== 下拉日历 =====
            PopupWindow {
                id: calendarPopup
                visible: false
                grabFocus: false
                anchor.window: bar
                anchor.rect.x: bar.width - width - 12
                anchor.rect.y: bar.height + 4
                width: 268
                height: 250
                color: "transparent"

                property var viewDate: clockText.currentDate
                property int viewYear: viewDate.getFullYear()
                property int viewMonth: viewDate.getMonth()

                function open() {
                    viewYear = clockText.currentDate.getFullYear()
                    viewMonth = clockText.currentDate.getMonth()
                    visible = true
                    closeTimer.stop()
                    refreshHoliday(viewYear)
                }

                function daysInMonth(y, m) { return new Date(y, m + 1, 0).getDate() }

                function fmtDate(y, m, d) {
                    return y + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d
                }

                property var gridModel: {
                    let first = new Date(viewYear, viewMonth, 1).getDay()
                    let dim = daysInMonth(viewYear, viewMonth)
                    let prevDim = daysInMonth(viewYear, viewMonth - 1)
                    let today = clockText.currentDate
                    let arr = []
                    for (let i = 0; i < 42; i++) {
                        let day = i - first + 1
                        let inMonth = day >= 1 && day <= dim
                        let cy = viewYear, cm = viewMonth, cd = day
                        if (!inMonth) {
                            if (day < 1) { cm = viewMonth - 1; cd = prevDim + day }
                            else        { cm = viewMonth + 1; cd = day - dim }
                            cy = cm < 0 ? viewYear - 1 : (cm > 11 ? viewYear + 1 : viewYear)
                            cm = (cm + 12) % 12
                        }
                        let isToday = inMonth && cy === today.getFullYear()
                            && cm === today.getMonth() && cd === today.getDate()
                        let mark = holidayMap[fmtDate(cy, cm + 1, cd)] || ""
                        arr.push({
                            label: cd,
                            inMonth: inMonth,
                            isToday: isToday,
                            mark: mark
                        })
                    }
                    return arr
                }

                function goPrevMonth() {
                    viewMonth--
                    if (viewMonth < 0) { viewMonth = 11; viewYear-- }
                    refreshHoliday(viewYear)
                }

                function goNextMonth() {
                    viewMonth++
                    if (viewMonth > 11) { viewMonth = 0; viewYear++ }
                    refreshHoliday(viewYear)
                }

                Timer {
                    id: closeTimer
                    interval: 350
                    onTriggered: calendarPopup.visible = false
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: closeTimer.stop()
                    onExited: closeTimer.start()
                }

                Rectangle {
                    anchors.fill: parent
                    color: colBg
                    border.color: colMuted
                    border.width: 1
                    radius: 8

                    Column {
                        anchors.fill: parent
                        anchors.topMargin: 6
                        anchors.bottomMargin: 6
                        spacing: 4

                        // 导航栏
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 8

                            Item {
                                width: 24; height: 24
                                Text { text: "◀"; anchors.centerIn: parent; color: colFg
                                    font.pixelSize: 11; font.family: fontName }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: calendarPopup.goPrevMonth() }
                            }

                            Text {
                                text: calendarPopup.viewYear + "年" + (calendarPopup.viewMonth + 1) + "月"
                                color: colFg
                                font.pixelSize: fontSize
                                font.family: fontName
                                font.bold: true
                                width: 90
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Item {
                                width: 24; height: 24
                                Text { text: "▶"; anchors.centerIn: parent; color: colFg
                                    font.pixelSize: 11; font.family: fontName }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: calendarPopup.goNextMonth() }
                            }
                        }

                        // 星期表头
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            Repeater {
                                model: ["日", "一", "二", "三", "四", "五", "六"]
                                Text {
                                    width: 36; height: 20
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    text: modelData
                                    color: colMuted
                                    font.pixelSize: fontSize - 2
                                    font.family: fontName
                                }
                            }
                        }

                        // 日期网格
                        Grid {
                            anchors.horizontalCenter: parent.horizontalCenter
                            columns: 7
                            spacing: 1
                            Repeater {
                                model: calendarPopup.gridModel
                                delegate: Rectangle {
                                    width: 36; height: 26
                                    radius: 13
                                    color: modelData.isToday ? colActive : "transparent"

                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 0
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: modelData.label
                                            color: modelData.isToday ? colBg
                                                 : modelData.inMonth ? colFg : colMuted
                                            font.pixelSize: fontSize - 1
                                            font.family: fontName
                                            font.bold: modelData.isToday
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: modelData.mark === "off" ? "假"
                                                : modelData.mark === "work" ? "班" : ""
                                            color: modelData.mark === "off" ? colGreen
                                                 : modelData.mark === "work" ? colYellow : "transparent"
                                            font.pixelSize: fontSize - 5
                                            font.family: fontName
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
