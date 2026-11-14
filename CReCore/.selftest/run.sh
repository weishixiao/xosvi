#!/bin/sh
# 逆向引擎（CReCore/src/xosvi_re.c）本机自测：编译 XRE_TOOL 版 xre → 跑 fixture → 校验关键计数。
#
#   sh CReCore/.selftest/run.sh                只跑 fixture
#   sh CReCore/.selftest/run.sh <Mach-O 路径>  额外分析一个真实二进制并打印概览
#
# 需要 clang 与 ldid（iOS toolchain）。产物写在 .selftest/ 下，不入库。
# xre.ent.plist 只为本机执行用：没有 no-sandbox 等 entitlements，内核会直接以信号 9 杀掉进程。
#
# 调试：给引擎加 XRE_DEBUG=1 会往 stderr 打每个类的 ro 地址与属性列表条目。
set -eu

# 一律用相对路径调工具：roothide 下 $(pwd) 可能带 /rootfs 前缀，而 clang/ld 写文件时不认这个前缀
cd "$(dirname "$0")/../.."
sel=CReCore/.selftest

xre="$sel/xre"
clang -O1 -Wall -DXRE_TOOL -ICReCore/include -o "$xre" CReCore/src/xosvi_re.c
ldid -S"$sel/xre.ent.plist" "$xre"

fail=0
check() {
    if grep -qF -- "$2" "$1"; then printf '  ok    %s\n' "$2"
    else printf '  FAIL  %s（期望出现在 %s）\n' "$2" "$1"; fail=1; fi
}

# fixture A：三个类，FxAlpha 声明遵循 FxProto（clang 会把它和 NSObject 协议的 4 个属性
# 一起写进类的属性表，所以属性是 6 而不是源码里的 2）；分类与类在同一 TU，clang 直接
# 合并进类的方法表，__objc_catlist 为空 —— 分类数为 0 是编译器行为，不是解析缺陷。
clang -dynamiclib -arch arm64e -fobjc-arc -framework Foundation -o "$sel/fxre.dylib" "$sel/FxRe.m"
rm -rf "$sel/out"; mkdir -p "$sel/out"
"$xre" "$sel/fxre.dylib" "$sel/out" >/dev/null
echo "fixture A: FxRe.m"
check "$sel/out/report.md" "| 类 / 分类 / 协议 | 3 / 0 / 2 |"
check "$sel/out/report.md" "| 方法 / ivar / 属性 | 13 / 4 / 6 |"
check "$sel/out/report.md" "| 导入符号 / bind / rebase | 10 / 23 / 129 |"
check "$sel/out/report.md" "- 父类：NSObject"

# fixture B：同一份源码去掉协议遵循 → 属性只剩自己的 2 条；父类是 bind 指针，仍要解出名字。
clang -dynamiclib -arch arm64e -fobjc-arc -framework Foundation -o "$sel/fxre2.dylib" "$sel/FxRe2.m"
rm -rf "$sel/out2"; mkdir -p "$sel/out2"
"$xre" "$sel/fxre2.dylib" "$sel/out2" >/dev/null
echo "fixture B: FxRe2.m"
check "$sel/out2/report.md" "| 方法 / ivar / 属性 | 13 / 4 / 2 |"
check "$sel/out2/report.md" "- 父类：NSObject"

# fixture C：给 NSObject 加分类（类体在别的镜像里）→ 必须经 __objc_catlist 解出分类及其所属类。
clang -dynamiclib -arch arm64e -fobjc-arc -framework Foundation -o "$sel/fxre3.dylib" "$sel/FxRe3.m"
rm -rf "$sel/out3"; mkdir -p "$sel/out3"
"$xre" "$sel/fxre3.dylib" "$sel/out3" >/dev/null
echo "fixture C: FxRe3.m"
check "$sel/out3/report.md" "| 类 / 分类 / 协议 | 0 / 1 / 0 |"
check "$sel/out3/report.md" "→ NSObject"

if [ $# -ge 1 ]; then
    rm -rf "$sel/out-real"; mkdir -p "$sel/out-real"
    echo "真实二进制: $1"
    "$xre" "$1" "$sel/out-real"
    sed -n '/^| 类 \/ 分类 \/ 协议/,/^| 导入符号/p' "$sel/out-real/report.md"
fi

if [ "$fail" -ne 0 ]; then echo "有检查失败"; exit 1; fi
echo "全部通过"
