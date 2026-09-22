#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MiMo TokenPlan 用量查询（quickshell bar 显示用，仅标准库）。

输出一行文本，由 shell.qml 的 mimoProc 接收显示：
  已登录:  MIMO 月剩 64.8% | 3.52亿/5.00亿
  未登录:  MIMO 未登录
  已失效:  MIMO 登录失效
  出错:    MIMO 查询失败

cookie 来自登录脚本 mimo_token_balance.py 保存的 ~/.mimo-token-balance/state.json。
"""
import json
import os
import urllib.error
import urllib.request

API = "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
DATA_DIR = os.path.expanduser("~/.mimo-token-balance")
STATE = os.path.join(DATA_DIR, "state.json")
CACHE = os.path.join(DATA_DIR, "last_usage.json")


def load_cookies():
    """只取平台域 cookie。"""
    try:
        with open(STATE, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        return {}
    cookies = {}
    for c in state.get("cookies", []):
        domain = c.get("domain", "").lstrip(".")
        if domain == "xiaomimimo.com" or domain.endswith(".xiaomimimo.com"):
            cookies[c["name"]] = c.get("value", "")
    return cookies


def fetch(cookies):
    """返回 (status, payload)。"""
    req = urllib.request.Request(
        API,
        headers={
            "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items()),
            "Accept": "application/json, text/plain, */*",
            "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                           "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"),
            "Referer": "https://platform.xiaomimimo.com/",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace") if e.fp else ""
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, None
    except Exception:
        return 0, None


def unwrap(payload):
    """平台响应可能包一层 {code, message, data}。"""
    if isinstance(payload, dict) and isinstance(payload.get("data"), (dict, list)):
        return payload["data"]
    return payload


def pick_item(body):
    """从 usage.items 里挑主额度项（排除补偿积分，取有 limit 的第一项）。

    返回 (主项 or None, usage dict or None)。
    """
    usage = body.get("usage") if isinstance(body, dict) else None
    usage = usage if isinstance(usage, dict) else None
    items = usage.get("items") if usage else None
    if items is None and isinstance(body, dict):
        items = body.get("items")
    if not isinstance(items, list):
        return None, usage
    picked = None
    for it in items:
        if not isinstance(it, dict):
            continue
        limit = it.get("limit")
        if not isinstance(limit, (int, float)) or limit <= 0:
            continue
        if it.get("name") == "compensation_total_token":
            picked = picked or it      # 只有补偿积分时兜底用
            continue
        return it, usage
    return picked, usage


def to_percent(value):
    """0~1 的比例转 0~100 的百分数；>1 视为已经是百分数。"""
    if not isinstance(value, (int, float)):
        return None
    if 0 <= value <= 1:
        return value * 100.0
    return value


def yi(value):
    """数字转"亿"为单位的文本。"""
    try:
        x = float(value) / 1e8
    except (TypeError, ValueError):
        return "—"
    if x >= 0.01:
        return f"{x:.2f}亿"
    if x > 0:
        return f"{x:.4f}亿"
    return "0.00亿"


def build_line(body):
    """构造 MIMO 月剩 xx% | used/limit。"""
    item, usage = pick_item(body)
    used_pct = None
    used_txt = limit_txt = None

    if item:
        used_pct = to_percent(item.get("percent"))
        if used_pct is None:
            u, l = item.get("used"), item.get("limit")
            if isinstance(u, (int, float)) and isinstance(l, (int, float)) and l > 0:
                used_pct = u / l * 100.0
        if isinstance(item.get("used"), (int, float)) \
                and isinstance(item.get("limit"), (int, float)):
            used_txt, limit_txt = yi(item["used"]), yi(item["limit"])

    if used_pct is None and isinstance(usage, dict):
        used_pct = to_percent(usage.get("percent"))

    parts = []
    if used_pct is not None:
        remain = min(100.0, max(0.0, 100.0 - used_pct))
        parts.append(f"月剩 {remain:.1f}%")
    if used_txt and limit_txt:
        parts.append(f"{used_txt}/{limit_txt}")
    if not parts:
        return None
    return "MIMO " + " | ".join(parts)


def main():
    cookies = load_cookies()
    if not cookies:
        print("MIMO 未登录")
        return

    status, payload = fetch(cookies)
    if status in (401, 403):
        print("MIMO 登录失效")
        return
    if status != 200 or payload is None:
        print("MIMO 查询失败")
        return

    # 缓存原始响应，便于后续按真实结构精调解析
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(CACHE, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.chmod(CACHE, 0o600)
    except OSError:
        pass

    line = build_line(unwrap(payload))
    if not line:
        # 结构未知时兜底：显示原始 JSON 片段，便于发现问题
        raw = json.dumps(payload, ensure_ascii=False)
        print(("MIMO " + raw[:60]) if raw else "MIMO 查询失败")
        return
    print(line)


if __name__ == "__main__":
    main()
