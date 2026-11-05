#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导出 / 校验 Xosvi 工具注册表快照。

  python3 scripts/dump_registry.py                                  # 打印 JSON
  python3 scripts/dump_registry.py --out docs/registry.snapshot.json
  python3 scripts/dump_registry.py --check docs/registry.snapshot.json   # CI 用

快照内容：{"count": N, "names": [...], "tools": {name: {category, verified, ...}}}
（稳定输出，便于 diff）。
--check 模式：快照不一致时列出 added/removed 并退出 1。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEF_START_RE = re.compile(r"ToolDefinition\s*\(")
NAME_RE = re.compile(r"name\s*:\s*\"([^\"]+)\"")
CATEGORY_RE = re.compile(r"category\s*:\s*\"([^\"]+)\"")
NAME_LIMIT = 600
BLOCK_LIMIT = 8000
CLOSE_RE = re.compile(r"^[ \t]*\)", re.MULTILINE)   # ToolDefinition( 参数串的收尾行

# v0.2.5：只统计**真正注册**的工具。旧实现扫全仓库每一个 ToolDefinition(，把已合并进
# 大工具、却仍保留类定义的遗留工具也算进去，快照记着 164 个「工具」而运行期只有 51 个：
#   * 快照校验守的是一个错误基线，删死代码反而 CI 报不一致；
#   * AI/文档读快照会以为那些名字可以调用（幽灵工具）。
# 现在：先收集 register(XxxTool()) 的类名，只取这些类（及其外层类）里的 ToolDefinition。
# 注意类头正则里的 \s 不能跨行，否则会把上一行内容一起吞掉导致游标错位。
REGISTER_CLASS_RE = re.compile(r"\bregister\s*\(\s*([A-Za-z_]\w*)\s*\(\s*\)")
CLASS_START_RE = re.compile(
    r"(?:^|\n)[ \t]*(?:public[ \t]+|final[ \t]+|open[ \t]+)*(?:class|struct)[ \t]+([A-Za-z_]\w*)[ \t]*[:{<]")


def parse_args(argv):
    p = argparse.ArgumentParser(description="Xosvi registry snapshot tool")
    p.add_argument("--src", default="Sources/XosviMCP")
    p.add_argument("--out", default=None, help="写入快照文件（不存在则创建父目录）")
    p.add_argument("--check", default=None, help="与快照文件比对，不一致退出 1")
    return p.parse_args(argv)


def resolve_src(raw: str) -> Path:
    p = Path(raw)
    if not p.is_absolute():
        p = (REPO_ROOT / p).resolve()
    if not p.exists():
        print(f"[FATAL] 源码目录不存在: {p}")
        sys.exit(2)
    return p


def collect_registered_classes(src: Path) -> set[str]:
    """所有 register(Xxx()) 里出现的类型名（跨文件；只认无参构造）。"""
    names: set[str] = set()
    for f in sorted(src.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        names.update(REGISTER_CLASS_RE.findall(text))
    return names


def owning_classes(text: str) -> list[tuple[int, str]]:
    """[(位置, 类名)]，按出现顺序 —— 供单遍游标查找所属类。"""
    return [(m.start(), m.group(1)) for m in CLASS_START_RE.finditer(text)]


def collect_tools(src: Path) -> dict[str, dict]:
    tools: dict[str, dict] = {}
    registered = collect_registered_classes(src)
    for f in sorted(src.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        starts = [m.start() for m in DEF_START_RE.finditer(text)]
        owners = owning_classes(text)
        oi, owner = 0, ""
        for i, s in enumerate(starts):
            e = starts[i + 1] if i + 1 < len(starts) else len(text)
            block = text[s:e]
            while oi < len(owners) and owners[oi][0] < s:
                owner = owners[oi][1]
                oi += 1
            if owner not in registered:
                continue          # 未注册的工具类：不进快照（运行期不可调用）
            m = NAME_RE.search(block[:NAME_LIMIT])
            if not m:
                continue
            name = m.group(1)
            # 只取 ToolDefinition 的参数串（到收尾的 ")" 行为止）：长 summary 会超过
            # BLOCK_LIMIT，整块截断会把末尾的 verified/category 一起切掉。
            close = CLOSE_RE.search(block)
            head = block[: close.start() if close else BLOCK_LIMIT]
            meta: dict = {
                "file": f.name,
                "category": (CATEGORY_RE.search(head).group(1) if CATEGORY_RE.search(head) else ""),
                "verified": bool(re.search(r"verified\s*:\s*true", head)),
                "requires_jailbreak": bool(re.search(r"requiresJailbreak\s*:\s*true", head)),
                "requires_trollstore": bool(re.search(r"requiresTrollStore\s*:\s*true", head)),
                "remote_only": bool(re.search(r"remoteOnly\s*:\s*true", head)),
            }
            # 同名冲突：保留第一个，并在报告里可见
            if name in tools:
                meta["duplicate_of"] = tools[name]["file"]
            tools[name] = meta
    return tools


def main(argv=None) -> int:
    args = parse_args(argv)
    src = resolve_src(args.src)
    tools = collect_tools(src)
    names = sorted(tools)
    payload = {
        "count": len(names),
        "names": names,
        "tools": {n: tools[n] for n in names},
    }
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)

    if args.out:
        out = Path(args.out)
        if not out.is_absolute():
            out = REPO_ROOT / out
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text + "\n", encoding="utf-8")
        print(f"snapshot written: {out} ({len(names)} tools)")
        return 0

    if args.check:
        snap = Path(args.check)
        if not snap.is_absolute():
            snap = REPO_ROOT / snap
        if not snap.exists():
            print(f"::warning:: 快照文件不存在: {snap}（先运行 --out 生成并提交）")
            return 0
        old = json.loads(snap.read_text(encoding="utf-8"))
        old_names = set(old.get("names", []))
        new_names = set(names)
        added = sorted(new_names - old_names)
        removed = sorted(old_names - new_names)
        if not added and not removed:
            print(f"snapshot OK ({len(names)} tools)")
            return 0
        print("[ERROR] 工具注册表与快照不一致：")
        for n in added:
            print(f"  + {n}")
        for n in removed:
            print(f"  - {n}")
        print("若为有意变更：运行 --out 更新快照并提交（破坏性变更请在 PR 说明里标注）。")
        return 1

    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
