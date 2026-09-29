#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
查询 Xiaomi MiMo 开放平台 TokenPlan 余额
https://platform.xiaomimimo.com/api/v1/tokenPlan/usage

流程：
  1. 优先读取本地保存的 cookie 直接请求 API；
  2. cookie 缺失或失效时，用 Playwright 打开小米账号登录页：
     启动后输入手机号 -> 进入验证码登录页并触发发送验证码
     -> 终端输入短信验证码 -> 登录成功后保存 cookie -> 查询余额。
  登录提交验证码后，浏览器窗口不会立刻关闭：
  页面可能先进入确认页面（需等待约 5 秒），脚本会先等 5 秒，
  然后每 2 秒实测 API，直到真正拿到 token（HTTP 200）才保存并关窗，
  最长等待 120 秒。

依赖安装（任选一种）：
  方式 A（venv，推荐，不污染系统）：
    python3 -m venv ~/.venvs/mimo
    ~/.venvs/mimo/bin/pip install requests playwright
    ~/.venvs/mimo/bin/playwright install chromium
    ~/.venvs/mimo/bin/python mimo_token_balance.py
  方式 B（装到用户目录）：
    pip install --user --break-system-packages requests playwright
    python3 -m playwright install chromium
    python3 mimo_token_balance.py

运行：
  python3 mimo_token_balance.py                # 交互式输入手机号
  python3 mimo_token_balance.py --phone 138xxxx1234
  python3 mimo_token_balance.py --relogin      # 强制重新登录
  python3 mimo_token_balance.py --headless     # 无界面模式（不推荐，易触发风控）

登录态保存在 ~/.mimo-token-balance/（家目录隐藏目录，权限 600）：
  state.json  登录 cookie（quickshell 的 mimo_usage.py 也读它）
  phone       上次登录的手机号（下次登录可直接回车复用）
cookie 失效后再次运行会自动重新走登录流程。
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from urllib.parse import quote

API_URL = "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
ORIGIN = "https://platform.xiaomimimo.com"
# cookie 与手机号都保存在家目录隐藏文件里（quickshell 集成共用）
DATA_DIR = Path.home() / ".mimo-token-balance"
STATE_FILE = DATA_DIR / "state.json"        # playwright storage_state（cookie）
PHONE_FILE = DATA_DIR / "phone"             # 上次登录使用的手机号
SCREENSHOT_FILE = DATA_DIR / "fail.png"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")

# 登录后等待 token 的节奏：首测前先等 5 秒（覆盖确认页面场景），
# 之后轮询，总上限 120 秒
LOGIN_GRACE_MS = 5000
LOGIN_POLL_MS = 2000
LOGIN_WAIT_TIMEOUT_MS = 120000

# 401 响应里会返回 loginUrl；这里是它的静态兜底构造
DEFAULT_LOGIN_URL = (
    "https://account.xiaomi.com/pass/serviceLogin?callback="
    + quote(f"{ORIGIN}/sts?sign=&followup={API_URL}", safe="")
    + "&sid=api-platform&_group=DEFAULT"
)


# ---------------------------------------------------------------- cookie 存取

def load_state() -> dict:
    """读取 playwright storage_state 格式的登录态。"""
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2),
                          encoding="utf-8")
    STATE_FILE.chmod(0o600)


def read_phone() -> str:
    try:
        return PHONE_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def save_phone(phone: str) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    PHONE_FILE.write_text(phone.strip(), encoding="utf-8")
    PHONE_FILE.chmod(0o600)


def state_to_cookies(state: dict) -> dict:
    """只取平台域的 cookie（storage_state 里还可能混有 account.xiaomi.com）。"""
    cookies = {}
    for c in state.get("cookies", []):
        domain = c.get("domain", "").lstrip(".")
        if domain == "xiaomimimo.com" or domain.endswith(".xiaomimimo.com"):
            cookies[c["name"]] = c.get("value", "")
    return cookies


# ---------------------------------------------------------------- API 请求

def build_session(cookies: dict):
    import requests

    session = requests.Session()
    session.cookies.update(cookies)
    session.headers.update({
        "User-Agent": UA,
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Referer": f"{ORIGIN}/",
        "x-timeZone": "Asia/Shanghai",
    })
    return session


