// xpc-reply-lifetime.c —— XPC 回复对象存活期的最小复现（诊断工具，不进 deb）
//
// 背景：Sources/XosviMCP/XosviXPC.swift 曾经把 send_message_with_reply 的回调参数
//       （xpc_object_t）存到 block 外面，等主线程 wait 回来再 xpc_dictionary_get_*。
//       reply 对象只在这次块调用期间有效，块一返回 libxpc 就回收 → 块外读是
//       use-after-free。App 里的表现是 EXC_GUARD / namespace LIBXPC /
//       XPC_EXIT_REASON_FAULT（控制台「注入 → 闪退」的现场），本工具里是 SIGBUS。
//
// 编译运行（设备上，clang 与 ldid 已在 PATH）：
//   clang -arch arm64e -o /tmp/xpc-reply-lifetime tools/xpc-reply-lifetime.c
//   ldid -S /tmp/xpc-reply-lifetime
//   /tmp/xpc-reply-lifetime bad     # 块外读 → 立刻 Bus error: 10
//   /tmp/xpc-reply-lifetime good    # 块内解析 → 正常跑完
//
// 两种模式都必须连到一个**会回包**的 MachService 才触发：
// 默认 wiki.qaq.xosvi.service（com.xosvi.daemon 的守护），第二个参数可换。

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

// 公共头把 create_mach_service 标成 iOS 不可用；运行时一直在，用 dlsym 取（同 App 的做法）。
typedef xpc_connection_t (*create_fn)(const char *, dispatch_queue_t, uint64_t);

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "good";
    const char *svc = argc > 2 ? argv[2] : "wiki.qaq.xosvi.service";
    create_fn create = (create_fn)dlsym((void *)-2, "xpc_connection_create_mach_service");
    if (!create) {
        fprintf(stderr, "no xpc_connection_create_mach_service\n");
        return 2;
    }

    xpc_connection_t c = create(svc, NULL, 0);
    if (!c) {
        fprintf(stderr, "connection NULL\n");
        return 2;
    }
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
    xpc_connection_resume(c);

    __block xpc_object_t raw = NULL;
    __block int exitCode = -1;
    static char goodBuf[128];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, "command", "status");

    xpc_connection_send_message_with_reply(c, msg, NULL, ^(xpc_object_t reply) {
        if (strcmp(mode, "bad") == 0) {
            raw = reply;                 // 只存指针，块里不读 —— 错误写法
        } else {
            const char *st = xpc_dictionary_get_string(reply, "status");
            snprintf(goodBuf, sizeof goodBuf, "%s", st ? st : "(no status)");
            exitCode = (int)xpc_dictionary_get_int64(reply, "uid");   // 块内读完 —— 正确写法
        }
        dispatch_semaphore_signal(sem);
    });

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10ll * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "timeout\n");
        xpc_connection_cancel(c);
        return 3;
    }
    xpc_connection_cancel(c);

    if (raw) {
        // 块早就返回了；这里读它是 use-after-free。
        const char *status = xpc_dictionary_get_string(raw, "status");
        printf("status=%s\n", status ? status : "(null)");
    } else {
        printf("status=%s uid=%d (parsed inside the reply block)\n", goodBuf, exitCode);
    }
    return 0;
}
