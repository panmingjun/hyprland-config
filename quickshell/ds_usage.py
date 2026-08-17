#!/usr/bin/env python3
import json
import os
import sqlite3
import urllib.request
from datetime import datetime

API = "https://api.deepseek.com/user/balance"
DATA_DIR = os.path.expanduser("~/.local/share/deepseek")
DB = os.path.join(DATA_DIR, "usage.db")

KEY = os.environ.get("DEEPSEEK_KEY", "").strip()


def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(DB)
    con.execute(
        """CREATE TABLE IF NOT EXISTS usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            balance REAL NOT NULL,
            delta REAL NOT NULL
        )"""
    )
    return con


def fetch_balance():
    req = urllib.request.Request(
        API,
        headers={"Authorization": "Bearer " + KEY, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode())
    infos = data.get("balance_infos", [])
    if not infos:
        raise ValueError("balance_infos empty")
    return float(infos[0]["total_balance"])


def main():
    if not KEY:
        print("未配置deepseek密钥")
        return

    try:
        total = fetch_balance()
    except Exception:
        print("余额获取失败")
        return

    today = datetime.now().strftime("%Y-%m-%d")
    con = init_db()
    try:
        row = con.execute("SELECT balance FROM usage_log ORDER BY id DESC LIMIT 1").fetchone()
        prev = row[0] if row else None
        delta = 0.0 if prev is None else round(total - prev, 4)
        con.execute(
            "INSERT INTO usage_log (date, balance, delta) VALUES (?, ?, ?)",
            (today, total, delta),
        )
        cost = con.execute(
            "SELECT SUM(delta) FROM usage_log WHERE date = ? AND delta < 0",
            (today,),
        ).fetchone()[0] or 0
        con.commit()
    finally:
        con.close()

    cost_today = max(0.0, -cost)
    print("DS ¥{:.2f} | 今日 ¥{:.2f}".format(total, cost_today))


if __name__ == "__main__":
    main()
