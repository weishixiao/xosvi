// xosvi-common.h —— 三个 helper 共用的定义（bootstrap 前缀解析、安全路径判定）
//
// 为什么需要它：roothide 下不同进程看到的「根」不同。helper 是 xosvid（root 守护）
// fork 出来的，继承守护的视图：可能看见真根（/usr/... 直接可用），也可能看见
// AppGroup 里的 .jbroot-XXXX 共享视图。写死 /var/jb 在两边都会错——旧版 0.1.0
// 就是这么挂的（日志里 bootstrap=/var/jb，opendir 全部 ENOENT）。
// 这里的解析顺序和 xosvid / xosvi-pathcheck 完全一致。

#ifndef XOSVI_COMMON_H
#define XOSVI_COMMON_H

#define _DARWIN_C_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

/* 数据目录（真根视图下写死 /private/var 是对的：两者都指向同一个卷） */
#define XOSVI_DATA_DIR "/private/var/mobile/Documents/wiki.qaq.xosvi"
#define XOSVI_WORK_ROOT XOSVI_DATA_DIR "/work"

typedef int (*xosvi_rootfs_fn)(char *, size_t);

static int xosvi_probe_prefix(const char *prefix) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/usr/bin/dash", prefix);
    return access(p, X_OK) == 0;
}

static int xosvi_exe_jbroot(char *out, size_t cap) {
    char buf[PATH_MAX];
    uint32_t sz = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0) return 0;
    char *p = strstr(buf, "/.jbroot-");
    if (!p) return 0;
    char *end = strchr(p + 1, '/');
    if (!end) return 0;
    *end = '\0';
    snprintf(out, cap, "%s", buf);
    return 1;
}

static int xosvi_scan_base(const char *base, char *out, size_t cap) {
    DIR *d = opendir(base);
    if (!d) return 0;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, ".jbroot-", 8) != 0) continue;
        char cand[PATH_MAX];
        snprintf(cand, sizeof cand, "%s/%s", base, de->d_name);
        if (xosvi_probe_prefix(cand)) { snprintf(out, cap, "%s", cand); found = 1; break; }
    }
    closedir(d);
    return found;
}

/* 返回 bootstrap 前缀（真根为空串）；0 表示找不到。 */
static int xosvi_bootstrap(char *out, size_t cap) {
    const char *env = getenv("XOSVI_JBROOT");
    if (env && env[0] == '/' && xosvi_probe_prefix(env)) {
        snprintf(out, cap, "%s", env);
        return 1;
    }
    xosvi_rootfs_fn rootfs = (xosvi_rootfs_fn)dlsym(RTLD_DEFAULT, "rootfs_get_path");
    if (rootfs) {
        char root[PATH_MAX];
        if (rootfs(root, sizeof root) == 0 && root[0]) {
            const char *pre = strcmp(root, "/") ? root : "";
            if (xosvi_probe_prefix(pre)) { snprintf(out, cap, "%s", pre); return 1; }
        }
    }
    char exe[PATH_MAX];
    if (xosvi_exe_jbroot(exe, sizeof exe) && xosvi_probe_prefix(exe)) {
        snprintf(out, cap, "%s", exe);
        return 1;
    }
    const char *bases[] = { "/private/var/containers/Bundle/Application",
                            "/var/containers/Bundle/Application", NULL };
    for (int i = 0; bases[i]; i++) {
        char cand[PATH_MAX];
        if (xosvi_scan_base(bases[i], cand, sizeof cand)) {
            snprintf(out, cap, "%s", cand);
            return 1;
        }
    }
    if (xosvi_probe_prefix("")) { out[0] = '\0'; return 1; }
    out[0] = '\0';
    return 0;
}

/* <prefix><逻辑路径> */
static void xosvi_path(char *out, size_t cap, const char *prefix, const char *logical) {
    snprintf(out, cap, "%s%s", prefix, logical);
}

/* path 是否等于 root 或位于其下（两者都应是 realpath 结果）。 */
static int xosvi_inside(const char *path, const char *root) {
    size_t rl = strlen(root);
    if (rl == 0) return 0;
    if (strncmp(path, root, rl) != 0) return 0;
    return path[rl] == '/' || path[rl] == 0;
}

#endif
