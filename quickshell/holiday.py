#!/usr/bin/env python3
import json
import os
import sys
import urllib.request

DOMAINS = [
    "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json",
    "https://fastly.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json",
]
DATA_DIR = os.path.expanduser("~/.local/share/holiday-cn")


def cache_path(year):
    return os.path.join(DATA_DIR, "{}.json".format(year))


def read_cache(year):
    path = cache_path(year)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def write_cache(year, data):
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(cache_path(year), "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
    except Exception:
        pass


def fetch(year):
    for url_template in DOMAINS:
        url = url_template.format(year=year)
        try:
            req = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                return json.loads(resp.read().decode())
        except Exception:
            continue
    return None


def main():
    year = sys.argv[1] if len(sys.argv) > 1 else ""
    if not year.isdigit():
        print("{}")
        return

    data = read_cache(year)
    if data is None:
        data = fetch(year)
        if data is None:
            print("{}")
            return
        write_cache(year, data)

    result = {}
    for day in data.get("days", []) or []:
        date = day.get("date")
        if not date:
            continue
        result[date] = "off" if day.get("isOffDay") else "work"
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
