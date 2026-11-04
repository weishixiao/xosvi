#!/bin/sh
# apelin/build.sh —— com.xosvi.daemon 的构建脚本（apelin_project_build 调用）
#
# 产物（装在 $APELIN_PREFIX 下）：
#   usr/libexec/xosvid                  root 守护：XPC MachService wiki.qaq.xosvi.service
#   usr/libexec/xosvi/xosvi-build       构建 helper
#   usr/libexec/xosvi/xosvi-install     安装 helper
#   usr/libexec/xosvi/xosvi-symbolicate 符号化 helper
#   usr/libexec/xosvi/xosvi-pathcheck   路径自检（设备上排查用）
#   usr/bin/xosvi-cli                   命令行客户端
#   Library/LaunchDaemons/wiki.qaq.xosvid.plist
#
# 只用 Apelin 给的变量；所有路径都从变量拼，任一个为空就立刻停（空值会变成 /）。
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}"   # roothide 下为空串，rootless 下为 /var/jb

stage="$(mktemp -d -p "${TMPDIR:?}" stage.XXXXXX)"
# 编译产物放脚本自己的临时目录（APELIN_PACKAGE_DIR 之外），最后只把 deb 写进去。
work="$(mktemp -d -p "${TMPDIR:?}" work.XXXXXX)"
trap 'rm -rf -- "${stage:?}" "${work:?}"' EXIT

cd "${APELIN_PROJECT_ROOT:?}"

# ---- 架构与宏 ----------------------------------------------------------------
case "${APELIN_BOOTSTRAP}" in
  roothide)  ARCHS="arm64e";                         BOOTDEF="-DAPELIN_BOOTSTRAP_ROOTHIDE=1" ;;
  rootless)  ARCHS="arm64 arm64e";                   BOOTDEF="-DAPELIN_BOOTSTRAP_ROOTLESS=1" ;;
  *) echo "unknown bootstrap ${APELIN_BOOTSTRAP}" >&2; exit 1 ;;
esac

build_one() {  # build_one <源文件> <输出名> <额外 clang 参数...>
  src="${APELIN_PROJECT_ROOT:?}/$1"; out="$2"; shift 2
  if [ "${ARCHS#* }" != "$ARCHS" ]; then
    # 多架构（rootless）：分别编译再 lipo
    objs=""
    for a in $ARCHS; do
      obj="${work:?}/build.$a.$(basename "$out").o"
      ( cd "${work:?}" && clang -arch "$a" -O2 -Wall -Wno-unused-function -Wno-unused-variable \
          "$BOOTDEF" -DAPELIN_PACKAGE_ID='"com.xosvi.daemon"' \
          -DAPELIN_BUILD_ID="\"${APELIN_BUILD_ID}\"" \
          "$@" -c "$src" -o "$obj" )
      objs="$objs $obj"
    done
    lipo -create $objs -output "${work:?}/$out"
    rm -f $objs
  else
    # 单架构：直接链接，不走目标文件（ldid 认不出 clang 产出的 .o 格式）
    ( cd "${work:?}" && clang -arch "$ARCHS" -O2 -Wall -Wno-unused-function -Wno-unused-variable \
        "$BOOTDEF" -DAPELIN_PACKAGE_ID='"com.xosvi.daemon"' \
        -DAPELIN_BUILD_ID="\"${APELIN_BUILD_ID}\"" \
        "$@" -o "$out" "$src" )
  fi
  chmod 0755 "${work:?}/$out"
}

# ---- 编译 --------------------------------------------------------------------
echo ">>> 编译 (${APELIN_BOOTSTRAP}, ${ARCHS})"
build_one tools/xosvid.c               xosvid               -framework Foundation
build_one tools/xosvi-pathcheck.c      xosvi-pathcheck
build_one tools/xosvi-cli.c            xosvi-cli            -framework Foundation -framework CoreFoundation
build_one Support/xosvi/xosvi-build.c       xosvi-build      -ISupport/xosvi
build_one Support/xosvi/xosvi-install.c     xosvi-install    -ISupport/xosvi
build_one Support/xosvi/xosvi-symbolicate.c xosvi-symbolicate -ISupport/xosvi

