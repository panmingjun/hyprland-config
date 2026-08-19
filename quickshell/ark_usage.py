#!/usr/bin/env python3
"""调用 arkcli usage plan 获取火山方舟 Coding Plan 用量，输出单行 JSON 给 quickshell。"""
import json
import shutil
import subprocess
import sys
from datetime import datetime
from typing import NoReturn


def fail(text: str, error: str) -> NoReturn:
    print(json.dumps({"text": text, "detail": None, "error": error}, ensure_ascii=False))
    sys.exit(0)


def to_percent(value) -> float:
    try:
        return round(float(value), 2)
    except (TypeError, ValueError):
        return 0.0


def fmt_reset(iso: str) -> str:
    if not iso:
        return ""
    try:
        dt = datetime.fromisoformat(iso)
        return dt.strftime("%m-%d %H:%M")
    except ValueError:
        return iso


def main() -> None:
    if shutil.which("arkcli") is None:
        fail("Ark 未安装", "not_installed")

    try:
        result = subprocess.run(
            ["arkcli", "usage", "plan", "--format", "json"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        fail("Ark 超时", "timeout")
    except Exception as e:
        fail("Ark 失败", "exec_error:" + str(e)[:60])

    if result.returncode != 0:
        stderr = (result.stderr or "").lower()
        if "auth" in stderr or "login" in stderr or "unauthorized" in stderr:
            fail("Ark 未登录", "unauthorized")
        fail("Ark 获取失败", "cli_error")

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        fail("Ark 解析失败", "bad_json")

    items = data.get("items") or []
    coding = None
    for item in items:
        product = (item.get("product") or "").lower()
        if "coding-plan" in product:
            coding = item
            break

    if coding is None or not coding.get("subscribed"):
        fail("Ark 未订阅", "not_subscribed")

    label_map = {
        "session": "5h",
        "5h": "5h",
        "weekly": "W",
        "monthly": "M",
    }
    order = ["session", "5h", "weekly", "monthly"]
    periods = {p.get("label"): p for p in (coding.get("periods") or [])}

    detail = []
    shorts = []
    for key in order:
        p = periods.get(key)
        if not p:
            continue
        label = label_map.get(key, key)
        pct = to_percent(p.get("percent"))
        shorts.append((label, pct))
        detail.append({
            "label": label,
            "percent": pct,
            "reset": fmt_reset(p.get("reset_at", "")),
        })

    if not shorts:
        fail("Ark 无数据", "no_periods")

    order_sort = {"5h": 0, "W": 1, "M": 2}
    shorts.sort(key=lambda x: order_sort.get(x[0], 9))
    max_pct = max(p for _, p in shorts)

    text = "Ark " + "|".join(f"{p:.0f}%" for _, p in shorts)

    out = {
        "text": text,
        "detail": detail,
        "max": max_pct,
        "error": "",
    }
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
