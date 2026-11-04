/* xosvid 的路径解析自检：不启动守护，只把 jbroot 前缀、真实系统根前缀与两条
 * 关键路径打印出来，方便在任何 bootstrap 上直接看「守护会去哪找 dash / helper」。
 *
 * v2：新增真实根（rootfs）候选。roothide 下进程看到的 / 是 AppGroup 里的共享
 * 视图，bootstrap 只以 .jbroot-XXXX 软链接出现；而 root 守护由 launchd 拉起时
 * 视图可能完全不同，光靠可执行路径推不出前缀，必须逐个候选实测（这是本次现场
 * 踩到的坑：helper 路径拼错 → 每个 helper 调用都 ENOENT）。
 *
 * 构建：clang -arch arm64e -O2 -o pathcheck tools/test/xosvid_pathcheck.c
 * 签名：ldid -S pathcheck
 * 用法：./pathcheck
 *   期望：1) 身份行（mobile 下必有 virtualRoot=<AppGroup>/.jbroot-XXXX）
 *         2) dash / helper 至少一行 resolve= 非空
 *         3) 对每组 (前缀, 逻辑路径) 写入 O_EXCL 的 owner 探针，
 *            最终「RESOLVED」那一行就是 xosvid 会用的路径。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <mach-o/dyld.h>

/* Apple 的私有符号：返回进程的分叉视图根（roothide 下是 AppGroup 里的
 * .jbroot-XXXX）。普通程序也能拿到，用来解释为什么 _NSGetExecutablePath
 * 与真实磁盘路径不一致。 */
extern const char *__get_executable_path_root(void);

static const char *exe_jbroot(void) {
    static char buf[512];
    static int cached = 0;
    if (cached) return buf;
    cached = 1;
    uint32_t sz = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &sz) != 0) { buf[0] = '\0'; return buf; }
    char *p = strstr(buf, "/.jbroot-");
    if (!p) { buf[0] = '\0'; return buf; }
    char *end = strchr(p + 1, '/');
    if (!end) { buf[0] = '\0'; return buf; }
    *end = '\0';
    return buf;
}

static const char *vhroot(void) {
    const char *r = __get_executable_path_root();
    return r ? r : "(null)";
}

static void show(const char *prefix, const char *logical) {
    char buf[700];
    snprintf(buf, sizeof buf, "%s%s", prefix, logical);
    FILE *f = fopen(buf, "r");
    int err = errno;
    printf("%-48s -> %s (X_OK=%d fopen=%s)\n", logical, buf, access(buf, X_OK),
           f ? "ok" : strerror(err));
    if (f) fclose(f);
}

/* 真写探针：以 O_CREAT|O_EXCL 建一个临时文件再删掉，owner 会显示这个路径
 * 在实际磁盘上落到哪 —— 软链接、分叉视图都能被这套办法看穿。 */
static void probe_write(const char *prefix) {
    char p[700];
    snprintf(p, sizeof p, "%s/tmp/xosvid-probe-%d", prefix, (int)getpid());
    int fd = open(p, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0) {
        printf("probe %-44s -> open %s\n", p, strerror(errno));
        return;
    }
    close(fd);
    char cmd[800];
    snprintf(cmd, sizeof cmd, "ls -l %s 2>&1", p);
    printf("probe %-44s -> ok\n", p);
    fflush(stdout);
    if (system(cmd) != 0) { /* 只用于人眼核对 */ }
    unlink(p);
}

int main(void) {
    printf("uid=%d virtualRoot=%s\n", getuid(), vhroot());
    printf("exe jbroot = '%s'\n\n", exe_jbroot());

    const char *cands[] = {
        exe_jbroot(),
        "/private/preboot",       /* rootless/palera1n jbroot 常见基址（下面会跳过不存在者） */
        "",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        printf("[prefix '%s']\n", cands[i]);
        show(cands[i], "/usr/bin/dash");
        show(cands[i], "/usr/libexec/xosvi/xosvi-build");
        show(cands[i], "/private/var/mobile/Documents/wiki.qaq.xosvi/work");
        probe_write(cands[i]);
        printf("\n");
    }

    /* 真实根：/private/var 与 /var 在 iOS 上是同一棵树，写探针会落到同一处 */
    printf("[真实根 /private/var/tmp]\n");
    probe_write("/private/var");
    return 0;
}
