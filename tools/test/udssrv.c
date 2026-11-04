/* 临时测试工具：在指定路径 bind UDS，验证 rootHide 双视图问题。用完即删。 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {0};
    a.sun_family = AF_UNIX;
    strcpy(a.sun_path, argv[1]);
    unlink(argv[1]);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) { perror("bind"); return 1; }
    listen(s, 1);
    printf("listening %s (uid=%d)\n", argv[1], geteuid());
    fflush(stdout);
    sleep(8);
    return 0;
}
