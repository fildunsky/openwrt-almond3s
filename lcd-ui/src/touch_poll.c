/*
 * touch_poll — Touch + backlight control for Almond 3S LCD
 *
 * Usage:
 *   touch_poll          — foreground touch demo (draw crosshairs)
 *   touch_poll daemon   — background daemon: write /tmp/.lcd_touch
 *   touch_poll bl 0     — backlight OFF (ioctl cmd=4, arg=0)
 *   touch_poll bl 1     — backlight ON  (ioctl cmd=4, arg=1)
 *   touch_poll bl 2     — show splash   (ioctl cmd=4, arg=2)
 *
 * Daemon writes: "raw_x raw_y pressed\n" to /tmp/.lcd_touch every 50ms
 * Build: zig cc -target mipsel-linux-musleabi -Os -static -o touch_poll touch_poll.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <sys/types.h>

#define LCD_W 320
#define LCD_H 240
#define FB_SIZE (LCD_W * LCD_H * 2)
#define TOUCH_FILE "/tmp/.lcd_touch"

static volatile int running = 1;
static void sig_handler(int sig) { (void)sig; running = 0; }

/* === Daemon mode: latch touch events to file === */
/* Only writes on press EDGE (transition 0→1).
 * File stays until UI reads and unlinks it.
 * This prevents race conditions where continuous polling
 * overwrites pressed=1 with pressed=0 before UI reads.
 *
 * NOTE: daemon(0,0) closes fd 0-2 which on musl can
 * invalidate /dev/lcd fd. We fork manually instead. */
static int daemon_mode(int fd)
{
    signal(SIGTERM, sig_handler);
    signal(SIGINT, sig_handler);

    /* Manual daemonize: fork, setsid, keep fd open */
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid > 0) _exit(0); /* parent exits */
    setsid();

    int was_pressed = 0;
    while (running) {
        int data[3] = {0, 0, 0};
        ioctl(fd, 1, data);

        if (data[2] && !was_pressed) {
            /* New press — write coordinates (latch) */
            FILE *out = fopen(TOUCH_FILE, "w");
            if (out) {
                fprintf(out, "%d %d\n", data[0], data[1]);
                fclose(out);
            }
            was_pressed = 1;
        } else if (!data[2]) {
            was_pressed = 0;
        }
        usleep(50000); /* 50ms */
    }
    return 0;
}

/* === Demo mode: draw crosshairs on touch === */

static unsigned short fb[LCD_W * LCD_H];

static void fb_pixel(int x, int y, unsigned short c)
{
    if (x >= 0 && x < LCD_W && y >= 0 && y < LCD_H)
        fb[y * LCD_W + x] = c;
}

static void fb_rect(int x, int y, int w, int h, unsigned short c)
{
    for (int j = y; j < y + h && j < LCD_H; j++)
        for (int i = x; i < x + w && i < LCD_W; i++)
            if (i >= 0 && j >= 0) fb[j * LCD_W + i] = c;
}

static const unsigned char font5x7[][5] = {
    {0x3E,0x51,0x49,0x45,0x3E},{0x00,0x42,0x7F,0x40,0x00},
    {0x42,0x61,0x51,0x49,0x46},{0x21,0x41,0x45,0x4B,0x31},
    {0x18,0x14,0x12,0x7F,0x10},{0x27,0x45,0x45,0x45,0x39},
    {0x3C,0x4A,0x49,0x49,0x30},{0x01,0x71,0x09,0x05,0x03},
    {0x36,0x49,0x49,0x49,0x36},{0x06,0x49,0x49,0x29,0x1E},
    {0x00,0x00,0x00,0x00,0x00}, /* space=10 */
    {0x44,0x64,0x54,0x4C,0x44}, /* %=11 */
    {0x14,0x14,0x14,0x14,0x14}, /* ==12 */
    {0x7E,0x11,0x11,0x11,0x7E}, /* A=13 */
    {0x7F,0x41,0x41,0x22,0x1C}, /* D=14 */
    {0x7F,0x49,0x49,0x49,0x41}, /* E=15 */
    {0x7F,0x08,0x08,0x08,0x7F}, /* H=16 */
    {0x7F,0x40,0x40,0x40,0x40}, /* L=17 */
    {0x7F,0x02,0x0C,0x02,0x7F}, /* M=18 */
    {0x7F,0x04,0x08,0x10,0x7F}, /* N=19 */
    {0x3E,0x41,0x41,0x41,0x3E}, /* O=20 */
    {0x01,0x01,0x7F,0x01,0x01}, /* T=21 */
    {0x3F,0x40,0x40,0x40,0x3F}, /* U=22 */
    {0x10,0x08,0x04,0x08,0x10}, /* W=23 (inverted V) */
    {0x44,0x28,0x10,0x28,0x44}, /* X=24 */
    {0x04,0x08,0x70,0x08,0x04}, /* Y=25 */
};

