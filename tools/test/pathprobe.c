/* 临时探针：在同一进程里同时 stat/realpath 同一路径，区分 rootHide 的 vroot 与真实视图。
 * 用法：pathprobe <path>...   用完即删。 */
#include <stdio.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

int main(int argc, char **argv) {
    char exe[PATH_MAX];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) == 0) printf("exe=%s\n", exe);
    printf("uid=%d cwd=", getuid());
    char cwd[PATH_MAX];
    printf("%s\n", getcwd(cwd, sizeof cwd) ? cwd : "?");

    for (int i = 1; i < argc; i++) {
        const char *p = argv[i];
        struct stat st;
        int s1 = stat(p, &st);
        int e1 = errno;
        DIR *d = opendir(p);
        int e2 = errno;
        char rb[PATH_MAX];
        char *r = realpath(p, rb);
        int e3 = errno;
        printf("%s\n  stat=%d(%s) opendir=%s(%s) realpath=%s(%s)\n",
               p,
               s1, s1 == 0 ? "ok" : strerror(e1),
               d ? "ok" : "fail", d ? "" : strerror(e2),
               r ? r : "fail", r ? "" : strerror(e3));
        if (d) closedir(d);
    }
    return 0;
}
