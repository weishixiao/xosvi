/*
 * xosvi-cli —— 命令行客户端，用于在终端里直接和 xosvid（wiki.qaq.xosvi.service）对话。
 *
 *   xosvi-cli ping
 *   xosvi-cli status
 *   xosvi-cli helper <name> <项目目录> [其它参数...] [--dry-run] [--timeout N]
 *   xosvi-cli call build <项目目录> [其它参数...]
 *
 * 输出：守护返回的字段逐行打印；带 stdout 的原样打印在 "--- stdout ---" 之后。
 * 退出码：0 成功（helper 自身退出码非 0 时以它为准）；1 连接失败；2 用法错误。
 */

#define _DARWIN_C_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>

#define SVC_NAME "wiki.qaq.xosvi.service"

typedef xpc_connection_t (*create_mach_fn)(const char *, dispatch_queue_t, uint64_t);

static int g_done = 0;
static xpc_object_t g_reply = NULL;
static int g_error = 0;

static void usage(void) {
    fprintf(stderr,
            "usage:\n"
            "  xosvi-cli ping\n"
            "  xosvi-cli status\n"
            "  xosvi-cli helper <name> <project-dir> [args...] [--dry-run] [--timeout N]\n"
            "  xosvi-cli call <build|install|symbolicate> <project-dir> [args...]\n");
}

static void print_str(const char *key) {
    const char *v = xpc_dictionary_get_string(g_reply, key);
    if (v) printf("%s: %s\n", key, v);
}

static void print_int(const char *key) {
    if (!xpc_dictionary_get_value(g_reply, key)) return;
    printf("%s: %lld\n", key, xpc_dictionary_get_int64(g_reply, key));
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }

    const char *cmd = argv[1];
    const char *helper = NULL;
    int first = 2;

    if (strcmp(cmd, "helper") == 0) {
        if (argc < 4) { fprintf(stderr, "helper <name> <project-dir> ...\n"); return 2; }
        helper = argv[2];
        first = 3;
    } else if (strcmp(cmd, "call") == 0) {
        if (argc < 4) { fprintf(stderr, "call <build|install|symbolicate> <project-dir> ...\n"); return 2; }
        helper = argv[2];
        first = 3;
        cmd = "helper";
    } else if (strcmp(cmd, "ping") != 0 && strcmp(cmd, "status") != 0) {
        fprintf(stderr, "unknown command %s\n", cmd);
        usage();
        return 2;
    }

    int dryrun = 0, timeout = 0;
    xpc_object_t args = xpc_array_create(NULL, 0);
    for (int i = first; i < argc; i++) {
        if (strcmp(argv[i], "--dry-run") == 0) { dryrun = 1; continue; }
        if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) { timeout = atoi(argv[++i]); continue; }
        xpc_array_set_string(args, XPC_ARRAY_APPEND, argv[i]);
    }

    create_mach_fn create = (create_mach_fn)dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!create) { fprintf(stderr, "libxpc missing xpc_connection_create_mach_service\n"); return 1; }

    xpc_connection_t c = create(SVC_NAME, dispatch_get_main_queue(), 0);
    if (!c) { fprintf(stderr, "cannot create connection\n"); return 1; }
    xpc_connection_set_event_handler(c, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
            g_reply = xpc_retain(event);
            g_done = 1;
        } else if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            const char *d = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
            fprintf(stderr, "connection error: %s\n", d ? d : "unknown");
            g_error = 1;
            g_done = 1;
        }
    });
    xpc_connection_resume(c);

    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "command", cmd);
    if (helper) xpc_dictionary_set_string(msg, "name", helper);
    if (xpc_array_get_count(args)) xpc_dictionary_set_value(msg, "args", args);
    if (dryrun) xpc_dictionary_set_bool(msg, "dryrun", true);
    if (timeout > 0) xpc_dictionary_set_int64(msg, "timeout", timeout);
    xpc_connection_send_message_with_reply(c, msg, dispatch_get_main_queue(),
                                          ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
            g_reply = xpc_retain(reply);
        } else {
            const char *d = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            fprintf(stderr, "xpc error: %s\n", d ? d : "unknown");
            g_error = 1;
        }
        g_done = 1;
    });

    int rc = 0;
    /* XPC 的回调在主队列上，主线程空转 sleep 永远等不到：必须跑 runloop。
     * 客户端等待要比守护侧的超时更长 —— 守护到点杀进程组后还要收尸、组回包，
     * 两边时限相同会让客户端先把结论说成「timeout waiting for xosvid」。 */
    CFTimeInterval deadline = CFAbsoluteTimeGetCurrent() + (timeout > 0 ? timeout + 10 : 30);
    while (!g_done && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }
    if (!g_done) { fprintf(stderr, "timeout waiting for xosvid\n"); return 2; }
    if (g_error || !g_reply) { fprintf(stderr, "no reply from xosvid\n"); return 1; }

    print_str("status");
    print_str("error");
    print_str("bootstrap");
    print_str("resolved");
    print_str("dash");
    print_str("helper");
    print_str("peer");
    print_int("pid");
    print_int("uid");
    if (xpc_dictionary_get_value(g_reply, "elapsed_ms"))
        printf("elapsed_ms: %.1f\n", xpc_dictionary_get_double(g_reply, "elapsed_ms"));
    if (xpc_dictionary_get_bool(g_reply, "timed_out")) printf("timed_out: true\n");
    if (xpc_dictionary_get_value(g_reply, "exit_code")) {
        int64_t ec = xpc_dictionary_get_int64(g_reply, "exit_code");
        printf("exit_code: %lld\n", ec);
        if (ec != 0) rc = (int)ec;
    }
    size_t n = 0;
    const char *out = xpc_dictionary_get_data(g_reply, "stdout", &n);
    if (out && n) {
        printf("--- stdout ---\n");
        fwrite(out, 1, n, stdout);
        if (out[n - 1] != '\n') fputc('\n', stdout);
    }
    if (xpc_dictionary_get_string(g_reply, "error")) rc = rc ? rc : 1;
    fflush(stdout);
    return rc;
}