def fetch_usage(session):
    """返回 (成功?, HTTP状态码, 解析后的JSON或None)。"""
    try:
        resp = session.get(API_URL, timeout=20)
    except Exception as exc:  # 网络错误
        print(f"[错误] 请求失败: {exc}", file=sys.stderr)
        return False, 0, None
    try:
        payload = resp.json()
    except ValueError:
        payload = None
    ok = resp.status_code == 200 and isinstance(payload, dict) \
        and payload.get("code") in (0, 200, None)
    return ok, resp.status_code, payload


def get_login_url(session=None) -> str:
    """请求 API，从 401 响应中取最新的登录地址（sign 是动态的）。"""
    try:
        import requests
        s = session or requests.Session()
        s.headers.update({"User-Agent": UA})
        resp = s.get(API_URL, timeout=20)
        if resp.status_code == 401:
            data = resp.json()
            if data.get("loginUrl"):
                return data["loginUrl"]
    except Exception:
        pass
    return DEFAULT_LOGIN_URL


# ---------------------------------------------------------------- Playwright 登录

def prompt_phone(cli_phone: str | None) -> str:
    if cli_phone:
        return cli_phone.strip()
    saved = read_phone()
    if not sys.stdin.isatty():
        # 非交互环境（如脚本被后台调用）：优先复用已保存的手机号
        if saved:
            return saved
        print("[错误] 非交互环境下请使用 --phone 指定手机号", file=sys.stderr)
        sys.exit(2)
    hint = f" [{saved}]" if saved else ""
    phone = input(f"请输入手机号{hint}: ").strip() or saved
    if not phone.isdigit() or len(phone) not in (11, 12, 13):
        print("[错误] 手机号格式不正确", file=sys.stderr)
        sys.exit(2)
    return phone


def prompt_code(cli_code: str | None) -> str:
    if cli_code:
        return cli_code.strip()
    code = input("请输入短信验证码: ").strip()
    if not code:
        print("[错误] 验证码不能为空", file=sys.stderr)
        sys.exit(2)
    return code


def _dismiss_cookie_banner(page) -> None:
    try:
        btn = page.locator('button:has-text("同意并关闭提示")')
        if btn.count() and btn.first.is_visible():
            btn.first.click()
            page.wait_for_timeout(300)
    except Exception:
        pass


def _click_confirm_buttons(page) -> None:
    """尝试点击登录后的确认/继续类按钮。

    不依赖具体页面结构，点不到就忽略（纯等待轮询也能跨过确认页面）。
    """
    try:
        confirm = page.locator(
            'button:has-text("确认"), button:has-text("继续"), '
            'button:has-text("同意"), button:has-text("允许"), '
            'button:has-text("下一步")')
        for i in range(min(confirm.count(), 3)):
            btn = confirm.nth(i)
            if btn.is_visible() and btn.is_enabled():
                btn.click()
                print("[登录] 已点击页面确认按钮")
                page.wait_for_timeout(500)
                return
    except Exception:
        pass


def _wait_api_ok(page, context, timeout_ms: int = LOGIN_WAIT_TIMEOUT_MS) -> bool:
    """等待真正拿到 token（API 实测 200）后才允许关闭窗口。

    页面跳到 platform 域后可能先进入确认页面（需等待约 5 秒），
    所以首测前先等 LOGIN_GRACE_MS，之后每 LOGIN_POLL_MS 实测一次 API，
    期间顺带尝试点击确认类按钮；返回 True 才算登录成功。
    """
    print(f"[登录] 等待确认页面/登录态生效（首测前 {LOGIN_GRACE_MS // 1000} 秒"
          f"，最长 {timeout_ms // 1000} 秒）...")
    page.wait_for_timeout(LOGIN_GRACE_MS)
    deadline = time.monotonic() + timeout_ms / 1000
    last_status = 0
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            resp = context.request.get(API_URL, timeout=20000)
            last_status = resp.status
        except Exception:
            last_status = 0
        if last_status == 200:
            print(f"[登录] 登录成功，token 已获取（第 {attempt} 次实测），"
                  "cookie 已保存")
            return True
        print(f"[登录] API 实测 HTTP {last_status}，"
              f"继续等待 ... (剩余约 "
              f"{max(0, int(deadline - time.monotonic()))} 秒)")
        _click_confirm_buttons(page)
        page.wait_for_timeout(LOGIN_POLL_MS)
    print(f"[错误] 等待 token 超时（最后状态 HTTP {last_status}），"
          "现在关闭浏览器窗口", file=sys.stderr)
    return False


