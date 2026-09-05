/*
 * almond3s-lcd — управление экраном Almond 3S: тач, подсветка, диод, звук
 *
 * Usage:
 *   almond3s-lcd          — foreground touch demo (draw crosshairs)
 *   almond3s-lcd daemon   — background daemon: write /tmp/.lcd_touch
 *   almond3s-lcd led on   — диод над экраном (on|off|blink)
 *   almond3s-lcd tone 800 40 600 40 — бипер: пары «частота длительность»
 *   almond3s-lcd rotate 1  — экран вверх ногами
 *   almond3s-lcd volume 2 — громкость бипера 1..3
 *   almond3s-lcd bl 0     — backlight OFF (ioctl cmd=4, arg=0)
 *   almond3s-lcd bl 1     — backlight ON  (ioctl cmd=4, arg=1)
 *   almond3s-lcd bl 2     — show splash   (ioctl cmd=4, arg=2)
 *
 * Daemon writes: "raw_x raw_y pressed\n" to /tmp/.lcd_touch every 50ms
 * Сборка вручную: zig cc -target mipsel-linux-musleabi -Os -static \
 *                 -o almond3s-lcd almond3s-lcd.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/file.h>

#define LCD_W 320
#define LCD_H 240
#define FB_SIZE (LCD_W * LCD_H * 2)
#define TOUCH_FILE "/tmp/.lcd_touch"

static volatile int running = 1;

/* TERM во время мелодии не должен убивать процесс молча: PIC зациклил
 * таблицу, и без финального stop-пакета звон не кончится никогда. Сигнал
 * только помечает флаг, а stop шлёт сам процесс перед выходом. */
