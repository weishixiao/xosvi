// py_shim.c — 用 dlopen/dlsym 在进程内跑 CPython
//
// 不链接 Python.framework、不需要 Python 头文件：
// 运行时按绝对路径 dlopen，再用 dlsym 取 Py_* 符号。
// 这样既不受 spawn 拦截影响，也不依赖构建期的 framework 路径。

#include "py_shim.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

typedef void  (*fn_Initialize)(void);
typedef int   (*fn_IsInitialized)(void);
typedef int   (*fn_RunSimpleString)(const char *);
typedef int   (*fn_GILStateEnsure)(void);
typedef void  (*fn_GILStateRelease)(int);

static void *g_framework = NULL;
static fn_Initialize g_init = NULL;
static fn_IsInitialized g_isInit = NULL;
static fn_RunSimpleString g_run = NULL;
static fn_GILStateEnsure g_gilEnsure = NULL;
static fn_GILStateRelease g_gilRelease = NULL;

static void seterr(char *err, size_t cap, const char *msg) {
    if (!err || cap == 0) return;
    snprintf(err, cap, "%s", msg ? msg : "");
}

int pyx_ready(void) {
    return g_run != NULL && g_isInit != NULL && g_isInit();
}

// ---------------------------------------------------------------
// fd 级输出捕获（v8.4）
// 进程内跑的代码除了 print，还可能经由 C 扩展 printf / os.write(1, ...)
// 直接写 fd 1/2——这些不经过 sys.stdout，只靠 StringIO 抓不到。
// 做法：执行前把 fd1/fd2 dup2 到临时文件，执行后 fflush(NULL) 再恢复 fd，最后回读追加。
// 顺序必须是：执行 → flush → 恢复 fd → 回读。
// ---------------------------------------------------------------
static int  g_cap_fd = -1, g_cap_saved_out = -1, g_cap_saved_err = -1;
static char g_cap_path[1024];

static void cap_begin(const char *outPath) {
    snprintf(g_cap_path, sizeof g_cap_path, "%s.cap", outPath);
    g_cap_fd = open(g_cap_path, O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (g_cap_fd < 0) return;
    fflush(NULL);
    g_cap_saved_out = dup(STDOUT_FILENO);
    g_cap_saved_err = dup(STDERR_FILENO);
    dup2(g_cap_fd, STDOUT_FILENO);
    dup2(g_cap_fd, STDERR_FILENO);
}

static void cap_end(void) {
    if (g_cap_fd < 0) return;
    fflush(NULL);                    // 缓冲先落盘，再恢复 fd（顺序反过来会丢尾巴）
    if (g_cap_saved_out >= 0) { dup2(g_cap_saved_out, STDOUT_FILENO); close(g_cap_saved_out); g_cap_saved_out = -1; }
    if (g_cap_saved_err >= 0) { dup2(g_cap_saved_err, STDERR_FILENO); close(g_cap_saved_err); g_cap_saved_err = -1; }
    close(g_cap_fd);
    g_cap_fd = -1;
}

static void cap_append(const char *outPath) {
    int fd = open(g_cap_path, O_RDONLY);
    if (fd < 0) return;
    int of = open(outPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (of >= 0) {
        char buf[8192];
        ssize_t n;
        while ((n = read(fd, buf, sizeof buf)) > 0) {
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(of, buf + off, (size_t)(n - off));
                if (w <= 0) break;
                off += w;
            }
        }
        close(of);
    }
    close(fd);
    unlink(g_cap_path);
}

int pyx_init(const char *frameworkPath, const char *home, const char *pythonPath,
             char *err, size_t errCap)
{
    seterr(err, errCap, "");
    if (pyx_ready()) return 0;

    // 1) PYTHONHOME / PYTHONPATH 必须在 Py_Initialize 之前生效：
    //    Py_Initialize 会读环境变量定位 stdlib（encodings 等），
    //    路径不对会直接 fatal "Failed to import encodings module"。
    if (home && home[0]) setenv("PYTHONHOME", home, 1);
    if (pythonPath && pythonPath[0]) setenv("PYTHONPATH", pythonPath, 1);

    // 2) 加载框架
    if (!g_framework) {
        g_framework = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL);
        if (!g_framework) {
            char buf[512];
            const char *e = dlerror();
            snprintf(buf, sizeof buf, "dlopen 失败: %s", e ? e : "(no dlerror)");
            seterr(err, errCap, buf);
            return -1;
        }
    }

    g_init       = (fn_Initialize)dlsym(g_framework, "Py_Initialize");
    g_isInit     = (fn_IsInitialized)dlsym(g_framework, "Py_IsInitialized");
    g_run        = (fn_RunSimpleString)dlsym(g_framework, "PyRun_SimpleString");
    g_gilEnsure  = (fn_GILStateEnsure)dlsym(g_framework, "PyGILState_Ensure");
    g_gilRelease = (fn_GILStateRelease)dlsym(g_framework, "PyGILState_Release");

    if (!g_init || !g_isInit || !g_run || !g_gilEnsure || !g_gilRelease) {
        seterr(err, errCap, "dlsym 失败：Python.framework 缺少 Py_* 入口");
        return -1;
    }

    if (!g_isInit()) {
        g_init();
    }
    if (!g_isInit()) {
        seterr(err, errCap, "Py_Initialize 后 Py_IsInitialized 仍为 0（stdlib 路径可能不对）");
        return -1;
    }
    seterr(err, errCap, "ok");
    return 0;
}

