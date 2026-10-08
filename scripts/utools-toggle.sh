#!/usr/bin/env bash
# uTools 唤起/关闭（Wayland 下 uTools 自身的 Alt+U 全局快捷键失效，由 Hyprland 代为采集）
#
# 原理：uTools(Electron/XWayland) 的 XGrabKey 抓取仍然存活，只是 XWayland 只在
# 自己窗口有焦点时才收得到按键。这里用 XTEST 往 XWayland X server 注入合成
# Alt+U，命中 uTools 自己的抓取，由 uTools 原生逻辑完成显示/隐藏。
# XTEST 注入不经过 Hyprland 的 bind 系统，不会造成死循环。
set -u

# 定位当前用户的 XWayland display（X0 属 root，X1 属用户）
x_display() {
    local sock
    for sock in /tmp/.X11-unix/X*; do
        [ -O "$sock" ] && { echo ":${sock##*/X}"; return; }
    done
    echo ":1"
}

DISPLAY=$(x_display) xdotool key --clearmodifiers alt+u