static volatile sig_atomic_t tone_term;
static void tone_term_handler(int s) { (void)s; tone_term = 1; }
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

    /* almond3s-lcd bl <0|1|2> — backlight control */
    if (argc >= 3 && strcmp(argv[1], "bl") == 0) {
        int ret = ioctl(fd, 4, (unsigned long)atoi(argv[2]));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd version — read lcd_drv version */
    if (argc >= 2 && strcmp(argv[1], "version") == 0) {
        char ver[64] = {0};
        if (ioctl(fd, 7, ver) == 0)
            printf("%s\n", ver);
        else
            printf("unknown\n");
        close(fd);
        return 0;
    }

    /* almond3s-lcd dim <0..255> — яркость подсветки программным ШИМ (ioctl 16).
     * 0 - погашено, 255 - полный накал, между ними драйвер крутит пин. */
    if (argc >= 3 && strcmp(argv[1], "dim") == 0) {
        int ret = ioctl(fd, 16, (unsigned long)atoi(argv[2]));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd scene <n|stop> — запустить сцену-заставку n (ioctl 5):
     * 0..6 - конкретная (6 = матрица «Wake up Neo»), 99 - случайная,
     * stop/100 - остановить анимацию и вернуть управление интерфейсу. */
    if (argc >= 3 && strcmp(argv[1], "scene") == 0) {
        int n = strcmp(argv[2], "stop") == 0 ? 100 : atoi(argv[2]);
        int ret = ioctl(fd, 5, (unsigned long)n);
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd matrixline <текст> — строка статуса матрицы-заставки
     * (ioctl 32): живой logread снизу вместо молчащего kmsg. */
    if (argc >= 3 && strcmp(argv[1], "matrixline") == 0) {
        char buf[128];
        strncpy(buf, argv[2], sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = 0;
        int ret = ioctl(fd, 32, buf);
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd stats — строк/мкс/кадров в последней перерисовке (ioctl 18). */
    if (argc >= 2 && strcmp(argv[1], "stats") == 0) {
        int d[3] = {0, 0, 0};
        if (ioctl(fd, 18, d) == 0)
            printf("rows=%d us=%d frames=%d\n", d[0], d[1], d[2]);
        else
            printf("stats unavailable\n");
        close(fd);
        return 0;
    }

    /* almond3s-lcd bench [N] — N полных перерисовок, печатает среднее мкс/кадр
     * (ioctl 30). Экран мигнёт мусором. По умолчанию 30 кадров. */
    if (argc >= 2 && strcmp(argv[1], "bench") == 0) {
        int iters = argc > 2 ? atoi(argv[2]) : 30;
        if (iters < 1) iters = 1;
        int us = ioctl(fd, 30, (unsigned long)iters);
        if (us > 0)
            printf("frames=%d total_us=%d avg_us=%d\n", iters, us, us / iters);
        else
            printf("bench failed\n");
        close(fd);
        return 0;
    }

    /* almond3s-lcd pwm <Гц> — частота ШИМ подсветки (ioctl 24). */
    if (argc >= 3 && strcmp(argv[1], "pwm") == 0) {
        int hz = atoi(argv[2]);
        if (hz < 50) hz = 50;
        if (hz > 20000) hz = 20000;
        int ret = ioctl(fd, 24, (unsigned long)(1000000 / hz));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd panel <команда> [данные] — сырая команда в ILI9341.
     * Для проверки аппаратной яркости: panel 0x53 0x2C, затем panel 0x51 0x40. */
    if (argc >= 3 && strcmp(argv[1], "panel") == 0) {
        int c = (int)strtol(argv[2], NULL, 0) & 0xFF;
        int d = argc > 3 ? (int)strtol(argv[3], NULL, 0) & 0xFF : 0;
        int n = argc > 3 ? 1 : 0;
        int ret = ioctl(fd, 23, (unsigned long)((c << 16) | (d << 8) | n));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd rotate 0|1 — разворот экрана на 180 (ioctl 22). */
    if (argc >= 3 && strcmp(argv[1], "rotate") == 0) {
        int ret = ioctl(fd, 22, (unsigned long)(atoi(argv[2]) ? 1 : 0));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd sxsel <байт> — SELECT-чтение тач-чипа координатным
     * циклом (ioctl 31): печатает тег канала и значение. Идентификация:
     * SELECT(RX)=0x85 при прижатом пере вернёт тег 5 только у SX8651.
     * almond3s-lcd sxw <регистр> <значение> — запись регистра чипа. */
    if (argc >= 3 && strcmp(argv[1], "sxsel") == 0) {
        int sb = (int)strtol(argv[2], NULL, 0) & 0xFF;
        int ret = ioctl(fd, 31, (unsigned long)sb);
        if (ret < 0)
            printf("sel 0x%02x: err\n", sb);
        else
            printf("sel 0x%02x -> raw 0x%04x (ch=%d val=%d)\n",
                   sb, ret, (ret >> 12) & 7, ret & 0x0FFF);
        close(fd);
        return ret < 0 ? 1 : 0;
    }
    if (argc >= 4 && strcmp(argv[1], "sxw") == 0) {
        int reg = (int)strtol(argv[2], NULL, 0) & 0x1F;
        int val = (int)strtol(argv[3], NULL, 0) & 0xFF;
        int ret = ioctl(fd, 31,
                        (unsigned long)(0x10000 | (reg << 8) | val));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd touchmode manual|pentrg|i2c — режим опроса SX8650 (ioctl 29):
     * manual = ручной SELECT (дефолт); pentrg = старый palmbus-PENTRG (тупик);
     * i2c = PENTRG по штатному I2C (стоко-подобный, тянет стилус/высокоомный
     * контакт). Число 0/1/2 тоже принимается. */
    if (argc >= 3 && strcmp(argv[1], "touchmode") == 0) {
        int m;
        if (strcmp(argv[2], "manual") == 0) m = 0;
        else if (strcmp(argv[2], "pentrg") == 0) m = 1;
        else if (strcmp(argv[2], "i2c") == 0) m = 2;
        else if (strcmp(argv[2], "pmtrg") == 0) m = 3;
        else m = atoi(argv[2]);
        int ret = ioctl(fd, 29, (unsigned long)m);
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd gpiowatch <сек> — печатать перемены GPIO DATA-регистров
     * (ioctl 28), шумные пины дисплея и ШИМ замаскированы. Поиск кнопки. */
    if (argc >= 3 && strcmp(argv[1], "gpiowatch") == 0) {
        int secs = atoi(argv[2]);
        unsigned int p[3] = { 0, 0, 0 };
        int first = 1, t;
        if (secs < 1) secs = 60;
        if (secs > 900) secs = 900;
        for (t = 0; t < secs * 100; t++) {
            unsigned int d[3];
            if (ioctl(fd, 28, d) == 0) {
                d[0] &= ~0x8FC7E000u;
                if (first || d[0] != p[0] || d[1] != p[1] || d[2] != p[2]) {
                    printf("%8d  %08x %08x %08x\n", t, d[0], d[1], d[2]);
                    fflush(stdout);
                    p[0] = d[0]; p[1] = d[1]; p[2] = d[2];
                    first = 0;
                }
            }
            usleep(10000);
        }
        close(fd);
        return 0;
    }

    /* almond3s-lcd waittouch <мс> — ждать НОВОЕ нажатие (фронт отпущено→
     * нажато) до таймаута; координаты в stdout. Нужен модальным диалогам:
     * ucode не умеет спать долями секунды, а событийные файлы демона несут
     * хвосты от прошлых нажатий. */
    if (argc >= 3 && strcmp(argv[1], "waittouch") == 0) {
        int ms = atoi(argv[2]);
        int d[3], was = 1, first = 1, t;
        if (ms < 30) ms = 30;
        if (ms > 60000) ms = 60000;
        for (t = 0; t < ms; t += 30) {
            if (ioctl(fd, 1, d) == 0) {
                if (first) { was = d[2]; first = 0; }
                else if (d[2] && !was) {
                    printf("%d %d\n", d[0], d[1]);
                    close(fd);
                    return 0;
                }
                was = d[2];
            }
            usleep(30000);
        }
        close(fd);
        return 1;
    }

    /* almond3s-lcd reinit [kernel|boot] — полный reset+init панели (ioctl 26):
     * лечилка при слетевшем контроллере. С аргументом заодно меняет таблицу
     * инициализации: kernel - вторая заводская (гамма из стокового ядра),
     * boot - таблица загрузчика (наш дефолт). */
    if (argc >= 2 && strcmp(argv[1], "reinit") == 0) {
        unsigned long v = 0;
        if (argc >= 3 && strcmp(argv[2], "kernel") == 0) v = 1;
        else if (argc >= 3 && strcmp(argv[2], "boot") == 0) v = 2;
        int ret = ioctl(fd, 26, v);
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd replay [уровень] — только старт по уже загруженной таблице,
     * без сброса шины. Нужен, чтобы отделить «громкость глушит» от
     * «команда съедает следующую». */
    if (argc >= 2 && strcmp(argv[1], "replay") == 0) {
        struct { int len; unsigned char data[152]; } p;
        /* Сначала глушим предыдущее: без этого воспроизведения
         * накладываются друг на друга и звук растёт с каждым повтором. */
        p.len = 3;
        p.data[0] = 0x2F; p.data[1] = 0x00; p.data[2] = 0x02;
        ioctl(fd, 21, &p);
        usleep(400000);
        if (argc > 2) {
            int lvl = atoi(argv[2]);
            p.len = 3;
            p.data[0] = 0x34; p.data[1] = 0x00; p.data[2] = (unsigned char)lvl;
            ioctl(fd, 21, &p);
            usleep(300000);
        }
        p.len = 3;
        p.data[0] = 0x2F; p.data[1] = 0x00; p.data[2] = 0x01;
        int ret = ioctl(fd, 21, &p);
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd volume 1|2|3 — громкость бипера. Заводской драйвер шлёт
     * {0x34, 0x00, уровень}: три режима раскачки пищалки. */
    if (argc >= 3 && strcmp(argv[1], "volume") == 0) {
        struct { int len; unsigned char data[152]; } p;
        int lvl = atoi(argv[2]);
        if (lvl < 1 || lvl > 3) lvl = 3;
        p.len = 3;
        p.data[0] = 0x34; p.data[1] = 0x00; p.data[2] = (unsigned char)lvl;
        int ret = ioctl(fd, 21, &p);
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd tone <Гц> <мс> | melody | siren — бипер на PIC.
     * Порядок взят из заводского драйвера: сброс шины, стоп, пауза, число
     * нот, таблица частот, таблица длительностей, старт. Байты в таблицах
     * идут старшим вперёд. */
    /* Мгновенный стоп звука: одиночный пакет вне замка, чтобы бить и по
     * играющей мелодии, чей процесс ещё держит lock. */
    if (argc >= 2 && strcmp(argv[1], "stop") == 0) {
        struct { int len; unsigned char data[152]; } p;
        p.len = 3; p.data[0] = 0x2F; p.data[1] = 0x00; p.data[2] = 0x02;
        for (int try = 0; try < 200; try++) {
            if (ioctl(fd, 21, &p) == 0) { close(fd); return 0; }
            usleep(50000);
        }
        close(fd);
        return 1;
    }

    if (argc >= 2 && (strcmp(argv[1], "tone") == 0 ||
                      strcmp(argv[1], "melody") == 0 ||
                      strcmp(argv[1], "march") == 0 ||
                      strcmp(argv[1], "mario") == 0 ||
                      strcmp(argv[1], "bell") == 0 ||
                      strcmp(argv[1], "ambulance") == 0 ||
                      strcmp(argv[1], "police") == 0 ||
                      strcmp(argv[1], "siren") == 0)) {
        static const int mel_f[] = { 1174, 1397, 1397, 1397, 0, 1244, 1568, 1568, 1568, 1200 };
        static const int mel_d[] = {  600,  150,  150,  150, 600,  600,  150,  150,  150,  150 };
        /* Имперский марш: пары «нота, пауза». Таблица в памяти PIC - 64
         * значения, так что помещается целиком. */
        /* Заводские тоны сирены: вынуты из libAlmondHA.so, метод
         * Device::setAlmondSirenTone. Звонок - тон 3. */
        static const int bell_f[] = { 1975, 1975, 1675, 1675, 0 };
        static const int bell_d[] = {  130,  267,  130,  535, 350 };
        static const int amb_f[] = { 2500, 2500, 2500, 2500, 0 };
        static const int amb_d[] = {  130,  130,  130,  130, 350 };
        static const int pol_f[] = { 1000, 2000, 1000, 2000, 1000, 2000 };
        static const int pol_d[] = {  130,  130,  130,  130,  130,  130 };
        static const int mar_f[] = {
            440,0, 440,0, 440,0, 349,0, 523,0, 440,0, 349,0, 523,0, 440,0,
            659,0, 659,0, 659,0, 698,0, 523,0, 415,0, 349,0, 523,0, 440,0 };
        static const int mar_d[] = {
            500,60, 500,60, 500,60, 375,30, 125,30, 500,60, 375,30, 125,30, 650,120,
            500,60, 500,60, 500,60, 375,30, 125,30, 500,30, 375,30, 125,30, 650,120 };
        /* Тема Super Mario Bros (надземный уровень), полная первая фраза.
         * Старый потолок «16 нот / 33 байта» снят: в тач-режиме 2 пакет
         * уходит одной транзакцией Linux-I2C без счётчика SM0_START, предел -
         * таблица PIC на 64 значения (39 проверено вживую). На palmbus-
         * фолбэках потолок прежний. 0 - пауза (драйвер заменит на
         * ультразвук). Частоты проверены: ни один байт не даёт 0xB7/0x8B
         * (те вешают PIC, issue #5) и не совпадает с опкодами. */
        static const int mario_f[] = {
            659,0, 659,0, 659,0, 523,659, 0,784, 0,392, 0,
            523,0, 392,0, 330,0, 440,0, 494,0, 466,440, 0,
            392,659, 784,880, 0,698, 784,0, 659,0, 523,587, 494 };
        static const int mario_d[] = {
            120,30, 120,150, 120,150, 120,120, 150,150, 400,150, 400,
            150,250, 150,250, 150,250, 150,100, 150,100, 120,150, 100,
            150,150, 150,150, 100,150, 150,100, 150,100, 150,150, 200 };
        int f[64], d[64], n = 1;
        int vol = 0, base = 2;
        if (argc > 3 && strcmp(argv[2], "-v") == 0) { vol = atoi(argv[3]); base = 4; }

        if (strcmp(argv[1], "bell") == 0) {
            n = 5;
            for (int i = 0; i < n; i++) { f[i] = bell_f[i]; d[i] = bell_d[i]; }
        } else if (strcmp(argv[1], "ambulance") == 0) {
            n = 5;
            for (int i = 0; i < n; i++) { f[i] = amb_f[i]; d[i] = amb_d[i]; }
        } else if (strcmp(argv[1], "police") == 0) {
            n = 6;
            for (int i = 0; i < n; i++) { f[i] = pol_f[i]; d[i] = pol_d[i]; }
        } else if (strcmp(argv[1], "march") == 0) {
            n = (int)(sizeof(mar_f) / sizeof(mar_f[0]));
            for (int i = 0; i < n; i++) { f[i] = mar_f[i]; d[i] = mar_d[i]; }
        } else if (strcmp(argv[1], "mario") == 0) {
            n = (int)(sizeof(mario_f) / sizeof(mario_f[0]));
            for (int i = 0; i < n; i++) { f[i] = mario_f[i]; d[i] = mario_d[i]; }
        } else if (argv[1][0] == 'm') {
            n = 10;
            for (int i = 0; i < n; i++) { f[i] = mel_f[i]; d[i] = mel_d[i]; }
        } else if (argv[1][0] == 's') {
            n = 10;
            for (int i = 0; i < n; i++) { f[i] = 3000; d[i] = 250; }
        } else {
            n = 0;
            for (int i = base; i + 1 < argc && n < 64; i += 2) {
                f[n] = atoi(argv[i]);
                d[n] = atoi(argv[i + 1]);
                /* Клампим CLI-ввод: отрицательная/огромная длительность иначе
                 * даёт отрицательный total и (unsigned) в usleep -> зависание на
                 * часы; кривая частота ломает pwm_compute. */
                if (f[n] < 0) f[n] = 0; else if (f[n] > 20000) f[n] = 20000;
                if (d[n] < 0) d[n] = 0; else if (d[n] > 2000)  d[n] = 2000;
                n++;
            }
            if (n == 0) { f[0] = 1174; d[0] = 150; n = 1; }
                }

        /* Драйвер шлёт пакет из своего потока по 15 мс на байт (так делает
         * заводской), и на время отправки занят: очередь на один пакет.
         * Поэтому ждём освобождения, а не «на глаз». */
        struct { int len; unsigned char data[152]; } p;

        int send_pkt(const unsigned char *b, int len) {
            memcpy(p.data, b, len);
            p.len = len;
            for (int try = 0; try < 200; try++) {
                if (ioctl(fd, 21, &p) == 0) {
                    /* Запас 60 мс между пакетами был мал: на части плат PIC
                     * не успевает переварить таблицу, ловит переполнение
                     * шины и виснет с погашенными выходами (issue #5,
                     * «звонок» ронял экран). 300 мс держат даже её. */
                    usleep((len * 16 + 300) * 1000);
                    return 0;
                }
                usleep(50000);
            }
            return -1;
        }

        /* Один звук за раз. Загрузка таблицы в чип занимает секунды, а
         * каждое нажатие на странице «Звук» запускает нас заново: без замка
         * несколько экземпляров дерутся за очередь пакетов, и в PIC уезжает
         * мешанина из двух мелодий. */
        int lock = open("/tmp/.lcd_tone.lock", O_CREAT | O_RDWR, 0600);
        /* Не смогли создать/взять замок - выходим, а не играем без него: иначе
         * теряется вся защита «один звук за раз» (гонка -> мешанина в PIC). */
        if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) < 0) {
            if (lock >= 0) close(lock);
            close(fd);
            return 0;
        }

        /* Свой pid - наружу: интерфейс прерывает играющую мелодию новой.
         * TERM на время заливки блокируем: смерть посреди пакета оставляет
         * PIC с полузалитой таблицей и вешает его. Сигнал долетит на фазе
         * ожидания, где убивать безопасно. */
        {
            FILE *pf = fopen("/tmp/.lcd_tone.pid", "w");
            if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); }
        }
        sigset_t sig_term;
        sigemptyset(&sig_term);
        sigaddset(&sig_term, SIGTERM);
        sigprocmask(SIG_BLOCK, &sig_term, NULL);

        /* 0x39 сбрасывает состояние выходов PIC - горевший диод после
         * мелодии молча гас (issue #5 жалуется и на погасший экран: на
         * части плат от выходов PIC зависит и панель). Запоминаем диод и
         * возвращаем его после последовательности. */
        int led_was = 0;
        {
            FILE *lf = fopen("/sys/class/leds/white:status/brightness", "r");
            if (lf) { if (fscanf(lf, "%d", &led_was) != 1) led_was = 0; fclose(lf); }
        }
        void led_restore(void) {
            /* Проигрывание зажигает диод на PIC - после мелодии возвращаем
             * его в состояние ДО: горел - восстановить яркость, не горел -
             * погасить явно, иначе остаётся гореть навсегда. */
            FILE *lf = fopen("/sys/class/leds/white:status/brightness", "w");
            if (lf) { fprintf(lf, "%d\n", led_was > 0 ? led_was : 0); fclose(lf); }
        }

        /* Пауза нулевой частотой ломает чип: pwm_compute делит на частоту, а
         * в делении 32-битных чисел у него нет защиты от нуля - в частное
         * уходит мусор, и мелодия рассыпается на щелчки. Поэтому паузы
         * кодируем ультразвуком: арифметика цела, а слышно ничего. */
        for (int i = 0; i < n; i++)
            if (f[i] <= 0) f[i] = 20000;

        unsigned char ssp[] = { 0x39 };
        unsigned char stop[] = { 0x2F, 0x00, 0x02 };
        unsigned char size[] = { 0x33, 0x00, (unsigned char)n };
        unsigned char play[] = { 0x2F, 0x00, 0x01 };
        unsigned char tbl[152];

        send_pkt(ssp, 1);
        send_pkt(stop, 3);
        usleep(400000);
        send_pkt(size, 3);

        for (int t = 0; t < 2; t++) {
            const int *src = t ? d : f;
            tbl[0] = t ? 0x2E : 0x2D;
            for (int i = 0; i < n; i++) {
                tbl[1 + i * 2] = (src[i] >> 8) & 0xFF;
                tbl[2 + i * 2] = src[i] & 0xFF;
            }
            if (send_pkt(tbl, 1 + n * 2) < 0) {
                send_pkt(stop, 3);
                led_restore();
                close(fd);
                return 1;
            }
        }

        /* Уровень громкости шлём последним, перед самым стартом: команда
         * 0x39 в начале последовательности сбрасывает состояние выходов. */
        if (vol >= 1 && vol <= 3) {
            unsigned char vp[] = { 0x34, 0x00, (unsigned char)vol };
            send_pkt(vp, 3);
        }

        int ret = send_pkt(play, 3);

        /* PIC зациклит таблицу - ждём одно полное проигрывание и глушим.
         * Тик длительности у PIC - полмиллисекунды: при ожидании полного
         * номинала каждая мелодия успевала прозвучать дважды. */
        if (ret == 0) {
            int total = 0;
            for (int i = 0; i < n; i++) total += d[i];
            if (total < 0) total = 0;
            /* Обработчик СТАВИМ ДО разблокировки: накопленный за время
             * заливки TERM иначе убивает процесс прямо тут, финальный stop
             * не уходит, и PIC зацикленно звенит (ловилось на длинных
             * мелодиях - их заливка ~4с, стоп из UI попадал в это окно). */
            signal(SIGTERM, tone_term_handler);
            sigprocmask(SIG_UNBLOCK, &sig_term, NULL);
            unsigned wait_us = (unsigned)total * 500 + 150000;
            if (wait_us > 20000000) wait_us = 20000000;   /* потолок 20с */
            if (!tone_term) usleep(wait_us);
            send_pkt(stop, 3);
        }
        led_restore();
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd led on|off|blink — диод над экраном.
     *
     * Ходим через класс светодиодов ядра, а не своим ioctl: драйвер
     * регистрирует диод как /sys/class/leds/white:status, и управление в
     * обход разошлось бы с состоянием в системе - ровно та же история, что
     * с подсветкой. Мигание аппаратное, его делает сам PIC, поэтому ставим
     * штатный триггер timer с интервалом, который драйвер принимает.
     * Прямой ioctl оставлен запасным путём для сборок со старым драйвером,
     * где светодиода в системе ещё нет. */
    if (argc >= 3 && strcmp(argv[1], "led") == 0 &&
        access("/sys/class/leds/red:status/brightness", W_OK) == 0) {
        static const char *ch[3] = { "red", "green", "blue" };
        const char *hex = argc > 3 ? argv[3] : "ffffff";
        unsigned long rgb = strtoul(hex, NULL, 16);
        int on = strcmp(argv[2], "on") == 0 || strcmp(argv[2], "color") == 0;
        int blink = strcmp(argv[2], "blink") == 0;
        int i;

        for (i = 0; i < 3; i++) {
            char path[96];
            FILE *f;
            int v = (on || blink) ? (int)((rgb >> (16 - 8 * i)) & 0xff) : 0;

            snprintf(path, sizeof(path), "/sys/class/leds/%s:status/trigger", ch[i]);
            if ((f = fopen(path, "w"))) { fputs("none", f); fclose(f); }
            snprintf(path, sizeof(path), "/sys/class/leds/%s:status/brightness", ch[i]);
            if ((f = fopen(path, "w"))) { fprintf(f, "%d", v); fclose(f); }
            if (blink && v) {
                snprintf(path, sizeof(path), "/sys/class/leds/%s:status/trigger", ch[i]);
                if ((f = fopen(path, "w"))) { fputs("timer", f); fclose(f); }
                snprintf(path, sizeof(path), "/sys/class/leds/%s:status/delay_on", ch[i]);
                if ((f = fopen(path, "w"))) { fputs("250", f); fclose(f); }
                snprintf(path, sizeof(path), "/sys/class/leds/%s:status/delay_off", ch[i]);
                if ((f = fopen(path, "w"))) { fputs("250", f); fclose(f); }
            }
        }
        close(fd);
        return 0;
    }

    if (argc >= 3 && strcmp(argv[1], "led") == 0) {
        static const char *dir = "/sys/class/leds/white:status";
        char path[128];
        FILE *f;
        int on = strcmp(argv[2], "on") == 0;
        int blink = strcmp(argv[2], "blink") == 0;

        snprintf(path, sizeof(path), "%s/brightness", dir);
        if (access(path, W_OK) == 0) {
            snprintf(path, sizeof(path), "%s/trigger", dir);
            if ((f = fopen(path, "w"))) {
                fputs(blink ? "timer" : "none", f);
                fclose(f);
            }
            if (blink) {
                snprintf(path, sizeof(path), "%s/delay_on", dir);
                if ((f = fopen(path, "w"))) { fputs("250", f); fclose(f); }
                snprintf(path, sizeof(path), "%s/delay_off", dir);
                if ((f = fopen(path, "w"))) { fputs("250", f); fclose(f); }
            } else {
                snprintf(path, sizeof(path), "%s/brightness", dir);
                if ((f = fopen(path, "w"))) { fputs(on ? "1" : "0", f); fclose(f); }
            }
            close(fd);
            return 0;
        }

        int c = on ? 0x32 : blink ? 0x30 : 0x31;
        int ret = ioctl(fd, 9, (unsigned long)(10000 + c));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd level — текущая яркость (ioctl 17). */
    if (argc >= 2 && strcmp(argv[1], "level") == 0) {
        int lvl[2] = { -1, -1 };
        if (ioctl(fd, 17, lvl) == 0)
            printf("подсветка %d, картинка %d\n", lvl[0], lvl[1]);
        close(fd);
        return 0;
    }

    /* almond3s-lcd gray <0..255> — цифровое затемнение картинки (ioctl 19). */
    if (argc >= 3 && strcmp(argv[1], "gray") == 0) {
        int ret = ioctl(fd, 19, (unsigned long)atoi(argv[2]));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd warm <0..100> — тёплый вечерний фильтр (ioctl 27). */
    if (argc >= 3 && strcmp(argv[1], "warm") == 0) {
        int ret = ioctl(fd, 27, (unsigned long)atoi(argv[2]));
        close(fd);
        return ret < 0 ? 1 : 0;
    }

    /* almond3s-lcd stat — сколько строк ушло на панель в последнем кадре. */
    if (argc >= 2 && strcmp(argv[1], "stat") == 0) {
        int d[3] = { -1, -1, -1 };
        if (ioctl(fd, 18, d) == 0)
            printf("строк %d, время %d мкс, кадров %d\n", d[0], d[1], d[2]);
        close(fd);
        return 0;
    }

    /* almond3s-lcd blstat — окна подсветки: самая длинная тёмная и светлая
     * паузы с прошлого чтения и счётчики затянувшихся. Нужно, чтобы отличить
     * «панель показывает чёрное» от «ШИМ застрял в тёмной фазе»: во втором
     * случае dim и светодиод честно рапортуют включённый экран, а света нет.
     * Чтение обнуляет счётчики - каждый вызов даёт максимум за интервал. */
    if (argc >= 2 && strcmp(argv[1], "blstat") == 0) {
        int d[4] = { -1, -1, -1, -1 };
        if (ioctl(fd, 25, d) == 0)
            printf("тьма_макс=%d мкс, затянувшихся=%d, свет_макс=%d мкс, затянувшихся=%d\n",
                   d[0], d[1], d[2], d[3]);
        else
            printf("blstat недоступен\n");
        close(fd);
        return 0;
    }

    /* almond3s-lcd pic — сырые 17 байт статуса PIC (ioctl 3).
     * Нужно, чтобы ловить, докладывает ли PIC о нажатиях кнопки питания:
     * до ядра она не доходит, вся надежда на эти байты. */
    if (argc >= 2 && strcmp(argv[1], "pic") == 0) {
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

    /* almond3s-lcd daemon — background poller (fork) */
    if (argc >= 2 && strcmp(argv[1], "daemon") == 0) {
        return daemon_mode(fd);
    }

    /* almond3s-lcd daemon_fg — foreground poller (for procd) */
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
            } else if (data[2] && was_pressed) {
                /* Палец прижат - движение в ОТДЕЛЬНЫЙ файл: в общем оно
                 * затирало событие нажатия раньше, чем интерфейс успевал
                 * его прочитать, и тапы терялись. */
                FILE *out = fopen(TOUCH_FILE ".move", "w");
                if (out) { fprintf(out, "%d %d\n", data[0], data[1]); fclose(out); }
            } else if (!data[2]) {
                was_pressed = 0;
            }
            usleep(50000);
        }
        close(fd);
        return 0;
    }

    /* Демо-режим только по явному слову. Раньше он стоял умолчанием, и любая
       опечатка или команда без обязательного значения (например «gray» без
       числа) вместо ошибки уводила сюда: процесс захватывал /dev/lcd, рисовал
       красный прицел по каждому касанию и висел, пока его не убьют. */
    if (argc >= 2 && strcmp(argv[1], "demo") == 0)
        return demo_mode(fd);

    fprintf(stderr,
            "almond3s-lcd: неизвестная команда%s%s\n"
            "  подсветка: bl 0|1 | dim 0..255 | gray 0..255 | warm 0..100 | pwm <мкс>\n"
            "  панель:    scene N | matrixline <текст> | reinit | rotate 0|1\n"
            "  сведения:  version | stats | stat | blstat | bench | level | pic\n"
            "  касания:   touchmode N | waittouch <мс> | daemon | daemon_fg\n"
            "  звук:      volume N | tone | melody | bell | siren | stop\n"
            "  проверка:  demo\n",
            argc >= 2 ? ": " : "", argc >= 2 ? argv[1] : "");
    close(fd);
    return 1;
}
