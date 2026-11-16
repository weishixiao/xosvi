#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L3 并发压测：多会话 × 多轮 tools/call，统计成功率/延迟/错误码。

用法：
  python3 scripts/stress_mcp.py --host 127.0.0.1 --port 8790 --sessions 8 --seconds 60

只看 http 层（不依赖 App 内 UI）。默认打只读工具，避免在真机上产生副作用。
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter

READONLY_CALLS = [
    ("device", {"command": "info"}),
    ("inject", {"command": "status"}),
    ("assistant_memory", {"command": "list"}),
    ("tools.audit", {}),
    ("system.overview", {}),
]


def parse_args(argv):
    p = argparse.ArgumentParser(description="Xosvi MCP concurrency stress")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8790)
    p.add_argument("--token", default="")
    p.add_argument("--sessions", type=int, default=8)
    p.add_argument("--seconds", type=int, default=60)
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--seed", type=int, default=42)
    return p.parse_args(argv)


def rpc(host, port, token, payload, timeout):
    url = f"http://{host}:{port}/"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def worker(idx, args, stop_at, stats, lock, counter):
    rnd = random.Random(args.seed + idx)
    while time.time() < stop_at:
        tool, params = rnd.choice(READONLY_CALLS)
        payload = {"jsonrpc": "2.0", "id": counter[0], "method": "tools/call",
                   "params": {"name": tool, "arguments": params}}
        with lock:
            counter[0] += 1
        t0 = time.time()
        ok = False
        code = "TRANSPORT"
        try:
            resp = rpc(args.host, args.port, args.token, payload, args.timeout)
            if "error" in resp:
                code = str(resp["error"].get("data", {}).get("mcp_code", "RPC_ERROR"))
            else:
                text = resp.get("result", {}).get("content", [{}])[0].get("text", "")
                ok = '"ok":true' in text or '"ok": true' in text
                code = "OK" if ok else "TOOL_FAILED"
        except urllib.error.URLError:
            code = "UNREACHABLE"
        except Exception as e:  # noqa: BLE001
            code = type(e).__name__
        dt = (time.time() - t0) * 1000
        with lock:
            stats["latency"].append(dt)
            stats["codes"][code] += 1
            if ok:
                stats["ok"] += 1
            stats["total"] += 1


def main(argv=None) -> int:
    args = parse_args(argv)
    stop_at = time.time() + args.seconds
    stats = {"latency": [], "codes": Counter(), "ok": 0, "total": 0}
    lock = threading.Lock()
    counter = [1]

    threads = [threading.Thread(target=worker, args=(i, args, stop_at, stats, lock, counter), daemon=True)
               for i in range(args.sessions)]
    print(f"start: sessions={args.sessions} seconds={args.seconds} target={args.host}:{args.port}")
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    total = stats["total"]
    if total == 0:
        print("[FATAL] 没有完成任何请求（服务未启动？）")
        return 2
    lat = sorted(stats["latency"])

    def pct(p):
        return lat[min(len(lat) - 1, int(len(lat) * p / 100))]

    print(f"\nrequests={total} ok={stats['ok']} ({stats['ok']/total*100:.1f}%)")
    print(f"latency ms: avg={statistics.mean(lat):.0f} p50={pct(50):.0f} p95={pct(95):.0f} max={lat[-1]:.0f}")
    print("codes:")
    for code, n in stats["codes"].most_common():
        print(f"  {code:16} {n}")
    return 0 if stats["ok"] / total >= 0.9 else 1


if __name__ == "__main__":
    raise SystemExit(main())
