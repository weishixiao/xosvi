#!/bin/sh
# ---------------------------------------------------------------------------
# rootd —— root 命令执行守护进程（供 Xosvi `root` 工具使用）
#
# 协议（与 Sources/XosviMCP/RootdTool.swift 严格对齐）：
#   <dir>/.cmd      工具写入待执行脚本（原子 rename 进来）
#   <dir>/.out      执行结果（stdout + stderr）
#   <dir>/.status   IDLE / RUNNING / DONE rc=N / DISABLED
#   <dir>/.alive    心跳，内容 "<epoch> <pid>"
#   <dir>/.rootd.pid  以及 <dir>/rootd.pid（两种命名都写，兼容不同版本工具）
#
# v1.4.0 —— 解决真机「launchd 反复拉起又 SIGKILL」：
#
#   真机日志证据：forks=143、last terminating signal = Killed: 9、launchd.err 为空。
#   这不是签名问题，是 **launchd 的 forks 配额被耗尽**：
#   旧脚本每秒 fork 5~6 次（date / tail / mv / cat / sleep 全是外部命令），
#   默认 forks 上限很快打满 → 内核直接 SIGKILL，日志里连一行都来不及写。
#
#   本版做法：
#     · 主循环不再 sleep 轮询，改为 **阻塞 read 在一个 fifo 上**：
#       有命令时工具往 fifo 写一个字节 → 立即唤醒；没命令时进程完全睡眠、零 fork。
#     · 心跳/超时兜底用一个**低频**的后台计时器（每 HEARTBEAT_EVERY 秒写一次），
#       而不是每轮循环都 fork date。
#     · 循环体内只用 shell 内建（test / echo / mv 走内建或极低频）。
# ---------------------------------------------------------------------------

HEARTBEAT_EVERY=10     # 心跳间隔（秒）；RootdTool 的 shared 判据是 15 秒内
WAKE_NAME=.wake        # fifo 名（每个目录一个）

# --- 解释器（rootless 的 dash 在 jbroot 内，路径每次装包都会变）-------------
INTERP=""
for c in "$ROOTD_INTERP" /var/jb/usr/bin/dash /usr/bin/dash /var/jb/bin/sh /bin/sh; do
	[ -n "$c" ] && [ -x "$c" ] && { INTERP="$c"; break; }
done
[ -z "$INTERP" ] && INTERP=/bin/sh

# --- 候选目录：必须与 RootdTool.candidateDirs 一致 --------------------------
DIRS=""
add_dir() {
	for _d in $DIRS; do [ "$_d" = "$1" ] && return 0; done
	DIRS="$DIRS $1"
}
add_dir "$ROOTD_PRIMARY_DIR"
for d in $ROOTD_EXTRA_DIRS; do add_dir "$d"; done
add_dir /var/mobile/Documents/wiki.qaq.xosvi/Rootd
add_dir /var/mobile/Library/Rootd

LIVE=""
for d in $DIRS; do
	[ -d "$d" ] && LIVE="$LIVE $d"
done
if [ -z "$LIVE" ]; then
	mkdir -p /var/mobile/Documents/wiki.qaq.xosvi/Rootd 2>/dev/null && LIVE=" /var/mobile/Documents/wiki.qaq.xosvi/Rootd"
fi
[ -z "$LIVE" ] && exit 1

# 目录必须让 mobile 能写：1777 + sticky
for d in $LIVE; do chmod 1777 "$d" 2>/dev/null; done

PRIMARY=""
for d in $LIVE; do PRIMARY="$d"; break; done
LOG="$PRIMARY/.rootd.log"

# --- 单实例检查（必须在写 pid 之前）-----------------------------------------
ME=$$
for d in $LIVE; do
	OLD=$(cat "$d/.rootd.pid" 2>/dev/null)
	if [ -n "$OLD" ] && [ "$OLD" != "$ME" ] && kill -0 "$OLD" 2>/dev/null; then
		echo "rootd already running pid=$OLD" >&2
		exit 0
	fi
done

# 日志轮转只做一次（不要放进循环，那是 fork 大户）
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
	tail -n 300 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

# --- 建 fifo 并写 pid -------------------------------------------------------
WAKE=""
for d in $LIVE; do
	[ -p "$d/$WAKE_NAME" ] || mkfifo "$d/$WAKE_NAME" 2>/dev/null
	chmod 666 "$d/$WAKE_NAME" 2>/dev/null
	echo "$ME" >"$d/.rootd.pid" 2>/dev/null
	echo "$ME" >"$d/rootd.pid" 2>/dev/null
	echo "IDLE" >"$d/.status" 2>/dev/null
done
WAKE="$PRIMARY/$WAKE_NAME"

echo "rootd started pid=$ME uid=$(id -u) interp=$INTERP dirs=$LIVE" >>"$LOG" 2>/dev/null

# --- 心跳/兜底计时器（低频，独立子进程）------------------------------------
# 作用：① 每 HEARTBEAT_EVERY 秒写 .alive；② 每轮也检查一遍 .cmd，
# 万一 fifo 通知丢失（工具直接写文件而不写 fifo）也能被执行。
# 它是**唯一**的高频外部命令来源，且频率是每 10 秒一次，不是每秒。
(
	while :; do
		sleep "$HEARTBEAT_EVERY"
		TS=$(date +%s 2>/dev/null)
		for d in $LIVE; do
			printf '%s %s\n' "${TS:-0}" "$ME" >"$d/.alive" 2>/dev/null
		done
		# 唤醒主循环去扫一遍（fifo 写失败也不影响）
		printf 'h' >"$WAKE" 2>/dev/null
	done
) &
HB=$!

# 退出时清理
cleanup() {
	kill "$HB" 2>/dev/null
	for d in $LIVE; do
		rm -f "$d/.rootd.pid" "$d/rootd.pid" 2>/dev/null
	done
	exit 0
}
trap cleanup INT TERM HUP

# 先写一次心跳，避免启动后 10 秒内被判定为「不共享」
TS=$(date +%s 2>/dev/null)
for d in $LIVE; do printf '%s %s\n' "${TS:-0}" "$ME" >"$d/.alive" 2>/dev/null; done

# --- 主循环：阻塞 read，零轮询 ---------------------------------------------
exec 9<>"$WAKE"

while :; do
	# 阻塞等待：没命令时完全睡眠，不 fork
	read -u 9 _junk 2>/dev/null

	for d in $LIVE; do
		if [ -f "$d/disabled" ]; then
			echo "DISABLED" >"$d/.status" 2>/dev/null
			continue
		fi
		[ -f "$d/.cmd" ] || continue

		echo "RUNNING" >"$d/.status" 2>/dev/null
		# 取走再执行，避免执行期间被新命令覆盖
		mv "$d/.cmd" "$d/.cmd.run" 2>/dev/null || continue

		"$INTERP" "$d/.cmd.run" >"$d/.out" 2>&1
		RC=$?
		echo "DONE rc=$RC" >"$d/.status" 2>/dev/null
		rm -f "$d/.cmd.run" 2>/dev/null
		printf '%s rc=%s\n' "$(date '+%F %T')" "$RC" >>"$LOG" 2>/dev/null
	done
done
