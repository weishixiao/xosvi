/*
 * xosvid —— Xosvi 特权守护进程
 *
 * 职责：以 root 执行白名单 helper（xosvi-build / xosvi-install / xosvi-symbolicate）。
 * 历史：
 *   v0  rootd.sh：1777 目录文件轮询（.cmd/.out/.status）—— 任何 mobile 进程都能投递
 *       root 命令；Shell 主循环 fork 风暴打满 launchd 配额被 SIGKILL。
 *   v1  UDS + RUN 跑任意脚本 —— 仍是「无鉴权的 root 执行」。
 *   v2（当前）：只有 XPC MachService，只认白名单 helper，没有任何执行任意脚本的入口。
 *
 * 传输：XPC MachService wiki.qaq.xosvi.service（launchd 按需拉起）。
 *   客户端：项目 App（wiki.qaq.xosvi）与命令行 xosvi-cli。
 *   不提供 Unix 域套接字：iOS 沙盒下每个进程的 /var/tmp 是各自的私有视图，
 *   root 守护 bind 出来的 socket 客户端根本看不到（实测：同进程 stat 可见、
 *   换一个进程 ENOENT）。XPC 由 launchd 转接，不存在这个问题。
 *
 * 请求（xpc 字典）：
 *   command = "ping" | "status" | "helper"
 *   name    = helper 名（xosvi-build 等，可带可不带 xosvi- 前缀）
 *   args    = 字符串数组；首项为项目目录
 *   dryrun  = bool；timeout = 秒
 * 响应：status / error / resolved / bootstrap / pid / uid / exit_code /
 *       timed_out / elapsed_ms / stdout
 *
 * 路径解析（roothide 的核心坑，见 find_bootstrap）：
 *   不同进程看到的「根」不同 —— App 侧是 AppGroup 里的 .jbroot-XXXX 共享视图，
 *   launchd 拉起的 root 进程可能是真根（+ libroot）。任何写死 /var/jb 的做法
 *   都会在另一侧 ENOENT。这里按 env → libroot → 可执行路径 → 扫描 → 真根 逐个实测，
 *   探测目标统一是 <prefix>/usr/bin/dash（bootstrap 内必有，且与 helper 同树）。
 *
 * 构建（tools/build-daemon.sh 调）：
 *   clang -arch arm64e -arch arm64 -O2 -Wall -o xosvid tools/xosvid.c -framework Foundation
 * 签名：ldid -S<entitlements>（platform-application / no-sandbox / XPC 服务白名单）
 */

#define _DARWIN_C_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <dirent.h>
#include <limits.h>
#include <fcntl.h>
#include <time.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>

#define SVC_NAME        "wiki.qaq.xosvi.service"
#define HELPER_DIR      "/usr/libexec/xosvi"
#define DEFAULT_TIMEOUT 300
#define MAX_STDOUT      (4u * 1024 * 1024)
#define MAX_ARGS        64

/* ---------------- bootstrap 路径解析 ---------------- */

typedef int (*rootfs_fn)(char *, size_t);

/* roothide 的 libroot 导出 rootfs_get_path；dlsym 取，缺失即 NULL。 */
static rootfs_fn g_rootfs;

static const char *env_jbroot(void) {
    const char *v = getenv("XOSVI_JBROOT");
    return (v && v[0] == '/') ? v : "";
}

static int probe_prefix(const char *prefix) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/usr/bin/dash", prefix);
    return access(p, X_OK) == 0;
}

/* 从可执行路径截出 /.jbroot-XXXX（roothide）；rootless/真根下返回 0。 */
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

