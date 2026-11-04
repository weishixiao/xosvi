// xosvi-probe —— 检查当前进程对关键路径/套接字是否可用（装进 usr/libexec）
// 用法：xosvi-probe [TAG]
//   每条结果一行：ok 或 errno 名称，用来区分「路径拼错」「视图不同」「权限不够」。
//
// 为什么要在设备上留一个探针：roothide 下不同进程看到的根不同（AppGroup 里的
// .jbroot-XXXX 共享视图、launchd 拉起的 root 进程可能是真根 + libroot），
// 守护路径一旦拼错只表现为 helper 全部 ENOENT，没有任何日志。这个工具把
// 「守护会怎么找 bootstrap、找到的路径在不在、数据目录属主是谁」一次摊开。

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <limits.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

#ifndef XOSVI_JBROOT_ENV
#define XOSVI_JBROOT_ENV "XOSVI_JBROOT"
#endif

/* roothide 的 libroot 导出 rootfs_get_path：把逻辑路径换成真实根下的路径。
 * 用 dlsym 取（弱链接在真机工具链上会被 ld 直接判成未定义）；
 * 没有 libroot（rootless / 未注入）时为 NULL。 */
typedef int (*rootfs_fn)(char *, size_t);
static rootfs_fn g_rootfs;

static const char *env_jbroot(void) {
    const char *v = getenv(XOSVI_JBROOT_ENV);
    return (v && v[0] == '/') ? v : "";
}

static int exe_jbroot(char *out, size_t cap) {
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

static int rootfs_join(const char *logical, char *out, size_t cap) {
    if (!g_rootfs) return 0;
    char root[PATH_MAX];
    if (g_rootfs(root, sizeof root) != 0 || !root[0]) return 0;
    snprintf(out, cap, "%s%s", strcmp(root, "/") ? root : "", logical);
    return 1;
}

static int scan_base(const char *base, char *out, size_t cap) {
    DIR *d = opendir(base);
    if (!d) return 0;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, ".jbroot-", 8) != 0) continue;
        char cand[PATH_MAX], probe[PATH_MAX];
        snprintf(cand, sizeof cand, "%s/%s", base, de->d_name);
        snprintf(probe, sizeof probe, "%s/usr/bin/dash", cand);
        if (access(probe, X_OK) == 0) { snprintf(out, cap, "%s", cand); found = 1; break; }
    }
    closedir(d);
    return found;
}

/* 与 xosvid.c 的 find_bootstrap 同序 */
static int find_prefix(const char *logical, char *out, size_t cap, char *how, size_t howcap) {
    char p[PATH_MAX];
    if (env_jbroot()[0]) {
        snprintf(p, sizeof p, "%s%s", env_jbroot(), logical);
        if (access(p, X_OK) == 0) { snprintf(out, cap, "%s", env_jbroot()); snprintf(how, howcap, "env"); return 1; }
    }
    if (rootfs_join(logical, p, sizeof p) && access(p, X_OK) == 0) {
        char r[PATH_MAX];
        g_rootfs(r, sizeof r);
        snprintf(out, cap, "%s", strcmp(r, "/") ? r : "");
        snprintf(how, howcap, "libroot");
        return 1;
    }
    char exe[PATH_MAX];
    if (exe_jbroot(exe, sizeof exe)) {
        snprintf(p, sizeof p, "%s%s", exe, logical);
        if (access(p, X_OK) == 0) { snprintf(out, cap, "%s", exe); snprintf(how, howcap, "exe"); return 1; }
    }
    const char *bases[] = { "/private/var/containers/Bundle/Application",
                            "/var/containers/Bundle/Application", NULL };
    for (int i = 0; bases[i]; i++) {
        if (scan_base(bases[i], p, sizeof p)) {
            snprintf(out, cap, "%s", p);
            snprintf(how, howcap, "scan:%s", bases[i]);
            return 1;
        }
    }
    if (access(logical, X_OK) == 0) {
        snprintf(out, cap, "");
        snprintf(how, howcap, "realroot");
        return 1;
    }
    out[0] = '\0';
    how[0] = '\0';
    return 0;
}

static void line(const char *tag, const char *what, int ok, const char *detail) {
    printf("%-10s %-46s %-4s %s\n", tag ? tag : "", what, ok ? "ok" : "FAIL", detail ? detail : "");
}

int main(int argc, char **argv) {
    const char *tag = argc > 1 ? argv[1] : "";
    g_rootfs = (rootfs_fn)dlsym(RTLD_DEFAULT, "rootfs_get_path");
    char exe[PATH_MAX] = "";
    exe_jbroot(exe, sizeof exe);
    printf("uid=%d euid=%d tag=%s exe_jbroot=%s env=%s libroot=%s\n",
           getuid(), geteuid(), tag, exe[0] ? exe : "(none)",
           env_jbroot()[0] ? env_jbroot() : "(unset)",
           g_rootfs ? "present" : "missing");

    char prefix[PATH_MAX], how[128];
    int have = find_prefix("/usr/bin/dash", prefix, sizeof prefix, how, sizeof how);
    printf("bootstrap prefix='%s' via=%s\n", prefix, have ? how : "(not found)");

    char dash[PATH_MAX], helper[PATH_MAX];
    snprintf(dash, sizeof dash, "%s/usr/bin/dash", prefix);
    snprintf(helper, sizeof helper, "%s/usr/libexec/xosvi/xosvi-build", prefix);
    line(tag, "dash", access(dash, X_OK) == 0, dash);
    line(tag, "xosvi-build", access(helper, X_OK) == 0, helper);

    const char *datas[] = { "/private/var/mobile/Documents/wiki.qaq.xosvi",
                            "/var/mobile/Documents/wiki.qaq.xosvi", NULL };
    for (int i = 0; datas[i]; i++) {
        struct stat st;
        int ok = stat(datas[i], &st) == 0;
        char d[128]; d[0] = '\0';
        if (ok) snprintf(d, sizeof d, "owner=%d:%d mode=%o", (int)st.st_uid, (int)st.st_gid, st.st_mode & 07777);
        line(tag, datas[i], ok, d);
    }

    char sockp[PATH_MAX];
    snprintf(sockp, sizeof sockp, "/var/tmp/.xosvi-probe-%d.sock", (int)getpid());
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s >= 0) {
        struct sockaddr_un a;
        memset(&a, 0, sizeof a);
        a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof a.sun_path, "%s", sockp);
        int b = bind(s, (struct sockaddr *)&a, sizeof a);
        line(tag, "/var/tmp bind", b == 0, b ? strerror(errno) : sockp);
        if (b == 0) unlink(sockp);
        close(s);
    }
    return have ? 0 : 1;
}
