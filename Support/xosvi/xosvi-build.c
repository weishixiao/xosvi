// xosvi-build —— 构建 helper（由 xosvid 以 root 派发）
//
// 用法：xosvi-build <project_dir> [script]
//       xosvi-build --exec <cwd> <shell 命令>      ← App 的 root command:exec 走这条
//   project_dir 必须在 <数据目录>/work 之下；script 默认 <project_dir>/build.sh，
//   必须在 project_dir 之内；两者都先 realpath 再判定，防止 ../ 与符号链接逃逸。
//   脚本以 mobile(501) 运行（构建不需要 root），输出直接作为 helper 的 stdout。
//   --exec 例外：命令以 root 运行、cwd 只做存在性检查（root 工具要在 /Library 等处执行）。
//
// 0.1.0 的失败点：解释器写死 /bin/sh，在「只看得见 bootstrap」的视图里不存在。
// 现在按 xosvi_bootstrap() 实测前缀解析 sh，前缀为空就用真根的 /bin/sh。

#include "xosvi-common.h"

/* <bootstrap>/bin/sh、<bootstrap>/usr/bin/dash、真根 /bin/sh 依次尝试，返回第一个可执行的。 */
static int resolve_shell(const char *prefix, char *out, size_t cap) {
    if (prefix[0]) {
        snprintf(out, cap, "%s/bin/sh", prefix);
        if (access(out, X_OK) == 0) return 1;
        snprintf(out, cap, "%s/usr/bin/dash", prefix);
        if (access(out, X_OK) == 0) return 1;
    }
    snprintf(out, cap, "/bin/sh");
    return access(out, X_OK) == 0;
}

/* 把脚本/命令交给 shell 跑，返回退出码（127 = exec 失败）。root=1 时以 root 身份执行。 */
static int run_shell(const char *sh, const char *cwd, const char *const *argv_with_dash,
                     int as_root, const char *prefix) {
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        if (cwd && chdir(cwd) != 0) _exit(126);
        setenv("HOME", "/var/mobile", 1);
        setenv("PATH",
               "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/var/jb/usr/bin:/var/jb/bin",
               1);
        if (prefix[0]) {
            setenv("XOSVI_JBROOT", prefix, 1);
            char p2[PATH_MAX * 2];
            snprintf(p2, sizeof p2, "%s/usr/bin:%s/bin:%s/usr/sbin:%s/sbin:/usr/bin:/bin",
                     prefix, prefix, prefix, prefix);
            setenv("PATH", p2, 1);
        }
        if (!as_root) {
            setgid(501);
            setuid(501);
            if (getuid() == 0) _exit(126);
        }
        execv(sh, (char *const *)argv_with_dash);
        fprintf(stderr, "exec %s failed: %s\n", sh, strerror(errno));
        _exit(127);
    }
    if (pid < 0) { perror("fork"); return 7; }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: xosvi-build <project_dir> [script]\n"
                        "       xosvi-build --exec <cwd> <shell command>\n");
        return 2;
    }

    char prefix[PATH_MAX];
    if (!xosvi_bootstrap(prefix, sizeof prefix)) {
        fprintf(stderr, "error: no bootstrap (dash not found in any view)\n");
        return 3;
    }

    /* ---- --exec：root 身份跑一条 shell 命令 ---- */
    if (strcmp(argv[1], "--exec") == 0) {
        if (argc < 4) {
            fprintf(stderr, "usage: xosvi-build --exec <cwd> <shell command>\n");
            return 2;
        }
        char sh[PATH_MAX];
        if (!resolve_shell(prefix, sh, sizeof sh)) {
            fprintf(stderr, "error: no shell (bootstrap=%s)\n", prefix);
            return 6;
        }
        struct stat st;
        if (stat(argv[2], &st) != 0 || !S_ISDIR(st.st_mode)) {
            fprintf(stderr, "error: cwd %s is not a directory\n", argv[2]);
            return 4;
        }
        printf("bootstrap=%s\nshell=%s\nuid=%d\n", prefix, sh, (int)getuid());
        fflush(stdout);
        const char *ea[] = { sh, "-c", argv[3], NULL };
        int rc = run_shell(sh, argv[2], ea, 1, prefix);
        printf("\n[exit %d]\n", rc);
        return rc;
    }

    char work_root[PATH_MAX];
    xosvi_path(work_root, sizeof work_root, prefix, "/private/var/mobile/Documents/wiki.qaq.xosvi/work");
    char work_real[PATH_MAX];
    if (!realpath(work_root, work_real) && !realpath(XOSVI_WORK_ROOT, work_real)) {
        fprintf(stderr, "error: work root missing (tried %s and %s)\n", work_root, XOSVI_WORK_ROOT);
        return 3;
    }

    /* 调用方（App / CLI）给的是真根视图路径 /private/var/mobile/...，root 守护看到的是
     * AppGroup 共享视图；realpath 之后前缀不同但是同一个目录。这里两步都试一次：
     * 先按原路径，再按「真根逻辑部分拼到当前视图的 /private/var 之前」的候选路径。 */
    char cand[PATH_MAX];
    snprintf(cand, sizeof cand, "%s", argv[1]);
    char proj_real[PATH_MAX];
    int ok = realpath(cand, proj_real) != NULL;
    if (!ok) {
        char alt[PATH_MAX];
        snprintf(alt, sizeof alt, "%s%s", prefix, argv[1]);
        ok = realpath(alt, proj_real) != NULL;
        if (!ok && strncmp(argv[1], "/private/var/", 13) == 0) {
            /* 真根视图：/private/var/... 在共享视图里是 <base>/var/... */
            char base[PATH_MAX];
            snprintf(base, sizeof base, "%s", prefix);
            char *slash = strrchr(base, '/');           /* .../AppGroup */
            if (slash) {
                *slash = '\0';
                snprintf(alt, sizeof alt, "%s%s", base, argv[1]);
                ok = realpath(alt, proj_real) != NULL;
            }
        }
    }
    if (!ok || !xosvi_inside(proj_real, work_real)) {
        fprintf(stderr, "error: project dir %s escapes %s\n", argv[1], work_real);
        return 4;
    }

    char script[PATH_MAX];
    if (argc >= 3) snprintf(script, sizeof script, "%s", argv[2]);
    else snprintf(script, sizeof script, "%s/build.sh", proj_real);

    char script_real[PATH_MAX];
    struct stat st;
    if (!realpath(script, script_real) || lstat(script_real, &st) != 0 || !S_ISREG(st.st_mode)) {
        fprintf(stderr, "error: script %s not found\n", script);
        return 5;
    }
    if (!xosvi_inside(script_real, proj_real)) {
        fprintf(stderr, "error: script escapes project dir\n");
        return 5;
    }

    char sh[PATH_MAX];
    if (!resolve_shell(prefix, sh, sizeof sh)) {
        fprintf(stderr, "error: no shell under '%s' (bootstrap=%s)\n", prefix, prefix);
        return 6;
    }

    printf("bootstrap=%s\nproject=%s\nscript=%s\nshell=%s\n",
           prefix, proj_real, script_real, sh);
    fflush(stdout);

    const char *sa[] = { sh, script_real, NULL };
    int rc = run_shell(sh, proj_real, sa, 0, prefix);
    printf("\n[exit %d]\n", rc);
    return rc;
}