/* prefix 为拼在 /usr/... 前面的那段（真根时为空串），how 记录凭据。 */
static int find_bootstrap(char *prefix, size_t cap, char *how, size_t howcap) {
    if (env_jbroot()[0] && probe_prefix(env_jbroot())) {
        snprintf(prefix, cap, "%s", env_jbroot());
        snprintf(how, howcap, "env");
        return 1;
    }
    if (g_rootfs) {
        char root[PATH_MAX];
        if (g_rootfs(root, sizeof root) == 0 && root[0]) {
            const char *pre = strcmp(root, "/") ? root : "";
            if (probe_prefix(pre)) {
                snprintf(prefix, cap, "%s", pre);
                snprintf(how, howcap, "libroot");
                return 1;
            }
        }
    }
    char exe[PATH_MAX];
    if (exe_jbroot(exe, sizeof exe) && probe_prefix(exe)) {
        snprintf(prefix, cap, "%s", exe);
        snprintf(how, howcap, "exe");
        return 1;
    }
    const char *bases[] = { "/private/var/containers/Bundle/Application",
                            "/var/containers/Bundle/Application", NULL };
    for (int i = 0; bases[i]; i++) {
        char cand[PATH_MAX];
        if (scan_base(bases[i], cand, sizeof cand)) {
            snprintf(prefix, cap, "%s", cand);
            snprintf(how, howcap, "scan:%s", bases[i]);
            return 1;
        }
    }
    if (probe_prefix("")) {                        /* 真根 */
        prefix[0] = '\0';
        snprintf(how, howcap, "realroot");
        return 1;
    }
    prefix[0] = '\0';
    snprintf(how, howcap, "none");
    return 0;
}

/* ---------------- 日志（launchd 把 stderr 写进 <bootstrap>/var/log/xosvid.log） ---------------- */

static int g_log_fd = -1;
/* launchd 的 StandardErrorPath 与这里自己开的日志文件实测指向同一个 inode，
 * 两边都写会让每条日志出现两遍（2026-11 排障时日志里每条都重复）。开日志时用
 * fstat 比一下，相同就只写一次。 */
static int g_log_same_as_stderr = 0;

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...) {
    /* v0.2.5：每行前缀本地时间。此前日志无时间戳，无法与崩溃报告/用户反馈的时刻
     * 对齐（排 07:55 那次卡死时只能靠世代顺序猜）。格式固定 24 字节，
     * "%Y-%m-%d %H:%M:%S " —— 用 localtime_r 而不是 ctime，避免换行与静态缓冲。 */
    char stamp[32];
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    struct tm tmv;
    localtime_r(&now.tv_sec, &tmv);
    size_t sl = strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tmv);

    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof line - 4) n = (int)sizeof line - 4;
    line[n] = '\n';
    line[n + 1] = '\0';
    if (g_log_fd >= 0) {
        if (sl) { ssize_t w = write(g_log_fd, stamp, sl); (void)w; }
        ssize_t w = write(g_log_fd, " ", 1); (void)w;
        w = write(g_log_fd, line, (size_t)n + 1);
        (void)w;
    }
    if (!g_log_same_as_stderr) {
        if (sl) { ssize_t w = write(STDERR_FILENO, stamp, sl); (void)w; }
        ssize_t w = write(STDERR_FILENO, " ", 1); (void)w;
        ssize_t w2 = write(STDERR_FILENO, line, (size_t)n + 1);
        (void)w2;
    }
}

/* ---------------- 请求模型 ---------------- */

typedef struct {
    char command[32];
    char name[64];
    char **args;
    int argc;
    int dryrun;
    int timeout;
    char peer[128];
} request_t;

static void request_free(request_t *r) {
    if (r->args) {
        for (int i = 0; i < r->argc; i++) free(r->args[i]);
        free(r->args);
        r->args = NULL;
    }
    r->argc = 0;
}

/* 把请求参数压成一行可读文本：换行/制表等控制字符换空格，过长截断。
 * 排查「App 卡在哪个工具」靠的就是这一行（旧日志只有 argc，定位不了）。 */
static void log_args(const request_t *r, char *out, size_t cap) {
    size_t off = 0;
    if (!r->argc) { snprintf(out, cap, "[]"); return; }
    int m = snprintf(out, cap, "[");
    off = (m > 0 && (size_t)m < cap) ? (size_t)m : cap - 1;
    for (int i = 0; i < r->argc && off + 4 < cap; i++) {
        const char *a = r->args[i] ? r->args[i] : "";
        m = snprintf(out + off, cap - off, "%s\"", i ? " " : "");
        if (m < 0) break;
        off += (size_t)m;
        /* 每个参数最多 160 字符，多出来的用 ... 表示（一条 shell 脚本可能很长） */
        size_t used = 0;
        for (const char *p = a; *p && off + 4 < cap; p++) {
            if (used >= 160) { memcpy(out + off, "...", 3); off += 3; break; }
            char c = *p;
            if (c == '\n' || c == '\r' || c == '\t') c = ' ';
            out[off++] = c;
            used++;
        }
        out[off++] = '"';
    }
    if (off + 2 < cap) out[off++] = ']';
    out[off] = '\0';
}

