/*
 * xosvi-pathcheck —— 路径解析自检（装进 usr/libexec，设备上排查用）
 *
 * 用法：xosvi-pathcheck [逻辑路径...]
 *   默认检查 /usr/bin/dash、/usr/libexec/xosvi/xosvi-build、数据目录，
 *   并做写探针（bootstrap 根 / 真根各一次）。
 *
 * 为什么需要它：roothide 下不同进程看到的「根」不同，App 侧是 AppGroup 里的
 * .jbroot-XXXX 共享视图，launchd 拉起的 root 进程可能是真根（+ libroot）。
 * 拼错路径没有任何提示，只表现为 helper 全部 ENOENT —— 这个工具把每条候选路径的
 * 「看不看得见 / 读不读得到 / 写得进哪里」一次摊开，和 xosvid 用同一套解析顺序。
 *
 * 构建：clang -arch arm64e -arch arm64 -O2 -o xosvi-pathcheck tools/xosvi-pathcheck.c
 * 签名：ldid -S<entitlements>（platform-application / no-sandbox）
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <dirent.h>
#include <limits.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>

typedef int (*rootfs_fn)(char *, size_t);

static int probe_prefix(const char *prefix) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/usr/bin/dash", prefix);
    return access(p, X_OK) == 0;
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

static int scan_base(const char *base, char *out, size_t cap) {
    DIR *d = opendir(base);
    if (!d) return 0;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, ".jbroot-", 8) != 0) continue;
        char cand[PATH_MAX];
        snprintf(cand, sizeof cand, "%s/%s", base, de->d_name);
        if (probe_prefix(cand)) { snprintf(out, cap, "%s", cand); found = 1; break; }
    }
    closedir(d);
    return found;
}

static void show(const char *prefix, const char *logical) {
    char buf[PATH_MAX];
    snprintf(buf, sizeof buf, "%s%s", prefix, logical);
    errno = 0;
    FILE *f = fopen(buf, "r");
    int open_err = errno;
    int xok = access(buf, X_OK);
    int uid = -1, gid = -1;
    struct stat st;
    if (stat(buf, &st) == 0) { uid = (int)st.st_uid; gid = (int)st.st_gid; }
    printf("  %-44s open=%-12s x=%d owner=%d:%d\n",
           buf, f ? "ok" : strerror(open_err), xok, uid, gid);
    if (f) fclose(f);
}

static void write_probe(const char *prefix) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/var/tmp/.xosvi-pathcheck-%d", prefix, (int)getpid());
    int fd = open(p, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0) { printf("  %-44s %s\n", p, strerror(errno)); return; }
    close(fd);
    struct stat st;
    if (stat(p, &st) == 0) printf("  %-44s ok owner=%d:%d\n", p, (int)st.st_uid, (int)st.st_gid);
    unlink(p);
}

int main(int argc, char **argv) {
    rootfs_fn rootfs = (rootfs_fn)dlsym(RTLD_DEFAULT, "rootfs_get_path");
    printf("uid=%d euid=%d libroot=%s\n", getuid(), geteuid(), rootfs ? "present" : "missing");

    if (rootfs) {
        char root[PATH_MAX];
        if (rootfs(root, sizeof root) == 0) printf("rootfs_get_path = '%s'\n", root);
    }
    char exe[PATH_MAX];
    if (exe_jbroot(exe, sizeof exe)) printf("exe jbroot = '%s'\n", exe);
    const char *env = getenv("XOSVI_JBROOT");
    printf("XOSVI_JBROOT = '%s'\n", env ? env : "");

    const char *prefix = NULL;
    const char *how = "none";
    if (env && env[0] == '/' && probe_prefix(env)) { prefix = env; how = "env"; }
    if (!prefix && rootfs) {
        static char root[PATH_MAX];
        if (rootfs(root, sizeof root) == 0 && root[0]) {
            const char *pre = strcmp(root, "/") ? root : "";
            if (probe_prefix(pre)) { prefix = pre; how = "libroot"; }
        }
    }
    if (!prefix && exe_jbroot(exe, sizeof exe) && probe_prefix(exe)) { prefix = exe; how = "exe"; }
    static char found[PATH_MAX];
    if (!prefix) {
        const char *bases[] = { "/private/var/containers/Bundle/Application",
                                "/var/containers/Bundle/Application", NULL };
        for (int i = 0; bases[i]; i++) {
            if (scan_base(bases[i], found, sizeof found)) { prefix = found; how = "scan"; break; }
        }
    }
    if (!prefix && probe_prefix("")) { prefix = ""; how = "realroot"; }
    printf("resolved bootstrap prefix = '%s' via %s\n", prefix ? prefix : "(none)", how);
    if (!prefix) return 1;

    char canon[PATH_MAX];
    snprintf(canon, sizeof canon, "%s", prefix);
    printf("\nbootstrap 视图:\n");
    if (argc > 1) {
        for (int i = 1; i < argc; i++) show(canon, argv[i]);
    } else {
        show(canon, "/usr/bin/dash");
        show(canon, "/usr/libexec/xosvi/xosvi-build");
        show(canon, "/private/var/mobile/Documents/wiki.qaq.xosvi/work");
    }
    printf("\n写探针:\n");
    write_probe(canon);
    if (canon[0]) write_probe("");          /* 同一逻辑路径的真根侧 */
    return 0;
}
