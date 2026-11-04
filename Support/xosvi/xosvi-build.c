// xosvi-build —— 构建 helper（由 xosvid 以 root 派发）
//
// 用法：xosvi-build <project_dir> [script]
//   project_dir 必须在 <数据目录>/work 之下；script 默认 <project_dir>/build.sh，
//   必须在 project_dir 之内；两者都先 realpath 再判定，防止 ../ 与符号链接逃逸。
//   脚本以 mobile(501) 运行（构建不需要 root），输出直接作为 helper 的 stdout。
//
// 0.1.0 的失败点：解释器写死 /bin/sh，在「只看得见 bootstrap」的视图里不存在。
// 现在按 xosvi_bootstrap() 实测前缀解析 sh，前缀为空就用真根的 /bin/sh。

#include "xosvi-common.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: xosvi-build <project_dir> [script]\n");
        return 2;
    }

    char prefix[PATH_MAX];
    if (!xosvi_bootstrap(prefix, sizeof prefix)) {
        fprintf(stderr, "error: no bootstrap (dash not found in any view)\n");
        return 3;
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
    snprintf(sh, sizeof sh, "%s/bin/sh", prefix);
    if (access(sh, X_OK) != 0) {
        snprintf(sh, sizeof sh, "%s/usr/bin/dash", prefix);
        if (access(sh, X_OK) != 0) {
            fprintf(stderr, "error: no shell under '%s' (bootstrap=%s)\n", prefix, prefix);
            return 6;
        }
    }

    printf("bootstrap=%s\nproject=%s\nscript=%s\nshell=%s\n",
           prefix, proj_real, script_real, sh);
    fflush(stdout);

    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        if (chdir(proj_real) != 0) _exit(126);
        setenv("HOME", "/var/mobile", 1);
        setenv("XOSVI_JBROOT", prefix, 1);
        setgid(501);
        setuid(501);
        execl(sh, "sh", script_real, (char *)NULL);
        fprintf(stderr, "exec %s failed: %s\n", sh, strerror(errno));
        _exit(127);
    }
    if (pid < 0) { perror("fork"); return 7; }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    printf("\n[exit %d]\n", rc);
    return rc;
}