/* helper 白名单，与 deb 里 /usr/libexec/xosvi/ 下的可执行文件一一对应。 */
static const char *kHelpers[] = { "xosvi-build", "xosvi-install", "xosvi-symbolicate", "xosvi-bin", NULL };

/* "build" / "xosvi-build" / "xosvi/xosvi-build" 归一为白名单项，其它返回 NULL。 */
static const char *normalize_helper(const char *name) {
    if (!name || !name[0]) return NULL;
    const char *base = name;
    const char *slash = strrchr(name, '/');
    if (slash && slash[1]) base = slash + 1;
    for (int i = 0; kHelpers[i]; i++) if (strcmp(base, kHelpers[i]) == 0) return kHelpers[i];
    char buf[64];
    snprintf(buf, sizeof buf, "xosvi-%s", base);
    for (int i = 0; kHelpers[i]; i++) if (strcmp(buf, kHelpers[i]) == 0) return kHelpers[i];
    return NULL;
}

/* ---------------- 执行 helper ---------------- */

typedef struct {
    int exit_code;
    int timed_out;
    int truncated;
    char *out;
    size_t outlen;
} result_t;

/* fork + 双管道跑 helper；到 timeout 仍在跑就 SIGKILL 整个进程组。
 * stdout/stderr 合并进 res->out（顺序按写出顺序，够用且便于排错）。
 *
 * 三条实测踩过的坑（v0.2.4 修）：
 *   1) 输出达到 MAX_STDOUT 就跳出循环会让子进程继续写满管道而永久阻塞，
 *      紧接着的阻塞 waitpid 就是「4MB 死锁」——现在跳出来先杀掉整组。
 *   2) 父进程 SIGPIPE 是 SIG_IGN，子进程 exec 后沿用，helper 写管道失败只会得到
 *      EPIPE 不肯退出；子进程里恢复 SIG_DFL。
 *   3) waitpid 一律带 WNOHANG + 超时，绝不做无上限的阻塞等待。 */
