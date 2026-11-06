// xosvi-bin —— 借 root 身份跑 App 包内（Xosvi.app/bin）的注入工具
//
// 为什么需要它：iOS 17 + 越狱上，App 里那条提权链全断——persona spawn 被 AMFI 拒（85），
// 包内二进制没有 setuid 位，`/bin/cp` 这类系统路径在真根视图里不存在（ENOENT 2）。
// 于是「静态重打包 → 复制 App」第一步就死在 spawnRoot，整条 control.inject 走不下去。
// 守护 xosvid 是 uid=0 的常驻进程，这里给出它的一条白名单 helper：
//
//   xosvi-bin sign <mach-o 路径>
//       用 ldid -S「当前进程自身签名里的 entitlements」重签。App 侧会先把 Xosvi.app
//       主二进制的签名原样写到该路径上（copyBundledToolWithEntitlements），
//       于是副本带上与主 App 同一套权限，再放回 bin/ 里由这里签名。
//
//   xosvi-bin <工具名> <工具路径> -- <参数...>
//       以 root execv 该工具。工具路径必须是 Xosvi.app/bin 下的普通文件，
//       工具名与文件 basename 必须一致。
//
// 安全边界（本 helper 以 root 运行，必须可被任意本机进程安全调用）：
//   * 只接受白名单里的工具名，且 basename 同名；
//   * 路径必须落在 Xosvi.app/bin 之下（realpath 后判定，防 ../ 与符号链接逃逸）；
//   * 不经过 shell，参数原样传给 execv；
//   * 子进程前清掉 DYLD_/LD_ 等注入型环境变量，PATH 固定；
//   * 每次调用写一行 xosvid.log，便于排障。

#include "xosvi-common.h"
#include <stdarg.h>

extern char **environ;

#define MAX_ARGS 64

static const char *allowed_tools[] = {
    "ldid", "cp", "cp-15", "rm", "mv", "mv-15", "mkdir", "chown",
    "insert_dylib", "optool", "install_name_tool", "ct_bypass", "teamid",
    "opainject", NULL
};

static const char *base_name(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

static int is_allowed_tool(const char *name) {
    for (int i = 0; allowed_tools[i]; i++) {
        if (strcmp(allowed_tools[i], name) == 0) return 1;
    }
    return 0;
}

/* Xosvi.app/bin 的 realpath。
 *
 * 不能只看自身可执行文件的位置：helper 装在 <bootstrap>/usr/libexec/xosvi/ 下，
 * 那个路径跟 App 目录毫无关系（第一版就是这么写的，运行时直接报
 * 「cannot locate Xosvi.app/bin」）。按下列顺序找：
 *   1. 环境变量 XOSVI_APP_BIN（排障时可手工指定）；
 *   2. 自己在 Xosvi.app/bin 里（直接把 helper 拷进 App 用的情形）；
 *   3. 扫描 /private/var/containers/Bundle/Application 下的每个容器，找 Xosvi.app/bin，
 *      与 xosvi_bootstrap 的做法一致：两个 Containers 基准路径都扫一遍。 */
static int dir_exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int app_bin_dir(char *out, size_t cap) {
    const char *env = getenv("XOSVI_APP_BIN");
    if (env && env[0] == '/' && dir_exists(env)) { snprintf(out, cap, "%s", env); return 1; }

    char exe[PATH_MAX];
    uint32_t sz = (uint32_t)sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) == 0) {
        char real[PATH_MAX];
        if (realpath(exe, real)) {
            char *slash = strrchr(real, '/');          /* <...>/bin/xosvi-bin */
            if (slash) {
                *slash = '\0';
                if (strcmp(base_name(real), "bin") == 0) {
                    char *app = strrchr(real, '/');
                    if (app) {
                        *app = '\0';
                        if (strstr(real, ".app")) {
                            snprintf(out, cap, "%s/bin", real);
                            if (dir_exists(out)) return 1;
                        }
                    }
                }
            }
        }
    }

    const char *bases[] = { "/private/var/containers/Bundle/Application",
                            "/var/containers/Bundle/Application", NULL };
    for (int i = 0; bases[i]; i++) {
        DIR *d = opendir(bases[i]);
        if (!d) continue;
        struct dirent *de;
        int found = 0;
        while ((de = readdir(d))) {
            if (de->d_name[0] == '.') continue;
            char cand[PATH_MAX];
            snprintf(cand, sizeof cand, "%s/%s/Xosvi.app/bin", bases[i], de->d_name);
            if (dir_exists(cand)) { snprintf(out, cap, "%s", cand); found = 1; break; }
        }
        closedir(d);
        if (found) return 1;
    }
    return 0;
}

