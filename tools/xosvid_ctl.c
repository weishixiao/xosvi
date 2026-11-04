/*
 * xosvid_ctl —— xosvid 的最小客户端，用于验证 UDS 通道
 * 用法：xosvid_ctl PING | STATUS | STOP | RUN '<脚本>'
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK_PATH "/var/mobile/Documents/xosvid/xosvid.sock"

static int send_frame(int fd, const char *d, size_t n) {
    unsigned char h[4] = { (unsigned char)(n>>24)&0xff, (unsigned char)(n>>16)&0xff,
                           (unsigned char)(n>>8)&0xff, (unsigned char)n&0xff };
    if (write(fd, h, 4) != 4) return -1;
    size_t s = 0;
    while (s < n) { ssize_t w = write(fd, d+s, n-s); if (w <= 0) return -1; s += (size_t)w; }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s PING|STATUS|STOP|RUN <script>\n", argv[0]); return 2; }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    const char *path = getenv("XOSVID_SOCK");
    if (!path || !path[0]) path = SOCK_PATH;
    strncpy(a.sun_path, path, sizeof(a.sun_path)-1);
    if (connect(fd, (struct sockaddr*)&a, sizeof(a)) != 0) {
        perror("connect"); fprintf(stderr, "(xosvid 没在跑？root: %s --foreground 或由 launchd 拉起)\n", argv[0]);
        return 1;
    }

    char *req; size_t n;
    if (strcmp(argv[1], "RUN") == 0 && argc >= 3) {
        n = strlen(argv[1]) + 1 + strlen(argv[2]);
        req = malloc(n+1);
        snprintf(req, n+1, "%s\n%s", argv[1], argv[2]);
    } else {
        n = strlen(argv[1]);
        req = strdup(argv[1]);
    }
    if (send_frame(fd, req, n) != 0) { perror("send"); return 1; }

    /* 读 4 字节长度 + payload */
    unsigned char h[4]; size_t got = 0;
    while (got < 4) { ssize_t r = read(fd, h+got, 4-got); if (r <= 0) { perror("read hdr"); return 1; } got += (size_t)r; }
    uint32_t len = ((uint32_t)h[0]<<24)|((uint32_t)h[1]<<16)|((uint32_t)h[2]<<8)|(uint32_t)h[3];
    if (len > 64u*1024*1024) { fprintf(stderr, "resp too large\n"); return 1; }
    char *buf = malloc(len+1);
    got = 0;
    while (got < len) { ssize_t r = read(fd, buf+got, len-got); if (r <= 0) break; got += (size_t)r; }
    buf[got] = 0;
    fwrite(buf, 1, got, stdout);
    if (got && buf[got-1] != '\n') putchar('\n');
    free(buf); free(req);
    return 0;
}
