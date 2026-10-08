#!/usr/bin/env python3
"""直连 uTools 的 Chromium SingletonSocket，发送单实例通知唤起面板。

绕过第二个 Electron 进程的完整冷启动（原 ~1.3s），毫秒级触发主进程的
second-instance 回调（与 `utools` 二次启动走完全相同的代码路径）。

协议（Chromium 108 chrome/browser/process_singleton_posix.cc）:
  1. 读 ~/.config/uTools/SingletonSocket 符号链接得到真实 socket 路径
  2. 校验 socket 同目录的 SingletonCookie 与本目录 SingletonCookie 一致
  3. connect 后发送: b"START\\0<cwd>\\0<argv[0]>\\0..."
  4. shutdown(SHUT_WR)，读回 "ACK" 表示主进程已受理
"""
import os
import socket
import sys

CONF = os.path.expanduser("~/.config/uTools")


def main() -> int:
    sock_link = os.path.join(CONF, "SingletonSocket")
    cookie_link = os.path.join(CONF, "SingletonCookie")

    try:
        sock_path = os.readlink(sock_link)
        local_cookie = os.readlink(cookie_link)
    except OSError as e:
        print(f"utools-notify: 读取单实例链接失败（uTools 未运行？）: {e}",
              file=sys.stderr)
        return 1

    # 协议要求：连接前后各校验一次远端 cookie（防 socket 目录被替换）
    remote_cookie_path = os.path.join(os.path.dirname(sock_path), "SingletonCookie")

    def check_cookie() -> bool:
        try:
            if os.readlink(remote_cookie_path) != local_cookie:
                print("utools-notify: cookie 校验失败", file=sys.stderr)
                return False
        except OSError as e:
            print(f"utools-notify: 读取远端 cookie 失败: {e}", file=sys.stderr)
            return False
        return True

    if not check_cookie():
        return 1

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(2)
        s.connect(sock_path)
    except OSError as e:
        s.close()
        print(f"utools-notify: 连接失败: {e}", file=sys.stderr)
        return 1

    if not check_cookie():
        s.close()
        return 1

    # "START\0<cwd>\0<argv0>\0..." — argv 至少 1 个元素（共 >=3 个 token）
    msg = b"START\x00" + os.getcwd().encode() + b"\x00" + b"/opt/uTools/utools"
    try:
        s.sendall(msg)
        s.shutdown(socket.SHUT_WR)
        ack = s.recv(16)
    except OSError as e:
        print(f"utools-notify: 通信失败: {e}", file=sys.stderr)
        return 1
    finally:
        s.close()

    if ack == b"ACK":
        return 0
    print(f"utools-notify: 主进程未确认 (收到 {ack!r})", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