def playwright_login(login_url: str, phone: str, code: str | None,
                     headless: bool) -> bool:
    """
    打开小米账号登录页，完成 手机号 -> 验证码 登录，
    成功后把 storage_state 写入 STATE_FILE。返回是否成功。
    浏览器窗口只在拿到 token（API 200）或超时后才关闭。
    """
    try:
        from playwright.sync_api import sync_playwright
        from playwright.sync_api import Error as PWError
        from playwright.sync_api import TimeoutError as PWTimeout
    except ImportError:
        print("[错误] 未安装 playwright，请先执行:", file=sys.stderr)
        print("  pip install --user --break-system-packages playwright", file=sys.stderr)
        print("  python3 -m playwright install chromium", file=sys.stderr)
        sys.exit(3)

    print(f"[登录] 打开登录页 (headless={headless}) ...")
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        context = browser.new_context(
            locale="zh-CN",
            viewport={"width": 1280, "height": 900},
            user_agent=UA,
        )
        page = context.new_page()
        try:
            _run_login_flow(page, context, login_url, phone,
                            code, PWTimeout, PWError)
            return True
        except Exception as exc:
            print(f"[登录] 自动流程中断: {exc}", file=sys.stderr)
            return _wait_manual_login(page, context, PWTimeout)
        finally:
            try:
                context.storage_state(path=str(STATE_FILE))
            except Exception:
                pass
            browser.close()