static void run_helper(char *const argv[], int argc_unused, int timeout, result_t *res) {
    (void)argc_unused;
    int outp[2], errp[2];
    res->exit_code = -1;
    res->timed_out = 0;
    res->truncated = 0;
    res->out = NULL;
    res->outlen = 0;
    if (pipe(outp) != 0) {
        logmsg("xosvid: FATAL pipe(stdout) failed: %s", strerror(errno));
        return;
    }
    if (pipe(errp) != 0) {
        logmsg("xosvid: FATAL pipe(stderr) failed: %s", strerror(errno));
        close(outp[0]); close(outp[1]);
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        logmsg("xosvid: FATAL fork failed: %s", strerror(errno));
        close(outp[0]); close(outp[1]); close(errp[0]); close(errp[1]);
        return;
    }
    if (pid == 0) {
        setpgid(0, 0);
        signal(SIGPIPE, SIG_DFL);
        dup2(outp[1], STDOUT_FILENO);
        dup2(errp[1], STDERR_FILENO);
        close(outp[0]); close(outp[1]); close(errp[0]); close(errp[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); if (devnull > 2) close(devnull); }
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
        execv(argv[0], argv);
        fprintf(stderr, "exec %s failed: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    setpgid(pid, pid);
    close(outp[1]);
    close(errp[1]);

    size_t cap = 64 * 1024, len = 0;
    char *buf = malloc(cap);
    int fds[2] = { outp[0], errp[0] };
    int open_fds = 2;
    int limit = timeout > 0 ? timeout : DEFAULT_TIMEOUT;
    time_t deadline = time(NULL) + limit;
    int killed = 0;

    while (open_fds > 0) {
        if (len >= MAX_STDOUT) {                 /* 输出超上限：停收并杀掉，别再等它写完 */
            res->truncated = 1;
            if (!killed) { kill(-pid, SIGKILL); killed = 1; }
            break;
        }
        if (!killed && time(NULL) > deadline) {
            kill(-pid, SIGKILL);
            res->timed_out = 1;
            killed = 1;
            break;
        }
        fd_set rs;
        FD_ZERO(&rs);
        int mx = -1;
        for (int i = 0; i < 2; i++) {
            if (fds[i] >= 0) { FD_SET(fds[i], &rs); if (fds[i] > mx) mx = fds[i]; }
        }
        if (mx < 0) break;
        struct timeval tv = { 1, 0 };
        int sel = select(mx + 1, &rs, NULL, NULL, &tv);
        if (sel < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (sel == 0) continue;
        for (int i = 0; i < 2; i++) {
            if (fds[i] < 0 || !FD_ISSET(fds[i], &rs)) continue;
            char tmp[16384];
            ssize_t n = read(fds[i], tmp, sizeof tmp);
            if (n <= 0) { close(fds[i]); fds[i] = -1; open_fds--; continue; }
            if (len + (size_t)n > MAX_STDOUT) n = (ssize_t)(MAX_STDOUT - len);
            if (len + (size_t)n > cap) {
                size_t ncap = cap * 2;
                while (ncap < len + (size_t)n) ncap *= 2;
                char *nb = realloc(buf, ncap);
                if (!nb) break;
                buf = nb;
                cap = ncap;
            }
            memcpy(buf + len, tmp, (size_t)n);
            len += (size_t)n;
        }
    }
    for (int i = 0; i < 2; i++) if (fds[i] >= 0) close(fds[i]);

    /* 有上限地收尸：最多再等 5 秒，仍在就强杀整组；绝不死等在 waitpid 上。 */
    int status = 0;
    int reaped = 0;
    for (int i = 0; i < 50; i++) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) { reaped = 1; break; }
        if (w < 0 && errno != EINTR) { reaped = 1; status = 0; break; }
        struct timespec ts = { 0, 100 * 1000 * 1000 };
        nanosleep(&ts, NULL);
        if (i == 20 && !killed) { kill(-pid, SIGKILL); killed = 1; res->timed_out = 1; }
    }
    if (!reaped) { kill(-pid, SIGKILL); res->timed_out = 1; }
    if (WIFEXITED(status)) res->exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) res->exit_code = 128 + WTERMSIG(status);
    if (!buf) { buf = strdup(""); len = 0; }
    res->out = buf;
    res->outlen = len;
}

/* ---------------- 客户端校验 ---------------- */

/* 只有带 wiki.qaq.xosvi.client entitlement 的客户端能发请求：主 App、xosvi-cli。
 * 不做这道校验的话，任何 App 都能借 root 守护跑 helper。 */
#define CLIENT_ENT "wiki.qaq.xosvi.client"

static int peer_allowed(xpc_connection_t peer) {
    static int (*has_ent)(xpc_connection_t, const char *);
    if (!has_ent) has_ent = (int (*)(xpc_connection_t, const char *))
        dlsym(RTLD_DEFAULT, "xpc_connection_has_bool_entitlement");
    if (!has_ent) {
        /* 取不到校验函数时按「有」处理：这里只为挡普通 App，不承担鉴权。 */
        logmsg("xosvid: WARN xpc_connection_has_bool_entitlement unavailable");
        return 1;
    }
    return has_ent(peer, CLIENT_ENT) != 0;
}

/* ---------------- 处理一条请求 ---------------- */

/* helper 并发上限：客户端超时重试时会新建连接重发（老 App 每 ~40s 一次），
 * 不设限会让一堆长任务同时压在守护里，反过来把 status/ping 也拖慢。 */
#define MAX_CONCURRENT_HELPERS 3
static int g_running_helpers = 0;