int pyx_run_file(const char *codePath, const char *outPath, const char *envPath,
                 char *err, size_t errCap)
{
    seterr(err, errCap, "");
    if (!pyx_ready()) { seterr(err, errCap, "解释器未初始化"); return -1; }

    // 用文件路径传代码/环境/输出，避免把用户内容拼进字符串字面量（转义地狱）。
    // 缓冲放栈上：static 会被后续调用覆盖（超时放弃后脚本仍在跑时尤其危险）。
    char code[8192];
    snprintf(code, sizeof code,
        "import sys, io, os, json, traceback\n"
        "_code_path = %c%s%c\n"
        "_out_path  = %c%s%c\n"
        "_env_path  = %c%s%c\n"
        "if _env_path:\n"
        "    try:\n"
        "        with open(_env_path, encoding='utf-8') as _ef:\n"
        "            os.environ.update({str(k): str(v) for k, v in json.load(_ef).items()})\n"
        "    except Exception:\n"
        "        pass\n"
        "_buf = io.StringIO()\n"
        "_old_out, _old_err = sys.stdout, sys.stderr\n"
        "sys.stdout = sys.stderr = _buf\n"
        "sys.argv = [_code_path]\n"
        "try:\n"
        "    _src = open(_code_path, encoding='utf-8').read()\n"
        "    exec(compile(_src, '<py.eval>', 'exec'), {'__name__': '__main__', '__file__': _code_path})\n"
        "except BaseException:\n"
        "    traceback.print_exc(file=_buf)\n"
        "finally:\n"
        "    for _s in (_old_out, _old_err):\n"
        "        try: _s.flush()\n"
        "        except Exception: pass\n"
        "    sys.stdout, sys.stderr = _old_out, _old_err\n"
        "    try:\n"
        "        open(_out_path, 'w', encoding='utf-8').write(_buf.getvalue())\n"
        "    except Exception:\n"
        "        pass\n",
        '\'', codePath, '\'', '\'', outPath, '\'', '\'', envPath ? envPath : "", '\'');

    cap_begin(outPath);          // fd1/fd2 → 临时文件（兜住 C 扩展/os.write 的输出）
    int gil = g_gilEnsure();
    int rc = g_run(code);
    g_gilRelease(gil);
    cap_end();                   // flush → 恢复 fd
    cap_append(outPath);         // 恢复之后再回读，追加到 Python 侧输出后面

    if (rc != 0) {
        seterr(err, errCap, "PyRun_SimpleString 返回非 0");
        return rc;
    }
    return 0;
}
