// xosvi-symbolicate —— 符号化 helper（由 xosvid 以 root 派发）
//
// 用法：
//   xosvi-symbolicate uuid  <mach-o>        取二进制/崩溃报告里的映像 UUID
//   xosvi-symbolicate find  <dir> <uuid>    在目录里找 UUID 匹配的 .dSYM
//   xosvi-symbolicate check <crash> <mach-o> 判断崩溃报告的 UUID 是否对得上
//
// UUID 只从 Mach-O 的 LC_UUID 读（崩溃报告文本里也有，但那只是抄同一份值）。
// 0.1.0 只会比对文本里的 UUID 串，路径写死且不认 bootstrap 视图。

#include "xosvi-common.h"
#include <mach-o/loader.h>
#include <mach-o/fat.h>

/* 读 Mach-O 的 LC_UUID；fat 包取第一个切片。成功返回 0 并填 u16（16 字节）。 */
static int read_uuid(const char *path, unsigned char u16[16]) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return -1; }
    if ((size_t)st.st_size < sizeof(struct mach_header_64)) { close(fd); return -1; }

    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof magic, 0) != (ssize_t)sizeof magic) { close(fd); return -1; }

    off_t base = 0;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        struct fat_arch fa;
        if (pread(fd, &fa, sizeof fa, sizeof(uint32_t) * 2) != (ssize_t)sizeof fa) { close(fd); return -1; }
        base = (off_t)ntohl((uint32_t)fa.offset);
        if (pread(fd, &magic, sizeof magic, base) != (ssize_t)sizeof magic) { close(fd); return -1; }
    }

    int is64;
    if (magic == MH_MAGIC || magic == MH_MAGIC_64) is64 = (magic == MH_MAGIC_64);
    else if (magic == MH_CIGAM || magic == MH_CIGAM_64) is64 = (magic == MH_CIGAM_64);
    else { close(fd); return -1; }
    (void)is64;

    off_t off = base + sizeof(struct mach_header_64);
    uint32_t ncmds, sizeofcmds;
    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof mh, base) != (ssize_t)sizeof mh) { close(fd); return -1; }
    ncmds = mh.ncmds;
    sizeofcmds = mh.sizeofcmds;

    char cmdbuf[sizeof(struct load_command)];
    for (uint32_t i = 0; i < ncmds && i < 4096; i++) {
        struct load_command lc;
        if (pread(fd, &lc, sizeof lc, off) != (ssize_t)sizeof lc) break;
        if (lc.cmd == LC_UUID && lc.cmdsize >= sizeof(struct uuid_command)) {
            struct uuid_command uc;
            if (pread(fd, &uc, sizeof uc, off) == (ssize_t)sizeof uc) {
                memcpy(u16, uc.uuid, 16);
                close(fd);
                return 0;
            }
        }
        if (lc.cmdsize == 0) break;
        off += lc.cmdsize;
    }
    (void)cmdbuf;
    (void)sizeofcmds;
    close(fd);
    return -1;
}

static void uuid_str(const unsigned char u[16], char out[40]) {
    snprintf(out, 40,
             "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
             u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}

/* 小写去连字符，便于宽松比较 */
static void uuid_norm(const char *in, char out[33]) {
    int n = 0;
    for (const char *p = in; *p && n < 32; p++) {
        if (*p == '-') continue;
        out[n++] = (char)((*p >= 'a' && *p <= 'z') ? *p - 32 : *p);
    }
    out[n] = '\0';
}

/* 在崩溃报告文本里找 "UUID: <uuid>" */
static int crash_uuid(const char *path, char out[40]) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512];
    int found = -1;
    while (fgets(line, sizeof line, f)) {
        char *p = strstr(line, "Incident Identifier");
        (void)p;
        char *u = strstr(line, "UUID:");
        if (u) {
            char *s = u + 5;
            while (*s == ' ' || *s == '\t') s++;
            snprintf(out, 40, "%s", s);
            char *nl = strchr(out, '\n');
            if (nl) *nl = '\0';
            found = 0;
            break;
        }
    }
    fclose(f);
    return found;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage:\n"
                "  xosvi-symbolicate uuid  <mach-o>\n"
                "  xosvi-symbolicate find  <dir> <uuid>\n"
                "  xosvi-symbolicate check <crash> <mach-o>\n");
        return 2;
    }
    const char *cmd = argv[1];

    if (strcmp(cmd, "uuid") == 0) {
        if (argc < 3) return 2;
        unsigned char u[16];
        if (read_uuid(argv[2], u) != 0) {
            fprintf(stderr, "error: no LC_UUID in %s\n", argv[2]);
            return 3;
        }
        char s[40];
        uuid_str(u, s);
        printf("%s\n", s);
        return 0;
    }

    if (strcmp(cmd, "check") == 0) {
        if (argc < 4) return 2;
        char from_crash[40];
        if (crash_uuid(argv[2], from_crash) != 0) {
            /* 没有 UUID 行的报告交给调用方自己解析，不当成失败 */
            printf("crash_uuid=\nmatch=unknown\n");
            return 0;
        }
        unsigned char u[16];
        if (read_uuid(argv[3], u) != 0) {
            fprintf(stderr, "error: no LC_UUID in %s\n", argv[3]);
            return 3;
        }
        char bin[40], a[33], b[33];
        uuid_str(u, bin);
        uuid_norm(from_crash, a);
        uuid_norm(bin, b);
        int match = strcmp(a, b) == 0;
        printf("crash_uuid=%s\nbinary_uuid=%s\nmatch=%s\n", from_crash, bin, match ? "yes" : "no");
        return match ? 0 : 4;
    }

    if (strcmp(cmd, "find") == 0) {
        if (argc < 4) return 2;
        char want[33];
        uuid_norm(argv[3], want);
        /* 只扫一层目录（调用方给的通常是 <work>/dSYMs），不递归整棵文件树 */
        char cand[PATH_MAX];
        snprintf(cand, sizeof cand, "%s/dSYMs", argv[2]);
        const char *dirs[2] = { cand, argv[2] };
        int hits = 0;
        for (int d = 0; d < 2 && hits == 0; d++) {
            DIR *dp = opendir(dirs[d]);
            if (!dp) continue;
            struct dirent *de;
            while ((de = readdir(dp))) {
                if (de->d_name[0] == '.') continue;
                char path[PATH_MAX];
                snprintf(path, sizeof path, "%s/%s", dirs[d], de->d_name);
                size_t l = strlen(de->d_name);
                if (l > 5 && strcmp(de->d_name + l - 5, ".dSYM") == 0) {
                    char stem[256];
                    snprintf(stem, sizeof stem, "%s", de->d_name);
                    stem[l - 5] = '\0';
                    snprintf(path, sizeof path, "%s/%s/Contents/Resources/DWARF/%s",
                             dirs[d], de->d_name, stem);
                }
                unsigned char u[16];
                if (read_uuid(path, u) != 0) continue;
                char s[40], n[33];
                uuid_str(u, s);
                uuid_norm(s, n);
                if (strcmp(n, want) == 0) { printf("%s\n", path); hits++; }
            }
            closedir(dp);
        }
        if (!hits) {
            fprintf(stderr, "not found: %s under %s\n", argv[3], argv[2]);
            return 4;
        }
        return 0;
    }

    fprintf(stderr, "unknown command %s\n", cmd);
    return 2;
}
