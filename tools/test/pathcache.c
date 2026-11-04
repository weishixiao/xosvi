/* 临时实验：在同一进程内先访问 /var/containers/…/.jbroot-…/var/mobile/Documents/wiki.qaq.xosvi，
 * 再访问 /var/mobile/Documents/wiki.qaq.xosvi，看是否被放行（路径缓存假说）。用完即删。 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>

static void probe(const char *p) {
    errno = 0;
    DIR *d = opendir(p);
    printf("%-100s %s\n", p, d ? "ok" : strerror(errno));
    if (d) closedir(d);
}

int main(void) {
    const char *jb = "/var/containers/Bundle/Application/.jbroot-D2AF34F838FA2E5D";
    char a[512], b[512];
    snprintf(a, sizeof a, "%s/var/mobile/Documents/wiki.qaq.xosvi", jb);
    probe("/var/mobile/Documents/wiki.qaq.xosvi");   /* 先测裸路径 */
    probe(a);                                        /* 再测 jbroot 路径 */
    snprintf(b, sizeof b, "%s/var/mobile/Documents/wiki.qaq.xosvi/work", jb);
    probe("/var/mobile/Documents/wiki.qaq.xosvi/work");
    probe(b);
    return 0;
}