# ---- 签名 --------------------------------------------------------------------
echo ">>> 签名"
staged_bin() {  # 解析阶段产物：优先 work 目录，退回 stage 目录（不同 Apelin 版本给的 TMPDIR 不同）
  for d in "${work:?}" "${stage:?}"; do
    [ -f "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }
  done
  echo "staged binary missing: $1" >&2
  exit 1
}
BIN_XOSVID=$(staged_bin xosvid)
BIN_CLI=$(staged_bin xosvi-cli)
BIN_PATHCHECK=$(staged_bin xosvi-pathcheck)
BIN_BUILD=$(staged_bin xosvi-build)
BIN_INSTALL=$(staged_bin xosvi-install)
BIN_SYM=$(staged_bin xosvi-symbolicate)

ldid -S"${APELIN_PROJECT_ROOT:?}/Support/xosvid.entitlements"     "$BIN_XOSVID"
ldid -S"${APELIN_PROJECT_ROOT:?}/Support/xosvi-cli.entitlements"  "$BIN_CLI"
ldid -S"${APELIN_PROJECT_ROOT:?}/Support/bin-entitlements.plist"  "$BIN_PATHCHECK" || ldid -S "$BIN_PATHCHECK"
for b in "$BIN_BUILD" "$BIN_INSTALL" "$BIN_SYM"; do
  ldid -S"${APELIN_PROJECT_ROOT:?}/Support/bin-entitlements.plist" "$b" || ldid -S "$b"
done

# ---- 布局 --------------------------------------------------------------------
echo ">>> 布局"
root="${stage:?}/root"
pkg="${root:?}${APELIN_PREFIX}"
mkdir -p "$pkg/usr/libexec/xosvi" "$pkg/usr/bin" "$pkg/Library/LaunchDaemons" "$root/DEBIAN"

install -m 0755 "$BIN_XOSVID"     "$pkg/usr/libexec/xosvid"
install -m 0755 "$BIN_BUILD"      "$pkg/usr/libexec/xosvi/xosvi-build"
install -m 0755 "$BIN_INSTALL"    "$pkg/usr/libexec/xosvi/xosvi-install"
install -m 0755 "$BIN_SYM"        "$pkg/usr/libexec/xosvi/xosvi-symbolicate"
install -m 0755 "$BIN_PATHCHECK"  "$pkg/usr/libexec/xosvi/xosvi-pathcheck"
install -m 0755 "$BIN_CLI"        "$pkg/usr/bin/xosvi-cli"

# 布局自检：少一个文件就失败，而不是装出半套
for f in usr/libexec/xosvid usr/libexec/xosvi/xosvi-build usr/libexec/xosvi/xosvi-install \
         usr/libexec/xosvi/xosvi-symbolicate usr/libexec/xosvi/xosvi-pathcheck usr/bin/xosvi-cli; do
  [ -f "$pkg/$f" ] || { echo "layout missing: $f" >&2; exit 1; }
done

# launchd plist：路径写 bootstrap 根的**逻辑路径**（/usr/libexec/...、/var/log/...）。
# 为什么不用占位：本机实测 launchd 不认 @PREFIX@、__ROOTFS__、【@@PREFIX@@】 中的任何一个，
# 会把字面量当相对路径，服务就"已加载、起不来"。正确做法是安装时由 icli svc bootstrap /
# load 把路径就地改写成 jbroot 下的真实路径（它自己会 patched:true），先 `icli svc paths`
# 预览、再加载。rootless（/var/jb）同样由 icli 重写，不需要脚本里做替换。
cat > "$pkg/Library/LaunchDaemons/wiki.qaq.xosvid.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>wiki.qaq.xosvid</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/libexec/xosvid</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>wiki.qaq.xosvi.service</key>
		<true/>
	</dict>
	<key>UserName</key>
	<string>root</string>
	<key>Umask</key>
	<integer>18</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>DISABLE_TWEAKS</key>
		<string>1</string>
	</dict>
	<key>StandardErrorPath</key>
	<string>/var/log/xosvid.log</string>
	<key>SoftResourceLimits</key>
	<dict>
		<key>NumberOfFiles</key>
		<integer>10240</integer>
	</dict>
</dict>
</plist>
PLIST

# ---- DEBIAN ------------------------------------------------------------------
VERSION="0.2.0"   # 0.1.0 是旧的 /var/jb 硬编码版本，helper 路径全 ENOENT
cat > "$root/DEBIAN/control" <<CONTROL
Package: com.xosvi.daemon
Version: ${VERSION}
Architecture: ${APELIN_ARCHITECTURE}
Maintainer: Xosvi <dev@xosvi.local>
Author: Xosvi
Section: Development
Priority: optional
Depends: firmware (>= 15.0)
Description: Xosvi 特权守护进程与构建 helper
 xosvid 以 root 身份提供 XPC MachService wiki.qaq.xosvi.service，
 只执行白名单 helper（xosvi-build / xosvi-install / xosvi-symbolicate）。
 roothide 下按 /var/containers/Bundle/Application/.jbroot-* 实际探测 bootstrap。
CONTROL

# postinst：目录与权限；launchd 的加载交给 icli（它会就地改写成 jbroot 路径）
#
# 用 【@@PREFIX@@】 占位而不是 @PREFIX@：dpkg 在解包时就会把 control 里的 @PREFIX@
# 展开成安装前缀（roothide 下是空串），脚本正文里的同一个串会剩下字面量，
# 以前就是这么把 postinst 跑挂的（chmod: cannot access '@PREFIX@/usr/libexec/xosvid'）。
cat > "$root/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
# 这里的 【@@PREFIX@@】 由 dpkg 的 @PREFIX@ 展开规则替换成真实安装前缀
PREFIX="【@@PREFIX@@】"
mkdir -p "${PREFIX}/var/log"
chmod 0755 "${PREFIX}/usr/libexec/xosvid" "${PREFIX}/usr/libexec/xosvi"/* 2>/dev/null
exit 0
POSTINST
chmod 0755 "$root/DEBIAN/postinst"

# ---- 打包 --------------------------------------------------------------------
echo ">>> dpkg-deb"
dpkg-deb -b --root-owner-group "${root:?}" "${APELIN_PACKAGE_DIR:?}/com.xosvi.daemon_${VERSION}_${APELIN_ARCHITECTURE}.deb"
echo ">>> done"