static int helper_slot_acquire(void) {
    int cur = __atomic_load_n(&g_running_helpers, __ATOMIC_RELAXED);
    for (;;) {
        if (cur >= MAX_CONCURRENT_HELPERS) return 0;
        if (__atomic_compare_exchange_n(&g_running_helpers, &cur, cur + 1, 0,
                                        __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
            return 1;
    }
}

static void helper_slot_release(void) {
    __atomic_fetch_sub(&g_running_helpers, 1, __ATOMIC_ACQ_REL);
}

/* 慢路径：跑 helper 并填回复。在并发队列上执行，绝不占用监听队列。 */
static void run_helper_request(const request_t *r, xpc_object_t reply) {
    char prefix[PATH_MAX], how[128];
    if (!find_bootstrap(prefix, sizeof prefix, how, sizeof how)) {
        xpc_dictionary_set_string(reply, "error", "no bootstrap (dash not found)");
        return;
    }
    const char *helper = normalize_helper(r->name);
    if (!helper) {
        xpc_dictionary_set_string(reply, "error",
                                  "helper not allowed (xosvi-build/xosvi-install/xosvi-symbolicate/xosvi-bin)");
        return;
    }
    char helper_path[PATH_MAX];
    snprintf(helper_path, sizeof helper_path, "%s%s/%s", prefix, HELPER_DIR, helper);
    if (access(helper_path, X_OK) != 0) {
        xpc_dictionary_set_string(reply, "error", "helper missing");
        xpc_dictionary_set_string(reply, "resolved", helper_path);
        return;
    }
    if (!helper_slot_acquire()) {
        /* v0.2.5：这一条以前完全不打日志，日志里表现为「请求数 > 完成数」却查不出原因
         * （实测 4 个并发任务只出现 3 条 done）。被拒的请求也必须留下可定位的一行。 */
        int running = (int)__atomic_load_n(&g_running_helpers, __ATOMIC_RELAXED);
        logmsg("xosvid: reject helper=%s busy=1 running=%d args=%s", helper, running,
               r->args && r->argc && r->args[0] ? r->args[0] : "-");
        xpc_dictionary_set_string(reply, "error",
                                  "too many concurrent helpers (max 3); retry when the running one finishes");
        xpc_dictionary_set_string(reply, "busy", "1");
        xpc_dictionary_set_int64(reply, "running_helpers", (int64_t)running);
        return;
    }

    char *argv[MAX_ARGS + 8];
    int n = 0;
    argv[n++] = helper_path;
    for (int i = 0; i < r->argc && n < MAX_ARGS; i++) argv[n++] = r->args[i];
    char tbuf[16];
    if (r->timeout > 0) {
        snprintf(tbuf, sizeof tbuf, "%d", r->timeout);
        argv[n++] = "--timeout";
        argv[n++] = tbuf;
    }
    if (r->dryrun) argv[n++] = "--dry-run";
    argv[n] = NULL;

    result_t res;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    run_helper(argv, n - 1, r->timeout, &res);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    helper_slot_release();

    if (res.exit_code < 0) {
        /* 只有守护自身失败（pipe/fork/未收到退出状态）才会是负值：以前会回 exit_code=-1
         * 却仍标 status=OK，App 侧当成「跑完但没输出」。改成明确错误。helper 真的退出
         * （含 exec 失败的 127）不受影响，仍走正常回包。 */
        logmsg("xosvid: helper=%s failed to start (exit_code=%d timed_out=%d)", helper,
               res.exit_code, res.timed_out);
        free(res.out);
        xpc_dictionary_set_string(reply, "error", "helper failed to start (see xosvid.log)");
        xpc_dictionary_set_bool(reply, "timed_out", res.timed_out ? true : false);
        xpc_dictionary_set_int64(reply, "running_helpers",
                                 (int64_t)__atomic_load_n(&g_running_helpers, __ATOMIC_RELAXED));
        return;
    }

    double ms = ((double)(t1.tv_sec - t0.tv_sec) * 1000.0) +
                ((double)(t1.tv_nsec - t0.tv_nsec) / 1e6);
    logmsg("xosvid: done helper=%s exit=%d timed_out=%d truncated=%d bytes=%zu %.0fms",
           helper, res.exit_code, res.timed_out, res.truncated, res.outlen, ms);

    xpc_dictionary_set_string(reply, "status", "OK");
    xpc_dictionary_set_string(reply, "resolved", helper_path);
    xpc_dictionary_set_int64(reply, "pid", (int64_t)getpid());
    xpc_dictionary_set_int64(reply, "uid", (int64_t)getuid());
    xpc_dictionary_set_int64(reply, "exit_code", res.exit_code);
    if (res.timed_out) xpc_dictionary_set_bool(reply, "timed_out", true);
    if (res.truncated) xpc_dictionary_set_bool(reply, "truncated", true);
    xpc_dictionary_set_double(reply, "elapsed_ms", ms);
    if (res.out) xpc_dictionary_set_data(reply, "stdout", res.out, res.outlen);
    free(res.out);
}

/* 快路径：ping/status 立即回；helper 交给并发队列，监听队列不再被长任务堵住
 * （v0.2.4 前 helper 在监听串行队列上同步跑，最长 300s，期间 status/ping 全部无响应，
 *  客户端的「慢」与「超时重试」都是这么来的）。 */
static void handle(request_t *r, xpc_object_t reply) {
    if (strcmp(r->command, "ping") == 0) {
        xpc_dictionary_set_string(reply, "status", "OK");
        return;
    }

    char prefix[PATH_MAX], how[128];
    if (!find_bootstrap(prefix, sizeof prefix, how, sizeof how)) {
        xpc_dictionary_set_string(reply, "error", "no bootstrap (dash not found)");
        return;
    }
    xpc_dictionary_set_string(reply, "bootstrap", how);

    if (strcmp(r->command, "status") == 0) {
        char helper[PATH_MAX], dash[PATH_MAX];
        snprintf(helper, sizeof helper, "%s%s/xosvi-build", prefix, HELPER_DIR);
        snprintf(dash, sizeof dash, "%s/usr/bin/dash", prefix);
        xpc_dictionary_set_string(reply, "status", "OK");
        xpc_dictionary_set_string(reply, "resolved", helper);
        xpc_dictionary_set_int64(reply, "pid", (int64_t)getpid());
        xpc_dictionary_set_int64(reply, "uid", (int64_t)getuid());
        xpc_dictionary_set_string(reply, "dash", access(dash, X_OK) == 0 ? "ok" : "missing");
        xpc_dictionary_set_string(reply, "helper",
                                  access(helper, X_OK) == 0 ? "ok" : "missing");
        xpc_dictionary_set_string(reply, "peer", r->peer);
        xpc_dictionary_set_int64(reply, "running_helpers",
                                 (int64_t)__atomic_load_n(&g_running_helpers, __ATOMIC_RELAXED));
        return;
    }

    if (strcmp(r->command, "helper") != 0) {
        xpc_dictionary_set_string(reply, "error", "unknown command (ping/status/helper)");
        return;
    }
    if (r->argc < 1) {
        xpc_dictionary_set_string(reply, "error", "first argument must be the project dir");
        return;
    }
    run_helper_request(r, reply);
}

/* ---------------- XPC ---------------- */

typedef xpc_connection_t (*create_mach_fn)(const char *, dispatch_queue_t, uint64_t);
typedef pid_t (*pid_fn)(xpc_connection_t);

/* 公共头把 xpc_connection_create_mach_service / _get_pid 标成 iOS 不可用，
 * 运行时符号一直都在；用 dlsym 取，避免与别名的可用性检查纠缠。 */
static create_mach_fn g_create_mach;
static pid_fn g_get_pid;

static void peer_desc(xpc_connection_t peer, char *out, size_t cap) {
    pid_t pid = g_get_pid ? g_get_pid(peer) : 0;
    snprintf(out, cap, "xpc uid=%d gid=%d pid=%d",
             (int)xpc_connection_get_euid(peer), (int)xpc_connection_get_egid(peer), (int)pid);
}

static request_t *request_from_xpc(xpc_object_t msg, const char *peer) {
    request_t *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    const char *cmd = xpc_dictionary_get_string(msg, "command");
    snprintf(r->command, sizeof r->command, "%s", cmd ? cmd : "status");
    const char *name = xpc_dictionary_get_string(msg, "name");
    if (name) snprintf(r->name, sizeof r->name, "%s", name);
    r->dryrun = xpc_dictionary_get_bool(msg, "dryrun");
    r->timeout = (int)xpc_dictionary_get_int64(msg, "timeout");
    snprintf(r->peer, sizeof r->peer, "%s", peer);
    xpc_object_t args = xpc_dictionary_get_value(msg, "args");
    if (args && xpc_get_type(args) == XPC_TYPE_ARRAY) {
        size_t c = xpc_array_get_count(args);
        if (c > MAX_ARGS) c = MAX_ARGS;
        r->args = calloc(c + 1, sizeof(char *));
        if (r->args) {
            for (size_t i = 0; i < c; i++) {
                const char *s = xpc_array_get_string(args, i);
                r->args[r->argc++] = strdup(s ? s : "");
            }
        }
    }
    return r;
}

/* 一条连接上的请求：快路径同步回，helper 丢到并发队列，绝不占用监听队列。
 * 连接的生命周期交给 libxpc 与客户端（客户端每回一条就 cancel）：这里既不 retain
 * 也不 cancel —— 实测在 `send_message` 之后立刻 `cancel` 会把尚未投递的回复一起丢掉，
 * 客户端只看到「Connection interrupted」。 */
static dispatch_queue_t g_helper_queue;

static void xpc_handle(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
        char peerdesc[128];
        peer_desc(peer, peerdesc, sizeof peerdesc);
        request_t *r = request_from_xpc(event, peerdesc);
        if (!r) return;
        xpc_object_t reply = xpc_dictionary_create_reply(event);
        if (!reply) { request_free(r); free(r); return; }

        char argbuf[600];
        log_args(r, argbuf, sizeof argbuf);
        logmsg("xosvid: %s command=%s name=%s timeout=%d args=%s", peerdesc, r->command,
               r->name[0] ? r->name : "-", r->timeout, argbuf);

        if (strcmp(r->command, "helper") == 0) {
            /* 长任务：同一连接上回包，但不占监听队列 */
            request_t *rr = r;
            dispatch_async(g_helper_queue, ^{
                handle(rr, reply);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
                request_free(rr);
                free(rr);
            });
            return;
        }

        handle(r, reply);
        xpc_connection_send_message(peer, reply);
        xpc_release(reply);
        request_free(r);
        free(r);
    });
    xpc_connection_resume(peer);
}

