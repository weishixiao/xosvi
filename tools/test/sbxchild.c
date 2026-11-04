/* 临时实验：A mobile 进程能否对「别人创建的 root:mobile 子目录」申请读扩展并读入。
 * 用法：sbxchild <dir>    用完即删。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <dlfcn.h>

typedef long (*issue_t)(const char *, const char *, int);
typedef long (*consume_t)(const char *);

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    const char *dir = argv[1];
    issue_t issue = (issue_t)dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file");
    consume_t consume = (consume_t)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    printf("before: ");
    DIR *d = opendir(dir);
    printf("opendir=%s\n", d ? "ok" : strerror(errno));
    if (d) closedir(d);
    long tok = issue ? issue("com.apple.app-sandbox.read", dir, 0) : 0;
    printf("issue -> %ld (%s)\n", tok, tok ? "" : strerror(errno));
    if (tok) {
        long c = consume((const char *)tok);
        printf("consume -> %ld (%s)\n", c, c >= 0 ? "" : strerror(errno));
    }
    d = opendir(dir);
    printf("after:  opendir=%s\n", d ? "ok" : strerror(errno));
    if (d) {
        struct dirent *de;
        while ((de = readdir(d))) printf("   %s\n", de->d_name);
        closedir(d);
    }
    return 0;
}
