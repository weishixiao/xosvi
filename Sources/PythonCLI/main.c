// Xosvi 原生 Python CLI (v8.3 / P0)
// 嵌入式 CPython 入口：链接 App 内置 Python.framework，PYTHONHOME 指向 App bundle/python/。
// 用法：python3 [-c code | -m module | script.py | 无参(打印版本/帮助)]
//
// v8.3 关键修正（P0）：
//   旧顺序是「dup 保存 → dup2 重定向 → Py_Initialize → **立刻恢复 fd** → PyRun」。
//   fd 在 PyRun 之前就被恢复，Python 的缓冲输出最终落到真 stdout 之外，
//   上层 BuildRunner 读到的就是空。现在改为：
//     1) 一开始就把 fd1/2 重定向到临时捕获文件；
//     2) Py_Initialize；
//     3) PyRun（-c / -m / 脚本）；
//     4) **先 flush Python 层，再 flush C 层**；
//     5) Py_Finalize（让它自己的缓冲也落盘）；
//     6) 最后才恢复 fd，并把捕获内容写到真 stdout。
//   诊断输出默认静音（设 PYCLI_DEBUG / TROLL_PY_DIAG 才开），避免污染 stdout。
#include <Python.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>

// ── 诊断：仅显式开启时才写，绝不混进 stdout ────────────────────────────────
static int g_debug = -1;
static void diag(const char *msg) {
    if (g_debug < 0) g_debug = (getenv("PYCLI_DEBUG") || getenv("TROLL_PY_DIAG")) ? 1 : 0;
    if (!g_debug) return;
    const char *envd = getenv("TROLL_PY_DIAG");
    if (envd && envd[0]) {
        FILE *f = fopen(envd, "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    }
    fprintf(stderr, "[py] %s\n", msg);
}

// ── 输出捕获 ────────────────────────────────────────────────────────────────
static char g_cap_path[PATH_MAX];
static int  g_cap_fd = -1, g_saved_out = -1, g_saved_err = -1;

static int cap_begin(void) {
    const char *cands[3] = { getenv("TMPDIR"), "/tmp", NULL };
    g_cap_fd = -1;
    for (int i = 0; i < 3 && g_cap_fd < 0; i++) {
        const char *tmp = cands[i];
        if (!tmp || !tmp[0]) continue;
        int n = snprintf(g_cap_path, sizeof g_cap_path, "%s/pyx_out_XXXXXX", tmp);
        if (n <= 0 || (size_t)n >= sizeof g_cap_path) continue;
        g_cap_fd = mkstemp(g_cap_path);
    }
    if (g_cap_fd < 0) return -1;
    g_saved_out = dup(STDOUT_FILENO);
    g_saved_err = dup(STDERR_FILENO);
    dup2(g_cap_fd, STDOUT_FILENO);
    dup2(g_cap_fd, STDERR_FILENO);
    return 0;
}

static void cap_flush_py(void) {
    if (!Py_IsInitialized()) return;
    PyGILState_STATE st = PyGILState_Ensure();
    PyRun_SimpleString(
        "import sys\n"
        "for _s in (sys.stdout, sys.stderr):\n"
        "    try: _s.flush()\n"
        "    except Exception: pass\n");
    PyGILState_Release(st);
    fflush(NULL);
}

static void cap_end(void) {
    fflush(NULL);
    if (g_saved_out >= 0) { dup2(g_saved_out, STDOUT_FILENO); close(g_saved_out); g_saved_out = -1; }
    if (g_saved_err >= 0) { dup2(g_saved_err, STDERR_FILENO); close(g_saved_err); g_saved_err = -1; }
}

static void cap_dump(void) {
    if (g_cap_fd < 0) return;
    close(g_cap_fd); g_cap_fd = -1;
    int fd = open(g_cap_path, O_RDONLY);
    if (fd >= 0) {
        char buf[8192]; ssize_t n;
        while ((n = read(fd, buf, sizeof buf)) > 0) {
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(STDOUT_FILENO, buf + off, (size_t)(n - off));
                if (w <= 0) break;
                off += w;
            }
        }
        close(fd);
    }
    unlink(g_cap_path);
}

// 从 argv[0] 推导 App bundle 路径：<bundle>/bin/python3 → <bundle>
static void derive_bundle(const char *argv0, char *buf, size_t size) {
    snprintf(buf, size, "%s", (argv0 && argv0[0]) ? argv0 : "/var/mobile/Documents/wiki.qaq.xosvi/Workspace/Xosvi.app");
    char *p = strrchr(buf, '/'); if (p) *p = '\0';  // .../Xosvi.app/bin
    p = strrchr(buf, '/'); if (p) *p = '\0';        // .../Xosvi.app
}

static char *real_script_path(const char *script, char *resolved, size_t n) {
    if (realpath(script, resolved)) return resolved;
    char alt[PATH_MAX];
    if (strncmp(script, "/var/", 5) == 0) {
        snprintf(alt, sizeof alt, "/private%s", script);
        if (realpath(alt, resolved)) return resolved;
    } else if (strncmp(script, "/private/var/", 13) == 0) {
        snprintf(alt, sizeof alt, "%s", script + 8);
        if (realpath(alt, resolved)) return resolved;
    }
    return NULL;
}

int main(int argc, char **argv) {
    // 巡检探针：main 真执行过就返回 42（Swift 读 exit_code 判断）
    if (argc > 1 && strcmp(argv[1], "--troll-probe") == 0) return 42;

    diag("=== python3 main start ===");

    // 1) 先接管 fd1/2 —— 从这里开始的所有输出都进捕获文件
    if (cap_begin() != 0) {
        fprintf(stderr, "python3: capture init failed (errno=%d)\n", errno);
        return 71;
    }

    // 2) 参数解析（-c / -m / --version / 脚本）
    const char *code = NULL, *module = NULL, *script = NULL;
    int show_version = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) code = argv[++i];
        else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) module = argv[++i];
        else if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-V") == 0) show_version = 1;
        else if (argv[i][0] == '-') { /* 其余旗标忽略 */ }
        else { script = argv[i]; break; }
    }

    // 3) 初始化 CPython
    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.use_environment = 1;

    char bundle[1024];
    derive_bundle(argc > 0 ? argv[0] : NULL, bundle, sizeof bundle);

    char pythonhome[1100];
    snprintf(pythonhome, sizeof pythonhome, "%s/python", bundle);
    status = PyConfig_SetBytesString(&config, &config.home, pythonhome);
    if (PyStatus_Exception(status)) {
        diag("set home FAIL");
        fprintf(stderr, "python3: set home failed: %s\n", status.err_msg ? status.err_msg : "unknown");
        cap_flush_py(); cap_end(); cap_dump();
        return 1;
    }

    PyWideStringList paths = {0};
    {
        const char *dirs[] = {
            "/lib/python3.14",
            "/lib/python3.14/lib-dynload",
            "/lib/python3.14/site-packages"
        };
        for (int i = 0; i < 3; i++) {
            char p[1600];
            snprintf(p, sizeof p, "%s/python%s", bundle, dirs[i]);
            wchar_t *w = Py_DecodeLocale(p, NULL);
            if (w) PyWideStringList_Append(&paths, w);
        }
    }
    config.module_search_paths = paths;
    config.module_search_paths_set = 1;

    diag("calling Py_InitializeFromConfig");
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "python3: Py_Initialize failed: %s\n",
                status.err_msg ? status.err_msg : "(no message)");
        diag("Py_Initialize EXCEPTION");
        cap_flush_py(); cap_end(); cap_dump();
        return 1;
    }
    diag("Py initialized OK");

    // 4) 执行
    int rc = 0;
    if (show_version) {
        rc = PyRun_SimpleString("import sys; print(sys.version)");
    } else if (code) {
        rc = PyRun_SimpleString(code);
        if (rc != 0) { PyErr_Print(); PyErr_Clear(); }
    } else if (module) {
        PyObject *mod = PyImport_ImportModule(module);
        if (!mod) { PyErr_Print(); rc = 1; }
        else { Py_DECREF(mod); }
        if (PyErr_Occurred()) PyErr_Clear();
    } else if (script) {
        char resolved[PATH_MAX];
        const char *sp = real_script_path(script, resolved, sizeof resolved);
        if (!sp) sp = script;
        FILE *fp = fopen(sp, "rb");
        if (!fp) {
            fprintf(stderr, "python3: can't open file '%s' (resolved '%s'): %s (errno=%d)\n",
                    script, sp, strerror(errno), errno);
            rc = 2;
        } else {
            rc = PyRun_AnyFileExFlags(fp, script, 1, NULL);
            if (PyErr_Occurred()) { PyErr_Print(); PyErr_Clear(); }
        }
    } else {
        rc = PyRun_SimpleString(
            "import sys\n"
            "print('Xosvi native Python', sys.version.split()[0], '(iOS arm64)')\n"
            "print('usage: python3 -c <code> | -m <module> | <script.py>')\n");
    }
    if (rc != 0 && PyErr_Occurred()) { PyErr_Print(); rc = 1; }

    // 5) 先 flush（Python 层 → C 层），再 finalize（它自己的缓冲也落盘）
    cap_flush_py();
    Py_FinalizeEx();
    cap_flush_py();

    // 6) 此刻才恢复 fd，然后把捕获内容吐回真 stdout
    cap_end();
    cap_dump();

    diag("=== python3 main end ===");
    return rc;
}