def _run_login_flow(page, context, login_url, phone, code, PWTimeout, PWError) -> None:
    page.goto(login_url, wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(2500)
    _dismiss_cookie_banner(page)

    # 1) 切换到手机号登录（默认是"账号+密码"页）
    if "/login/phone" not in page.url:
        link = page.locator('a:has-text("手机号登录")')
        if link.count() == 0:
            raise RuntimeError('页面上没找到"手机号登录"入口')
        link.first.click()
    page.wait_for_selector('input[name="phone"]', timeout=20000)
    print("[登录] 已进入手机号登录页")

    # 2) 填手机号 + 勾选协议 + 下一步
    page.locator('input[name="phone"]').fill(phone)
    checkbox = page.locator('input[type="checkbox"]')
    for i in range(checkbox.count()):
        try:
            if not checkbox.nth(i).is_checked():
                checkbox.nth(i).check()
        except Exception:
            pass
    next_btn = page.locator('button:has-text("下一步")')
    if next_btn.count() == 0:
        raise RuntimeError('没找到"下一步"按钮')
    next_btn.first.click()
    print("[登录] 已提交手机号，等待验证码页 ...")

    # 3) 进入验证码页 (/login/challenge/ticket)
    page.wait_for_selector('input[name="ticket"]', timeout=30000)
    page.wait_for_timeout(1500)

    # 4) 确认验证码已发出；若没有自动发送则点击"获取验证码"
    send_btn = page.locator(
        'button:has-text("获取验证码"), button:has-text("发送验证码")')
    if send_btn.count() and send_btn.first.is_visible():
        try:
            if send_btn.first.is_enabled():
                send_btn.first.click()
                print("[登录] 已点击发送验证码")
        except Exception:
            pass
    else:
        print("[登录] 验证码已自动发送")

    # 5) 输入验证码并提交
    ticket = prompt_code(code)
    page.locator('input[name="ticket"]').fill(ticket)
    submit = page.locator('button[type="submit"]')
    if submit.count() == 0:
        raise RuntimeError('没找到"登录"提交按钮')
    submit.first.click()
    print("[登录] 已提交验证码，等待跳转 "
          "（若弹出滑块/安全验证，请在浏览器窗口中手动完成）...")

    # 6) 等待跳回 platform 域（/sts 回调 -> followup 到 usage API）
    page.wait_for_url(lambda url: "platform.xiaomimimo.com" in url,
                      timeout=60000)

    # 7) 登录后可能先进入确认页面（需等约 5 秒）：
    #    轮询实测 API，真正拿到 token 才算成功，窗口在此之前不关闭
    if not _wait_api_ok(page, context):
        raise RuntimeError("等待 token 超时")


def _wait_manual_login(page, context, PWTimeout) -> bool:
    """自动流程失败时的兜底：允许用户在打开的浏览器窗口里手动完成登录。

    同样遵守"拿到 token 才关窗"：轮询实测 API，最长 120 秒。
    """
    print("[提示] 自动流程失败。你可以在打开的浏览器窗口中手动完成登录，"
          "脚本会等待最多 120 秒 ...", file=sys.stderr)
    try:
        page.screenshot(path=str(SCREENSHOT_FILE), full_page=True)
        print(f"[提示] 失败截图: {SCREENSHOT_FILE}", file=sys.stderr)
    except Exception:
        pass
    try:
        page.wait_for_url(lambda url: "platform.xiaomimimo.com" in url,
                          timeout=120000)
    except PWTimeout:
        print("[错误] 等待登录跳转超时", file=sys.stderr)
        return False
    except Exception as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return False
    if _wait_api_ok(page, context):
        return True
    print("[错误] 未获取到 token，关闭浏览器窗口", file=sys.stderr)
    return False


# ---------------------------------------------------------------- 结果展示

INTERESTING = ("balance", "credit", "remain", "used", "quota", "limit",
               "total", "amount", "expire", "reset", "status", "plan")


def _summarize(obj, path="", lines=None):
    if lines is None:
        lines = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            _summarize(v, f"{path}.{k}" if path else k, lines)
    elif isinstance(obj, list):
        for i, v in enumerate(obj[:20]):
            _summarize(v, f"{path}[{i}]", lines)
    elif isinstance(obj, (int, float, str)) and any(
            kw in path.lower() for kw in INTERESTING):
        lines.append(f"  {path} = {obj}")
    return lines


def print_balance(payload) -> None:
    print("=" * 60)
    print("TokenPlan usage 响应:")
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    lines = _summarize(payload)
    if lines:
        print("-" * 60)
        print("关键字段:")
        for line in lines[:40]:
            print(line)
    print("=" * 60)


# ---------------------------------------------------------------- main

def parse_args():
    ap = argparse.ArgumentParser(
        description="查询 Xiaomi MiMo 开放平台 TokenPlan 余额")
    ap.add_argument("--phone", help="登录手机号（缺省则启动时交互输入）")
    ap.add_argument("--code", help="短信验证码（缺省则登录时交互输入）")
    ap.add_argument("--relogin", action="store_true", help="忽略已保存 cookie，强制重新登录")
    ap.add_argument("--headless", action="store_true",
                    help="无界面运行浏览器（不推荐，易触发风控）")
    ap.add_argument("--json-only", action="store_true",
                    help="只输出原始 JSON，不输出摘要")
    return ap.parse_args()


def main() -> int:
    args = parse_args()

    # 1) 尝试用已有 cookie 查询
    if not args.relogin:
        cookies = state_to_cookies(load_state())
        if cookies:
            ok, status, payload = fetch_usage(build_session(cookies))
            if ok:
                if args.json_only:
                    print(json.dumps(payload, ensure_ascii=False, indent=2))
                else:
                    print_balance(payload)
                return 0
            print(f"[提示] 已保存的 cookie 失效 (HTTP {status})，转为重新登录",
                  file=sys.stderr)
    elif STATE_FILE.exists():
        STATE_FILE.unlink()

    # 2) 需要登录
    phone = prompt_phone(args.phone)
    login_url = get_login_url()
    print(f"[登录] 登录地址: {login_url[:100]}...")
    if not playwright_login(login_url, phone, args.code, args.headless):
        print("[错误] 登录未完成", file=sys.stderr)
        return 1
    save_phone(phone)

    # 3) 用新 cookie 查询
    cookies = state_to_cookies(load_state())
    if not cookies:
        print("[错误] 未保存到平台 cookie", file=sys.stderr)
        return 1
    ok, status, payload = fetch_usage(build_session(cookies))
    if not ok:
        print(f"[错误] 登录后查询仍失败 (HTTP {status}): "
              f"{json.dumps(payload, ensure_ascii=False)[:300]}",
              file=sys.stderr)
        return 1
    if args.json_only:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_balance(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