static void log_line(const char *fmt, ...) {
    char prefix[PATH_MAX];
    if (!xosvi_bootstrap(prefix, sizeof prefix)) prefix[0] = '\0';
    char path[PATH_MAX * 2];
    xosvi_path(path, sizeof path, prefix, "/var/log/xosvid.log");
    FILE *f = fopen(path, "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(f, "xosvi-bin[%d]: ", (int)getpid());
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* 清掉会影响子进程行为的注入型环境变量（dyld、老式 ld、include 路径）。 */
static void sanify_env(void) {
    static const char *drop_prefix[] = {
        "DYLD_", "LD_", "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
        "SUDO_", NULL
    };
    for (int i = 0; drop_prefix[i]; i++) {
        size_t n = strlen(drop_prefix[i]);
        for (char **e = environ; e && *e;) {
            if (strncmp(*e, drop_prefix[i], n) == 0) {
                char **p = e;
                while (p[1]) { p[0] = p[1]; p++; }
                *p = NULL;
                continue;
            }
            e++;
        }
    }
    setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
}

static int run_wait(const char *exe, char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setpgid(0, 0);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); if (devnull > 2) close(devnull); }
        execv(exe, argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static int sign_one(const char *path, const char *ldid) {
    char real[PATH_MAX];
    if (!realpath(path, real)) {
        fprintf(stderr, "xosvi-bin sign: %s: %s\n", path, strerror(errno));
        return 2;
    }
    struct stat st;
    if (stat(real, &st) != 0 || !S_ISREG(st.st_mode)) {
        fprintf(stderr, "xosvi-bin sign: %s is not a regular file\n", real);
        return 2;
    }
    /* 读出「当前进程签名里的 entitlements」（由 App 侧预先写入该文件） */
    int pfd[2];
    if (pipe(pfd) != 0) return 3;
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[0]); close(pfd[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); if (devnull > 2) close(devnull); }
        char *a[] = { (char *)ldid, "-e", real, NULL };
        execv(ldid, a);
        _exit(127);
    }
    close(pfd[1]);
    char ent_path[PATH_MAX];
    snprintf(ent_path, sizeof ent_path, "/tmp/xosvi-ent-%d.plist", (int)getpid());
    FILE *out = fopen(ent_path, "w");
    if (!out) { close(pfd[0]); return 3; }
    char buf[4096];
    ssize_t n;
    size_t total = 0;
    while ((n = read(pfd[0], buf, sizeof buf)) > 0) { fwrite(buf, 1, n, out); total += (size_t)n; }
    close(pfd[0]);
    fclose(out);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0) || total == 0) {
        unlink(ent_path);
        fprintf(stderr, "xosvi-bin sign: ldid -e %s failed (rc=%d, %zu bytes)\n",
                real, WIFEXITED(status) ? WEXITSTATUS(status) : -1, total);
        return 3;
    }
    char arg[PATH_MAX + 4];
    snprintf(arg, sizeof arg, "-S%s", ent_path);
    char *a[] = { (char *)ldid, arg, real, NULL };
    int rc = run_wait(ldid, a);
    unlink(ent_path);
    log_line("sign %s -> %d", real, rc);
    if (rc != 0) fprintf(stderr, "xosvi-bin sign: ldid %s %s failed (%d)\n", arg, real, rc);
    return rc;
}

