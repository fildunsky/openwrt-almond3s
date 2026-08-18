/*
 * keygrab.cpp - дождаться нажатия клавиши и напечатать её код.
 *
 * Нужен экрану настройки раскладки: интерфейс написан на ucode, а разбирать
 * там двоичные события /dev/input неудобно. Печатает одно число и выходит.
 * Аргумент - сколько секунд ждать (по умолчанию 8).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/select.h>
#include <linux/input.h>

#define MAX_FD 8

int main(int argc, char **argv)
{
    int fds[MAX_FD], n = 0;
    int wait_s = (argc > 1) ? atoi(argv[1]) : 8;
    DIR *d = opendir("/dev/input");
    struct dirent *e;
    char path[64];

    if (!d) return 1;
    while ((e = readdir(d)) && n < MAX_FD) {
        if (strncmp(e->d_name, "event", 5)) continue;
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY);
        if (fd >= 0) fds[n++] = fd;
    }
    closedir(d);
    if (!n) return 1;

    struct timeval tv = { wait_s, 0 };
    for (;;) {
        fd_set rs;
        int max = 0;
        FD_ZERO(&rs);
        for (int i = 0; i < n; i++) {
            FD_SET(fds[i], &rs);
            if (fds[i] > max) max = fds[i];
        }
        if (select(max + 1, &rs, NULL, NULL, &tv) <= 0) return 1;

        struct input_event ev;
        for (int i = 0; i < n; i++) {
            if (!FD_ISSET(fds[i], &rs)) continue;
            if (read(fds[i], &ev, sizeof ev) != (int)sizeof ev) continue;
            /* Только нажатие: отпускание того же кода пришло бы следом. */
            if (ev.type == EV_KEY && ev.value == 1) {
                printf("%d\n", ev.code);
                return 0;
            }
        }
    }
}