static int char_idx(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c == ' ') return 10;
    if (c == '#' || c == '%') return 11;
    if (c == '=') return 12;
    switch(c) {
        case 'A': case 'a': return 13;
        case 'D': case 'd': return 14;
        case 'E': case 'e': return 15;
        case 'H': case 'h': return 16;
        case 'L': case 'l': return 17;
        case 'M': case 'm': return 18;
        case 'N': case 'n': return 19;
        case 'O': case 'o': return 20;
        case 'T': case 't': return 21;
        case 'U': case 'u': return 22;
        case 'W': case 'w': return 23;
        case 'X': case 'x': return 24;
        case 'Y': case 'y': return 25;
    }
    return 10; /* space fallback */
}

static void fb_char(int x, int y, char c, unsigned short color, int s)
{
    int idx = char_idx(c);
    for (int col = 0; col < 5; col++)
        for (int row = 0; row < 7; row++)
            if (font5x7[idx][col] & (1 << row))
                for (int sy = 0; sy < s; sy++)
                    for (int sx = 0; sx < s; sx++)
                        fb_pixel(x + col*s + sx, y + row*s + sy, color);
}

static void fb_string(int x, int y, const char *str, unsigned short c, int s)
{
    while (*str) { fb_char(x, y, *str, c, s); x += 6*s; str++; }
}

static void fb_flush(int fd)
{
    lseek(fd, 0, SEEK_SET);
    write(fd, fb, FB_SIZE);
    ioctl(fd, 0, 0);
}

static int demo_mode(int fd)
{
    memset(fb, 0, FB_SIZE);
    fb_string(30, 10, "TOUCH DEMO", 0xFFE0, 3);
    fb_string(30, 45, "TAP ANYWHERE", 0xFFFF, 2);
    fb_flush(fd);

    printf("Touch demo. Ctrl+C to exit.\n");
    int count = 0, was = 0;

    while (1) {
        int d[3] = {0};
        if (ioctl(fd, 1, d) < 0) { usleep(50000); continue; }
        if (d[2] && !was) {
            count++;
            fb_rect(0, 60, LCD_W, 155, 0);
            /* crosshair */
            fb_rect(d[0]-12, d[1], 25, 1, 0xF800);
            fb_rect(d[0], d[1]-12, 1, 25, 0xF800);
            char buf[40];
            snprintf(buf, sizeof(buf), "X=%3d Y=%3d #%d", d[0], d[1], count);
            fb_string(20, 215, buf, 0xFFFF, 2);
            fb_flush(fd);
            printf("TAP #%d x=%d y=%d\n", count, d[0], d[1]);
        }
        was = d[2];
        usleep(30000);
    }
    return 0;
}

int main(int argc, char **argv)
{
    int fd = open("/dev/lcd", O_RDWR);
    if (fd < 0) { perror("/dev/lcd"); return 1; }

    /* touch_poll bl <0|1|2> — backlight control */
    if (argc >= 3 && argv[1][0] == 'b') {
        int ret = ioctl(fd, 4, (unsigned long)atoi(argv[2]));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* touch_poll version — read lcd_drv version */
    if (argc >= 2 && argv[1][0] == 'v') {
        char ver[64] = {0};
        if (ioctl(fd, 7, ver) == 0)
            printf("%s\n", ver);
        else
            printf("unknown\n");
        close(fd);
        return 0;
    }

    /* touch_poll pic — сырые 17 байт статуса PIC (ioctl 3).
     * Нужно, чтобы ловить, докладывает ли PIC о нажатиях кнопки питания:
     * до ядра она не доходит, вся надежда на эти байты. */
    if (argc >= 2 && argv[1][0] == 'p') {
        unsigned char buf[17] = {0};
        int i;
        /* ioctl 2 - последний периодический снимок, который делает поток тача.
         * ioctl 3 читает шину прямо здесь и на живом устройстве отваливается:
         * SM0 в этот момент занят потоком тача. */
        if (ioctl(fd, 2, buf) < 0) { close(fd); return 1; }
        for (i = 0; i < 17; i++)
            printf("%02x%s", buf[i], i == 16 ? "\n" : " ");
        close(fd);
        return 0;
    }

    /* touch_poll daemon — background poller (fork) */
    if (argc >= 2 && strcmp(argv[1], "daemon") == 0) {
        return daemon_mode(fd);
    }

    /* touch_poll daemon_fg — foreground poller (for procd) */
    if (argc >= 2 && strcmp(argv[1], "daemon_fg") == 0) {
        signal(SIGTERM, sig_handler);
        signal(SIGINT, sig_handler);
        int was_pressed = 0;
        while (running) {
            int data[3] = {0, 0, 0};
            ioctl(fd, 1, data);
            if (data[2] && !was_pressed) {
                FILE *out = fopen(TOUCH_FILE, "w");
                if (out) { fprintf(out, "%d %d\n", data[0], data[1]); fclose(out); }
                was_pressed = 1;
            } else if (!data[2]) {
                was_pressed = 0;
            }
            usleep(50000);
        }
        close(fd);
        return 0;
    }

    /* Default: demo mode */
    return demo_mode(fd);
}
