#!/bin/sh
# Xosvi 运行期日志桥：launchd 托管，持续把三层日志追加到 timeline.log
# 全部路径为真实根视图（/rootfs 前缀），因为 launchd 与 icli 都按真实根看路径。
set -u

# launchd 会注入 XPC_SERVICE_NAME 等变量，可能导致 icli 行为异常；用一个干净环境自重启一次。
if [ -n "${XOSVI_WATCH_CLEAN:-}" ]; then :; else
  JB=$(ls -d /rootfs/private/var/containers/Bundle/Application/.jbroot-* 2>/dev/null | head -1)
  [ -n "${JB:-}" ] || { echo "no roothide bootstrap found under /rootfs" >&2; exit 1; }
  exec env -i PATH="$JB/usr/bin:$JB/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
       XOSVI_WATCH_CLEAN=1 "$JB/usr/bin/sh" "$0"
fi
W=/rootfs/private/var/mobile/Library/XosviWatch
D=/rootfs/private/var/mobile/Containers/Data/Application/ED5E0D3D-E92C-48E4-BE7E-3557EA3989CA
TOOL=$D/Documents/audit/tool_log.jsonl
USAGE=$D/Documents/xosvi_usage.jsonl
XLOG=$(ls -d /rootfs/private/var/containers/Bundle/Application/.jbroot-*/var/log/xosvid.log 2>/dev/null | head -1)
# 不写死 .jbroot-<hash>：roothide 每次重启都可能改名，写死就指向不存在的文件。
# 探测不到就让这一节的日志为空，循环照跑（其它三路日志仍然工作）。
[ -n "${XLOG:-}" ] || echo "warning: xosvid.log not found, section 4 stays empty" >&2
CRASHDIR=/rootfs/private/var/mobile/Library/Logs/CrashReporter
OUT=$W/timeline.log

mkdir -p "$W"
prev_tool=0; prev_usage=0; prev_xlog=0; prev_pid=""
: > "$W/crashes.seen"

while :; do
  ts=$(date '+%H:%M:%S')

  # 1) Xosvi 进程与 pid
  # 僵尸任务在 icli 的进程表里只剩 executable + pid，没有 name 行；只有三行齐全才算活跃进程。
  pid=$(icli proc list 2>/dev/null | awk '
    /"executable"/ { exe = $0; hasName = 0; next }
    /"name"/       { hasName = 1; next }
    /"pid"/        { if (hasName && exe ~ /Xosvi\.app\\\/Xosvi"/) {
                       v = $0; gsub(/[^0-9]/, "", v); print v; exit
                     }
                     exe = ""; hasName = 0
                   }')
  if [ -z "${pid:-}" ] && [ -n "${prev_pid:-}" ]; then
    printf '%s ZOMBIE_OR_GONE pid=%s\n' "$ts" "$prev_pid" >> "$OUT"
    prev_pid=""
  fi
  if [ "${pid:-}" != "${prev_pid:-}" ]; then
    printf '%s PID_CHANGE %s -> %s\n' "$ts" "${prev_pid:-none}" "${pid:-none}" >> "$OUT"
    prev_pid="${pid:-}"
  fi

  # 2) 工具审计日志增量
  t=$(wc -c < "$TOOL" 2>/dev/null || echo 0)
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  if [ "$t" -gt "$prev_tool" ]; then
    { printf '=== %s TOOL_APPEND +%s\n' "$ts" "$((t-prev_tool))"; tail -c "$(( t - prev_tool ))" "$TOOL"; } >> "$OUT"
    prev_tool=$t
  elif [ "$t" -lt "$prev_tool" ]; then
    printf '=== %s TOOL_TRUNCATED %s->%s (被重写/轮转)\n' "$ts" "$prev_tool" "$t" >> "$OUT"
    prev_tool=$t
  fi

  # 3) 用量日志增量
  u=$(wc -c < "$USAGE" 2>/dev/null || echo 0)
  case "$u" in ''|*[!0-9]*) u=0 ;; esac
  if [ "$u" -gt "$prev_usage" ]; then
    { printf '=== %s USAGE_APPEND +%s\n' "$ts" "$((u-prev_usage))"; tail -c "$(( u - prev_usage ))" "$USAGE"; } >> "$OUT"
    prev_usage=$u
  fi

  # 4) xosvid 日志增量
  x=$(wc -c < "$XLOG" 2>/dev/null || echo 0)
  case "$x" in ''|*[!0-9]*) x=0 ;; esac
  if [ "$x" -gt "$prev_xlog" ]; then
    { printf '=== %s XOSVID_APPEND +%s\n' "$ts" "$((x-prev_xlog))"; tail -c "$(( x - prev_xlog ))" "$XLOG"; } >> "$OUT"
    prev_xlog=$x
  elif [ "$x" -lt "$prev_xlog" ]; then
    prev_xlog=0
  fi

  # 5) 新崩溃报告（只比较文件名，不读内容：.ips 需要 root 才可读）
  ls -1 "$CRASHDIR" 2>/dev/null | grep -i xosvi > "$W/crashes.now"
  if [ -s "$W/crashes.now" ]; then
    while read -r base; do
      [ -n "$base" ] || continue
      if ! grep -qxF "$base" "$W/crashes.seen" 2>/dev/null; then
        printf '%s NEW_CRASH %s\n' "$ts" "$base" >> "$OUT"
        echo "$base" >> "$W/crashes.seen"
      fi
    done < "$W/crashes.now"
  fi

  sleep 2
done
