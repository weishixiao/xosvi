#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PR-A6：修正工具描述里的交叉引用（旧写法 → 规范形式）。

用法：
  python3 scripts/fix_desc_refs.py --src Sources/XosviMCP            # dry-run（默认）
  python3 scripts/fix_desc_refs.py --src Sources/XosviMCP --apply    # 写回文件

规则：
  1) 只做「精确字符串」替换（见 REPLACEMENTS），不做正则联想——避免误伤。
  2) 目标名必须命中注册表（由 dump_registry/lint 校验）。
  3) 改完必须复跑 lint_tool_descriptions.py，L2 引用检查必须清零。

目标形态约定：`大工具` command:子命令（或真实注册名，如 prompt.read_mode / web.fetch）。
"""
from __future__ import annotations

import argparse
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# (文件, 旧片段, 新片段)
REPLACEMENTS: list[tuple[str, str, str]] = [
    # --- rescue / injection ---
    ("RescueTools.swift", "(use rescue.restore_all)", "(use `rescue` command:recover_all)"),
    ("RescueTools.swift", "(use injection.enable)", "(use `inject` command:enable)"),

    # --- app ---
    ("AppInstallTools.swift", "(use apps.open)", "(use `app` command:launch)"),
    ("AppInstallTools.swift", "(use cleanup.execute)", "(use `app` command:cache_clear)"),
    ("AppTools.swift", "(use cleanup.scan/cleanup.execute)", "(use `app` command:cache_inspect / command:cache_clear)"),
    ("AppTools.swift", "(use apps.open)", "(use `app` command:launch)"),
    ("AppDuplicateTool.swift", "(use backup.restore)", "(use `rescue` command:recover_all)"),

    # --- automation（创建任务没有对应工具，只能走 UI）---
    ("AllMCPTools.swift", "(use automation.create)", "(create tasks in the Automation UI; this tool only triggers existing ones)"),

    # --- calendar / reminder ---
    ("AllMCPTools.swift", "(use calendar.list)", "(use `calendar` command:list)"),
    ("MissingTools.swift", "(use calendar.list)", "(use `calendar` command:list)"),
    ("MissingTools.swift", "(use reminder.create)", "(use `reminder` action:create)"),
    ("MissingTools.swift", "(use reminder.schedule)", "(use `reminder` action:schedule)"),

    # --- device ---
    ("AllMCPTools.swift", "(use device.status)", "(use `device` command:info)"),

    # --- memory / artifact ---
    ("AssistantMemoryTools.swift", "(use artifact.write_text)", "(use `artifact` command:write)"),
    ("AssistantMemoryTools.swift", "(use assistant.memory_get)", "(use `assistant_memory` command:list)"),

    # --- location ---
    ("ControlLaunchTools.swift", "(use location.clear)", "(use `location` command:clear)"),

    # --- control ---
    ("ControlTools.swift", "(use control.tap)", "(use `control` command:tap)"),
    ("ControlTools.swift", "(use control.swipe)", "(use `control` command:swipe)"),
    ("ControlTools.swift", "(use control.type)", "(use `control` command:type)"),
    ("ControlTools.swift", "(use control.tap_text)", "(use `control` command:tap_text)"),
    ("ControlTools.swift", "(use control.type_text)", "(use `control` command:type_text)"),
    ("ControlTools.swift", "PREREQUISITE: call control.inject first.",
     "PREREQUISITE: call `control` command:inject first."),

    # --- debug / model / chat ---
    ("DebugConversationsTool.swift", "(use debug.dump_messages)", "(use `debug.dump_conversation`)"),
    ("DebugConversationsTool.swift", "(use chat.send)", "(send messages from the chat UI)"),
    ("DebugConversationsTool.swift", "(use debug.dump_model_configs)", "(use `model` command:list)"),
    ("DebugConversationsTool.swift", "(use model.switch)", "(use `model` command:switch)"),

    # --- workspace / fs / bridge ---
    ("KnowledgeBaseAndCleanup.swift", "(use cleanup.scan/execute)", "(use `app` command:cache_inspect / command:cache_clear)"),
    ("KnowledgeBaseAndCleanup.swift", "(use fs.rm)", "(use `workspace` command:shell with an absolute path)"),
    ("OriginalTools.swift", "(use fs.rm)", "(use `workspace` command:shell with an absolute path)"),
    ("OriginalTools.swift", "(use bridge.ls)", "(use `workspace` command:list_dir)"),

    # --- analysis ---
    ("AdvancedTools.swift", "(use ai.analyze_app)", "(use `subagent` for AI-assisted analysis)"),
    ("AdvancedTools.swift", "(use cleanup.execute)", "(use `app` command:cache_clear)"),
]


def parse_args(argv):
    p = argparse.ArgumentParser(description="Fix stale cross-references in tool descriptions")
    p.add_argument("--src", default="Sources/XosviMCP")
    p.add_argument("--apply", action="store_true", help="写回文件（默认 dry-run）")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    src = Path(args.src)
    if not src.is_absolute():
        src = (REPO_ROOT / src).resolve()
    if not src.exists():
        print(f"[FATAL] 目录不存在: {src}")
        return 2

    changed_files = 0
    changed_refs = 0
    missed = 0
    for fname, old, new in REPLACEMENTS:
        fp = src / fname
        if not fp.exists():
            print(f"[SKIP] 文件不存在: {fp}")
            continue
        text = fp.read_text(encoding="utf-8")
        n = text.count(old)
        if n == 0:
            missed += 1
            print(f"[MISS] {fname}: 未找到 → {old[:70]}")
            continue
        changed_refs += n
        changed_files += 1
        mode = "APPLY" if args.apply else "DRY  "
        print(f"[{mode}] {fname}: {n}x  {old[:52]}  →  {new[:52]}")
        if args.apply:
            fp.write_text(text.replace(old, new), encoding="utf-8")

    print(f"\n{'applied' if args.apply else 'dry-run'}: files={changed_files} refs={changed_refs} missed={missed}")
    if not args.apply:
        print("确认无误后加 --apply 写回；随后复跑 lint_tool_descriptions.py 复核 L2。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