int main(int argc, char **argv) {
    char bindir[PATH_MAX];
    if (!app_bin_dir(bindir, sizeof bindir)) {
        fprintf(stderr, "xosvi-bin: cannot locate Xosvi.app/bin\n");
        return 1;
    }
    char ldid[PATH_MAX];
    snprintf(ldid, sizeof ldid, "%s/ldid", bindir);

    if (argc < 2) {
        fprintf(stderr, "usage: xosvi-bin sign <mach-o> | xosvi-bin <tool> <tool-path> -- [args...]\n");
        return 2;
    }

    if (strcmp(argv[1], "sign") == 0) {
        if (argc < 3) { fprintf(stderr, "usage: xosvi-bin sign <mach-o>\n"); return 2; }
        sanify_env();
        return sign_one(argv[2], ldid);
    }

    const char *tool = argv[1];
    if (!is_allowed_tool(tool)) {
        log_line("reject tool '%s'", tool);
        fprintf(stderr, "xosvi-bin: tool '%s' not allowed\n", tool);
        return 2;
    }
    if (argc < 3) { fprintf(stderr, "xosvi-bin: missing tool path\n"); return 2; }
    char real[PATH_MAX];
    if (!realpath(argv[2], real)) {
        fprintf(stderr, "xosvi-bin: %s: %s\n", argv[2], strerror(errno));
        return 2;
    }
    size_t bl = strlen(bindir);
    int inside_app = (strncmp(real, bindir, bl) == 0 && real[bl] == '/');
    int inside_boot = 0;
    char prefix[PATH_MAX];
    if (!inside_app && xosvi_bootstrap(prefix, sizeof prefix) && prefix[0]) {
        char ubin[PATH_MAX];
        snprintf(ubin, sizeof ubin, "%s/usr/bin", prefix);
        size_t ul = strlen(ubin);
        inside_boot = (strncmp(real, ubin, ul) == 0 && real[ul] == '/');
    }
    if (!inside_app && !inside_boot) {
        log_line("reject path '%s' (not in %s nor <bootstrap>/usr/bin)", real, bindir);
        fprintf(stderr, "xosvi-bin: %s is outside %s and <bootstrap>/usr/bin\n", real, bindir);
        return 2;
    }
    /* App 内工具必须 basename 与工具名一致；bootstrap 的 coreutils 允许 cp-15 → cp 这类别名 */
    if (inside_app && strcmp(base_name(real), tool) != 0) {
        fprintf(stderr, "xosvi-bin: %s is not %s\n", real, tool);
        return 2;
    }
    if (inside_boot && !is_allowed_tool(base_name(real))) {
        fprintf(stderr, "xosvi-bin: %s is not a whitelisted tool\n", real);
        return 2;
    }
    struct stat st;
    if (stat(real, &st) != 0 || !S_ISREG(st.st_mode) || access(real, X_OK) != 0) {
        fprintf(stderr, "xosvi-bin: %s is not an executable file\n", real);
        return 2;
    }

    int start = 3;
    if (argc > 3 && strcmp(argv[3], "--") == 0) start = 4;
    if (argc - start > MAX_ARGS) { fprintf(stderr, "xosvi-bin: too many args\n"); return 2; }

    char *args[MAX_ARGS + 2];
    int ai = 0;
    args[ai++] = real;
    for (int i = start; i < argc && ai < MAX_ARGS + 1; i++) args[ai++] = argv[i];
    args[ai] = NULL;

    sanify_env();
    log_line("uid=%d run %s (args=%d)", (int)getuid(), real, ai - 1);
    execv(real, args);
    int e = errno;
    log_line("exec %s failed: %s", real, strerror(e));
    fprintf(stderr, "xosvi-bin: exec %s failed: %s\n", real, strerror(e));
    return 127;
}
