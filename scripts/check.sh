#!/bin/bash
# scripts/check.sh —— Xosvi 静态门禁
#
# 思路取自 Apelin 的 `make check`：设备上踩过的坑要变成**可执行的检查**，
# 而不是留在文档里靠下一次会话记住。这里每一条都对应一次真实事故或一次险些出事：
#
#   1. shell 语法        —— 脚本坏在半路，比不跑更糟
#   2. 递归删除守卫      —— 变量为空时 `rm -rf "$X"` 可能是 /（roothide 下是 bootstrap 根）
#   3. 写死 jbroot 路径  —— roothide 重启后 .jbroot-<hash> 会改名，写死就指向别处或不存在
#   4. launchd 占位符    —— 本机实测 launchd 不认 @PREFIX@/__ROOTFS__，会当相对路径
#   5. 持久化读取回退    —— 一条读不出来的记录不该让下一次保存把它永久清空（提示级）
#
# 用法：bash scripts/check.sh        有 FAIL 时退出码 1
#       bash scripts/check.sh -v     同时打印通过项
# 依赖：bash + awk + find/grep；不需要 python3（设备上没有）。

set -u
cd "$(dirname "$0")/.." || exit 1

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

FAILS=0
NOTES=0
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf 'WARN  %s\n' "$*"; NOTES=$((NOTES + 1)); }
pass() { [ "$VERBOSE" = "1" ] && printf 'ok    %s\n' "$*"; return 0; }

# 只扫第一方脚本：第三方副本（Resources/ 下的框架、要 vendor 的 SDK）不归我们管。
scripts() {
    find . -type f -name '*.sh' \
        -not -path './.git/*' -not -path './.runtime/*' -not -path './Resources/*' \
        -not -path './debs/*' -print | sort
}

# ---------- 1. shell 语法 -----------------------------------------------------
echo "== 1/5 shell 语法"
n=0
while IFS= read -r f; do
    n=$((n + 1))
    case "$(sed -n '1s/^#!//p' "$f")" in
        *bash*) bash -n "$f" 2>/dev/null || fail "语法错误：$f" ;;
        *)      sh   -n "$f" 2>/dev/null || fail "语法错误：$f" ;;
    esac
done < <(scripts)
[ "$FAILS" = "0" ] && pass "已解析 $n 个脚本"

# ---------- 2. 递归删除的变量守卫 --------------------------------------------
echo "== 2/5 递归删除守卫"
before=$FAILS
while IFS= read -r f; do
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        fail "未守卫的递归删除：$f:$hit（改写 \${VAR:?} 或在脚本开头 : \"\${VAR:?}\"）"
    done < <(awk -f scripts/check-rm.awk "$f" 2>/dev/null)
done < <(scripts)
[ "$FAILS" = "$before" ] && pass "递归删除目标都带 :? 守卫、字面量赋值或全局守卫"

# ---------- 3. 写死的 jbroot 绝对路径 -----------------------------------------
echo "== 3/5 写死 jbroot 路径"
# .jbroot-<16 位 hash>：只在 AGENTS.md 的说明、docs/ 记录与 tools/test/ 的历史实验里允许。
before=$FAILS
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    fail "写死 bootstrap 路径：$hit（roothide 重启后 .jbroot-<hash> 会改名，改成运行期探测）"
done < <(
    find . -type f \
        -not -path './.git/*' -not -path './.runtime/*' -not -path './Attachments/*' \
        -not -path './Resources/*' -not -path './tools/test/*' -not -path './docs/*' \
        -not -path './debs/*' -not -name 'AGENTS.md' -print0 2>/dev/null \
        | xargs -0 grep -nE '\.jbroot-[0-9A-Fa-f]{8,}' 2>/dev/null
)
[ "$FAILS" = "$before" ] && pass "第一方文件里没有写死的 .jbroot-<hash>"

# ---------- 4. launchd plist 里的占位符 ---------------------------------------
echo "== 4/5 launchd plist 占位符"
before=$FAILS
while IFS= read -r f; do
    grep -q '<key>ProgramArguments</key>\|<key>Program</key>' "$f" || continue      # 不是 launchd 作业
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        fail "launchd 不认占位符：$f:$hit（写逻辑路径，装完用 icli svc bootstrap 改写）"
    done < <(grep -nE '@PREFIX@|__ROOTFS__|@@PREFIX@@' "$f")
done < <(find . -type f -name '*.plist' -not -path './.git/*' -not -path './Resources/*' -not -path './debs/*' -print)
[ "$FAILS" = "$before" ] && pass "launchd plist 里没有占位符"

# ---------- 5. 持久化读取的空值回退（提示级，不阻断） -------------------------
echo "== 5/5 持久化读取回退（提示级）"
warned=0
while IFS= read -r f; do
    # 读到但解不出来时回退成空集合：下一次保存会把旧数据覆盖成空。
    hits=$(grep -n -A3 'try? JSONDecoder()\.decode' "$f" 2>/dev/null \
        | grep -E 'return \[:[[:space:]]*\]|return \[[[:space:]]*\]' | head -3)
    [ -n "$hits" ] || continue
    # 文件里已有「解不出来先另存一份」的留档逻辑（setAside / backup 之类），就算已处理。
    grep -qE 'setAsideIfUnreadable|unreadable|\.unreadable\b|backupKey|backup' "$f" && { pass "已留档：$f"; continue; }
    warned=1
    warn "读取失败回退为空集合：$f → 建议保留旧文件并另存，别用空值覆盖"
done < <(find Sources -type f -name '*.swift' -print)
[ "$warned" = "0" ] && pass "读不出来的记录都会先留档"

# ---------- 附：有 python3 时顺带跑既有契约检查 -------------------------------
if command -v python3 >/dev/null 2>&1; then
    echo "== 附：python3 契约检查"
    [ -f scripts/check_tool_registration.py ] && {
        python3 scripts/check_tool_registration.py --src Sources/XosviMCP || fail "工具注册一致性（check_tool_registration.py）"
    }
    [ -f scripts/lint_tool_descriptions.py ] && {
        python3 scripts/lint_tool_descriptions.py --src Sources/XosviMCP --fail-on-refs || fail "工具描述引用（lint_tool_descriptions.py）"
    }
else
    echo "== 附：无 python3，跳过契约检查（CI 上会跑）"
fi

echo
if [ "$FAILS" -gt 0 ]; then
    printf '门禁未通过：%d 项 FAIL，%d 项提示\n' "$FAILS" "$NOTES"
    exit 1
fi
printf '门禁通过：0 项 FAIL，%d 项提示\n' "$NOTES"
exit 0