/* ---------------- 自退出时钟 ---------------- */

/* v0.2.3：把 pid 写到 <bootstrap>/var/run/xosvid.pid，App 侧的 RootdTool.daemonPID()
 * 就读得到（它按 kill(pid,0) 校验，死 pid 不会被当成活着）。守护是 launchd 拉起的，
 * 以前不写这个文件，daemon_alive 只能靠 XPC 兜底；写出来两边判据才一致。 */
static void write_pidfile(const char *prefix) {
    char dir[PATH_MAX], path[PATH_MAX], buf[64];
    snprintf(dir, sizeof dir, "%s/var/run", prefix);
    mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/xosvid.pid", dir);
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    int n = snprintf(buf, sizeof buf, "%d\n", (int)getpid());
    if (n > 0) (void)!write(fd, buf, (size_t)n);
    close(fd);
}

static char g_pidfile[PATH_MAX];

static void remove_pidfile(void) {
    if (g_pidfile[0]) unlink(g_pidfile);
}

/* 连续 IDLE_SECS 没有请求就退出（launchd 下次连接会重新拉起）。
 * 必须重置，否则「键盘没电了但守护一直挂着」会占着 root 进程不放。
 * XOSVID_IDLE_SECS 可覆盖（排障时缩小到几秒即可验证「有 helper 时不退出」）。 */
