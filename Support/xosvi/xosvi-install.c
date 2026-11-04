// xosvi-install —— 安装 helper（由 xosvid 以 root 派发）
//
// 用法：xosvi-install <deb> <workdir> [--dry-run]
//   <deb>     必须是 workdir 之下的普通文件（先 realpath 再判定）
//   <workdir> 必须在 <数据目录>/work 之下
//   真正安装走 MobileInstallation（iOS 官方安装通道），不碰 dpkg —— rootless /
//   roothide 上 dpkg 维护的数据库和 App 侧的包管理不是一回事，绕过它会留下
//   一半装好的状态。--dry-run 只做校验并打印将要安装的路径与包标识。
//
// 0.1.0 的失败点：解释器与数据目录写死，bootstrap 前缀错误时连校验都过不去。

#include "xosvi-common.h"

typedef int (*mi_install_fn)(const char *, const char *);

int main(int argc, char **argv) {
    int dryrun = 0;
    if (argc >= 2 && strcmp(argv[argc - 1], "--dry-run") == 0) { dryrun = 1; argc--; }
    if (argc < 3) {
        fprintf(stderr, "usage: xosvi-install <deb> <workdir> [--dry-run]\n");
        return 2;
    }

    char prefix[PATH_MAX];
    if (!xosvi_bootstrap(prefix, sizeof prefix)) {
        fprintf(stderr, "error: no bootstrap (dash not found in any view)\n");
        return 3;
    }

    char work_root[PATH_MAX], work_real[PATH_MAX];
    xosvi_path(work_root, sizeof work_root, prefix, "/private/var/mobile/Documents/wiki.qaq.xosvi/work");
    if (!realpath(work_root, work_real) && !realpath(XOSVI_WORK_ROOT, work_real)) {
        fprintf(stderr, "error: work root missing\n");
        return 3;
    }
    char wd_real[PATH_MAX];
    if (!realpath(argv[2], wd_real) || !xosvi_inside(wd_real, work_real)) {
        fprintf(stderr, "error: workdir %s escapes %s\n", argv[2], work_real);
        return 4;
    }

    char deb_real[PATH_MAX];
    struct stat st;
    if (!realpath(argv[1], deb_real) || lstat(deb_real, &st) != 0 || !S_ISREG(st.st_mode)) {
        fprintf(stderr, "error: %s is not a regular file\n", argv[1]);
        return 5;
    }
    if (!xosvi_inside(deb_real, wd_real)) {
        fprintf(stderr, "error: deb %s escapes workdir %s\n", deb_real, wd_real);
        return 5;
    }
    if (st.st_uid != 501) {
        fprintf(stderr, "error: deb %s not owned by mobile (uid=%d)\n", deb_real, (int)st.st_uid);
        return 5;
    }

    printf("bootstrap=%s\ndeb=%s\nworkdir=%s\nsize=%lld\n",
           prefix, deb_real, wd_real, (long long)st.st_size);
    fflush(stdout);

    if (dryrun) {
        printf("[dry-run] 校验通过，未安装\n");
        return 0;
    }

    /* MobileInstallationInstall 由 MobileInstallation.framework 导出；
     * 用 dlsym 取，框架不存在时明确报错而不是崩在半路。 */
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
                     RTLD_NOW);
    if (!h) {
        fprintf(stderr, "error: MobileInstallation unavailable (%s)\n", dlerror());
        return 7;
    }
    mi_install_fn install = (mi_install_fn)dlsym(h, "MobileInstallationInstall");
    if (!install) {
        fprintf(stderr, "error: MobileInstallationInstall missing\n");
        return 7;
    }
    int rc = install(deb_real, wd_real);
    printf("\nMobileInstallationInstall -> %d\n", rc);
    return rc == 0 ? 0 : 8;
}