static int kIdleSecs = 900;

static void arm_idle_timer(dispatch_source_t t) {
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)kIdleSecs * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER, 5ull * NSEC_PER_SEC);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0) {
            printf("usage: xosvid\n"
                   "  XPC MachService %s (started by launchd).\n", SVC_NAME);
            return 0;
        }
    }

    umask(022);
    chdir("/");
    signal(SIGPIPE, SIG_IGN);

    const char *idle_env = getenv("XOSVID_IDLE_SECS");
    if (idle_env && idle_env[0]) {
        int v = atoi(idle_env);
        if (v >= 1) kIdleSecs = v;
    }

    g_create_mach = (create_mach_fn)dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    g_get_pid = (pid_fn)dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
    g_rootfs = (rootfs_fn)dlsym(RTLD_DEFAULT, "rootfs_get_path");

    char prefix[PATH_MAX], how[128];
    int have = find_bootstrap(prefix, sizeof prefix, how, sizeof how);
    /* 日志落 <bootstrap>/var/log/xosvid.log：launchd 的 StandardErrorPath 在
     * roothide 上落点随视图而定，自己再开一份才稳。 */
    char logpath[PATH_MAX];
    snprintf(logpath, sizeof logpath, "%s/var/log/xosvid.log", prefix);
    if (prefix[0]) {
        char logdir[PATH_MAX];
        snprintf(logdir, sizeof logdir, "%s/var/log", prefix);
        mkdir(logdir, 0755);
    }
    g_log_fd = open(logpath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (g_log_fd >= 0) {
        /* launchd 的 StandardErrorPath 往往就是同一个文件：只有一个 inode 时别再写第二遍 */
        struct stat a, b;
        if (fstat(g_log_fd, &a) == 0 && fstat(STDERR_FILENO, &b) == 0 &&
            a.st_dev == b.st_dev && a.st_ino == b.st_ino)
            g_log_same_as_stderr = 1;
    }
    logmsg("xosvid: start pid=%d euid=%d bootstrap='%s' via=%s libroot=%s log=%s",
           (int)getpid(), (int)geteuid(), prefix, how,
           g_rootfs ? "present" : "missing", g_log_fd >= 0 ? logpath : "(stderr only)");
    if (!have) logmsg("xosvid: WARN bootstrap not found; helpers will fail");
    if (geteuid() != 0) logmsg("xosvid: WARN not root (euid=%d)", (int)geteuid());
    if (have) {
        snprintf(g_pidfile, sizeof g_pidfile, "%s/var/run/xosvid.pid", prefix);
        write_pidfile(prefix);
        atexit(remove_pidfile);
        logmsg("xosvid: pidfile %s", g_pidfile);
    }
    if (!g_create_mach) {
        logmsg("xosvid: FATAL xpc_connection_create_mach_service missing");
        return 1;
    }

    dispatch_queue_t q = dispatch_queue_create("wiki.qaq.xosvid", DISPATCH_QUEUE_SERIAL);
    g_helper_queue = dispatch_queue_create("wiki.qaq.xosvid.helpers",
                                           DISPATCH_QUEUE_CONCURRENT);
    dispatch_source_t idle = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_event_handler(idle, ^{
        /* v0.2.5：还有 helper 在跑就绝不自退 —— exit(0) 会把正在执行的命令连同客户端
         * 连接一起砍掉，App 侧只看到「连接中断」而不知道原因。续一个周期再检查。 */
        int running = (int)__atomic_load_n(&g_running_helpers, __ATOMIC_RELAXED);
        if (running > 0) {
            logmsg("xosvid: idle %ds but %d helper(s) still running; stay alive", kIdleSecs, running);
            arm_idle_timer(idle);
            return;
        }
        logmsg("xosvid: idle %ds, exiting", kIdleSecs);
        remove_pidfile();   /* dispatch_main 不走 atexit，这里手动清 */
        exit(0);
    });
    arm_idle_timer(idle);
    dispatch_resume(idle);

    xpc_connection_t listener = g_create_mach(SVC_NAME, q, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) {
        logmsg("xosvid: FATAL listener unavailable for %s", SVC_NAME);
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)event;
        arm_idle_timer(idle);
        if (!peer_allowed(peer)) {
            char d[128];
            peer_desc(peer, d, sizeof d);
            logmsg("xosvid: peer rejected %s (no %s)", d, CLIENT_ENT);
            xpc_connection_cancel(peer);
            return;
        }
        xpc_handle(peer);
    });
    xpc_connection_resume(listener);
    logmsg("xosvid: listening on %s", SVC_NAME);

    dispatch_main();
    return 0;
}
