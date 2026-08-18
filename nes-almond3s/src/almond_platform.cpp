#include "almond_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <dirent.h>
#include <linux/input.h>
#include <pthread.h>
#include <signal.h>

#define FB_SZ (LCD_W * LCD_H * 2)
#define FRAME_US (1000000 / 60)
#define X_OFF ((LCD_W - NES_W) / 2)

#define TOUCH_PATH "/tmp/.lcd_touch"
#define TOUCH_MOVE "/tmp/.lcd_touch.move"

#define BAR_L_X1   32
#define BAR_R_X0   288
#define BTN_EXIT_Y1   28
#define BTN_B_Y0      58
#define BTN_B_Y1      144
#define BTN_A_Y0      148
#define BTN_A_Y1      236
#define BTN_START_Y1  28
#define BTN_SEL_Y1    56
#define BTN_UP_Y0     58
#define BTN_UP_Y1     144
#define BTN_DN_Y0     148
#define BTN_DN_Y1     236

/* Два кадровых буфера: пока панель забирает один, эмуляция рисует во второй.
   Раньше write() в /dev/lcd блокировал цикл на 4-8 мс - передача 150 КБ по
   GPIO идёт вручную, - и кадр то укладывался в свои 16.6 мс, то нет. Именно
   этот разброс и виден как рывки: сама эмуляция успевает всегда. */
static unsigned short fbuf[2][LCD_W * LCD_H];
static unsigned short *fb = fbuf[0];
static int fb_cur;
static int lcd_fd = -1;
static int quit_now;

static pthread_mutex_t wr_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  wr_c = PTHREAD_COND_INITIALIZER;
static int wr_idx = -1;        /* готовый кадр для панели, -1 - нет */
static int wr_stop;
static pthread_t wr_th;
static int wr_run;
static int panel_us = FRAME_US;   /* сколько панель тратит на кадр, замер на ходу */
static int panel_peak = FRAME_US; /* тяжёлый кадр: по нему считаем ритм */

static void *writer_thread(void *arg)
{
    (void)arg;
    for (;;) {
        int idx;
        pthread_mutex_lock(&wr_m);
        while (wr_idx < 0 && !wr_stop) pthread_cond_wait(&wr_c, &wr_m);
        if (wr_stop) { pthread_mutex_unlock(&wr_m); break; }
        idx = wr_idx;
        pthread_mutex_unlock(&wr_m);

        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        lseek(lcd_fd, 0, SEEK_SET);
        write(lcd_fd, fbuf[idx], FB_SZ);
        clock_gettime(CLOCK_MONOTONIC, &b);
        {
            long d = (b.tv_sec - a.tv_sec) * 1000000L + (b.tv_nsec - a.tv_nsec) / 1000;
            panel_us += (int)((d - panel_us) / 8);   /* сглаженная оценка */
            /* Для ритма важен не средний кадр, а тяжёлый: рывок создаёт именно
               он. Держим медленно оседающий максимум - шаг равняется на худший
               случай, и панель перестаёт отставать рывками. */
            if (d > panel_peak) panel_peak = (int)d;
            else                panel_peak -= panel_peak / 64;
        }

        pthread_mutex_lock(&wr_m);
        wr_idx = -1;
        pthread_cond_signal(&wr_c);
        pthread_mutex_unlock(&wr_m);
    }
    return NULL;
}

/* Отдать нарисованный кадр панели. Если она ещё не управилась с предыдущим,
   кадр не ждём, а пропускаем: эмуляция важнее, темп игры должен быть ровным. */
static int fb_publish(void)
{
    int taken = 0;
    if (!wr_run) {                     /* поток не поднялся - пишем сами */
        lseek(lcd_fd, 0, SEEK_SET);
        write(lcd_fd, fb, FB_SZ);
        return 1;
    }
    pthread_mutex_lock(&wr_m);
    if (wr_idx < 0) {
        wr_idx = fb_cur;
        fb_cur ^= 1;
        fb = fbuf[fb_cur];
        taken = 1;
        pthread_cond_signal(&wr_c);
    }
    pthread_mutex_unlock(&wr_m);
    return taken;
}

static void writer_finish(void)
{
    if (!wr_run) return;
    pthread_mutex_lock(&wr_m);
    while (wr_idx >= 0) pthread_cond_wait(&wr_c, &wr_m);
    wr_stop = 1;
    pthread_cond_signal(&wr_c);
    pthread_mutex_unlock(&wr_m);
    pthread_join(wr_th, NULL);
    wr_run = 0;
}

/* Сетевой джойстик: телефон по Wi-Fi. Ввод ДОБАВЛЯЕТСЯ к экранному. */
int  pad_net_init(void);
void pad_net_poll(void);
int  pad_net_state(int player);
void pad_net_stop(void);

/* ---- клавиатура ---- */
#define MAX_KBD 4
static int kbd_fd[MAX_KBD], kbd_n;
static unsigned char keys[KEY_MAX + 1];

static void kbd_open(void)
{
    DIR* d = opendir("/dev/input");
    struct dirent* e;
    char path[64];
    if (!d) return;
    while ((e = readdir(d)) && kbd_n < MAX_KBD) {
        if (strncmp(e->d_name, "event", 5)) continue;
        snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd >= 0) kbd_fd[kbd_n++] = fd;
    }
    closedir(d);
}

static void kbd_poll(void)
{
    struct input_event ev;
    for (int i = 0; i < kbd_n; i++)
        while (read(kbd_fd[i], &ev, sizeof ev) == (int)sizeof ev)
            if (ev.type == EV_KEY && ev.code <= KEY_MAX)
                keys[ev.code] = (ev.value != 0);
}

/* ---- тачскрин ---- */
static int latch_b, hold_left, hold_right;
static int hold_a, hold_start, hold_select, hold_up, hold_dn;
static int last_dir, jump_dir;
#define JUMP_DIR_FRAMES 38

static void touch_poll(void)
{
    char b[64];
    int fd, n, x, y, held = 0;

    fd = open(TOUCH_PATH, O_RDONLY);
    if (fd < 0) { fd = open(TOUCH_MOVE, O_RDONLY); held = 1; }
    if (fd < 0) return;
    n = read(fd, b, sizeof b - 1);
    close(fd);
    unlink(held ? TOUCH_MOVE : TOUCH_PATH);
    if (n <= 0) return;
    b[n] = 0;
    if (sscanf(b, "%d %d", &x, &y) != 2) return;

    if (x < BAR_L_X1) {
        if (y < BTN_START_Y1)      { if (!held) hold_start = 8; }
        else if (y < BTN_SEL_Y1)   { if (!held) hold_select = 8; }
        else if (y < BTN_UP_Y1)      hold_up = 4;
        else if (y >= BTN_DN_Y0)     hold_dn = 4;
        return;
    }
    if (x >= BAR_R_X0) {
        if (y < BTN_EXIT_Y1)       { if (!held) quit_now = 1; }
        else if (y < BTN_B_Y0)       return;      /* пустое место под крестиком */
        else if (y < BTN_B_Y1)     { if (!held) latch_b = !latch_b; }
        else {
            if (!hold_a && last_dir) jump_dir = JUMP_DIR_FRAMES;
            hold_a = 6;
        }
        return;
    }
    /* Игровое поле: держишь - идёт. Мёртвая зона у полос: тач резистивный, у
       краёв координата уезжает, и нажатие на кнопку попадало бы в поле. */
    if (x < BAR_L_X1 + 16 || x >= BAR_R_X0 - 16) return;
    if (x < LCD_W / 2) { hold_left = 5; hold_right = 0; last_dir = -1; }
    else               { hold_right = 5; hold_left = 0; last_dir = 1; }
}

/* Раскладка клавиатуры: по умолчанию привычная, но экран настройки может
   переписать её в /etc/almond3s/nes_keys - по строке «действие код» на
   каждое переназначенное действие. Второй столбец кодов - запасные клавиши,
   их настройка не трогает. */
enum { K_A, K_B, K_START, K_SELECT, K_UP, K_DOWN, K_LEFT, K_RIGHT, K_EXIT, K_N };

static const char *KEY_NAME[K_N] = {
    "a", "b", "start", "select", "up", "down", "left", "right", "exit"
};
static const int KEY_DEF[K_N] = {
    KEY_X, KEY_Z, KEY_ENTER, KEY_LEFTSHIFT,
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ESC
};
static const int KEY_ALT[K_N] = {
    KEY_K, KEY_J, KEY_KPENTER, KEY_RIGHTSHIFT, 0, 0, 0, 0, 0
};
static int keymap[K_N];

static void keymap_load(void)
{
    char buf[512];
    int fd, n;
    for (int i = 0; i < K_N; i++) keymap[i] = KEY_DEF[i];

    fd = open("/etc/almond3s/nes_keys", O_RDONLY);
    if (fd < 0) return;
    n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = 0;

    for (char *ln = strtok(buf, "\n"); ln; ln = strtok(NULL, "\n")) {
        char name[32];
        int code;
        if (sscanf(ln, "%31s %d", name, &code) != 2) continue;
        if (code <= 0 || code > KEY_MAX) continue;
        for (int i = 0; i < K_N; i++)
            if (!strcmp(name, KEY_NAME[i])) keymap[i] = code;
    }
}

static int key_down(int act)
{
    return keys[keymap[act]] || (KEY_ALT[act] && keys[KEY_ALT[act]]);
}

static int pad_state(void)
{
    int p = 0;
    kbd_poll();
    touch_poll();
    pad_net_poll();
    p |= pad_net_state(0);      /* первый игрок: телефон поверх экрана и клавиатуры */

    if (key_down(K_EXIT))   quit_now = 1;
    if (key_down(K_A))      p |= P_A;
    if (key_down(K_B))      p |= P_B;
    if (key_down(K_START))  p |= P_START;
    if (key_down(K_SELECT)) p |= P_SELECT;
    if (key_down(K_UP))     p |= P_UP;
    if (key_down(K_DOWN))   p |= P_DOWN;
    if (key_down(K_LEFT))   p |= P_LEFT;
    if (key_down(K_RIGHT))  p |= P_RIGHT;

    if (hold_left)   { p |= P_LEFT;  hold_left--; }
    if (hold_right)  { p |= P_RIGHT; hold_right--; }
    if (latch_b)       p |= P_B;
    if (hold_a)      { p |= P_A;      hold_a--; }
    if (hold_start)  { p |= P_START;  hold_start--; }
    if (hold_select) { p |= P_SELECT; hold_select--; }
    if (hold_up)     { p |= P_UP;     hold_up--; }
    if (hold_dn)     { p |= P_DOWN;   hold_dn--; }
    if (jump_dir) {
        jump_dir--;
        if (!hold_left && !hold_right)
            p |= (last_dir < 0) ? P_LEFT : P_RIGHT;
    }
    return p;
}

/* ---- отрисовка ---- */
static void box(int x0, int y0, int x1, int y1, unsigned short c)
{
    for (int y = y0; y < y1 && y < LCD_H; y++)
        for (int x = x0; x < x1 && x < LCD_W; x++)
            if (x >= 0 && y >= 0) fb[y * LCD_W + x] = c;
}

static const struct { char ch; unsigned char col[5]; } FONT[] = {
    { 'A', { 0x7E,0x11,0x11,0x11,0x7E } }, { 'B', { 0x7F,0x49,0x49,0x49,0x36 } },
    { 'C', { 0x3E,0x41,0x41,0x41,0x22 } }, { 'E', { 0x7F,0x49,0x49,0x49,0x41 } },
    { 'L', { 0x7F,0x40,0x40,0x40,0x40 } }, { 'R', { 0x7F,0x09,0x19,0x29,0x46 } },
    { 'S', { 0x46,0x49,0x49,0x49,0x31 } }, { 'T', { 0x01,0x01,0x7F,0x01,0x01 } },
    { 'X', { 0x63,0x14,0x08,0x14,0x63 } }, { 'I', { 0x00,0x41,0x7F,0x41,0x00 } },
    { 'O', { 0x3E,0x41,0x41,0x41,0x3E } }, { 'N', { 0x7F,0x04,0x08,0x10,0x7F } },
    { 'G', { 0x3E,0x41,0x49,0x49,0x7A } },
};

static void draw_char(int x, int y, char ch, unsigned short c, int sc)
{
    for (unsigned i = 0; i < sizeof FONT / sizeof FONT[0]; i++) {
        if (FONT[i].ch != ch) continue;
        for (int col = 0; col < 5; col++)
            for (int row = 0; row < 7; row++)
                if (FONT[i].col[col] & (1 << row))
                    box(x + col * sc, y + row * sc, x + col * sc + sc, y + row * sc + sc, c);
        return;
    }
}

static void tri(int cx, int cy, int dir, unsigned short c)
{
    for (int i = 0; i < 8; i++)
        box(cx - i, cy + dir * (4 - i), cx + i + 1, cy + dir * (4 - i) + 1, c);
}

/* Объёмная кнопка: заливка плюс светлая полоска сверху и справа - так же, как
   выглядят кнопки в остальном интерфейсе. */
static void btn3d(int x0, int y0, int x1, int y1, unsigned short fill, unsigned short lit)
{
    box(x0, y0, x1, y1, fill);
    box(x0, y0, x1, y0 + 2, lit);
    box(x1 - 2, y0, x1, y1, lit);
}

/* Треугольник «play» вместо слова START: шесть букв в 32px полосу не влезают. */
static void icon_play(int cx, int cy, unsigned short c)
{
    for (int i = 0; i < 5; i++)
        box(cx - 2 + i, cy - 4 + i, cx - 1 + i, cy + 5 - i, c);
}

/* Крестик вместо слова EXIT. */
static void icon_x(int cx, int cy, unsigned short c)
{
    for (int i = -5; i <= 5; i++) {
        box(cx + i, cy + i, cx + i + 2, cy + i + 2, c);
        box(cx + i, cy - i, cx + i + 2, cy - i + 2, c);
    }
}

/* Узкий шрифт 3x5 - только под слово SELECT: обычным оно шире полосы. */
static const struct { char ch; unsigned char col[3]; } FONT3[] = {
    { 'S', { 0x17,0x15,0x1D } }, { 'E', { 0x1F,0x15,0x11 } },
    { 'L', { 0x1F,0x10,0x10 } }, { 'C', { 0x0E,0x11,0x11 } },
    { 'T', { 0x01,0x1F,0x01 } },
};

static void draw_tiny(int x, int y, const char *t, unsigned short c)
{
    for (; *t; t++, x += 4)
        for (unsigned i = 0; i < sizeof FONT3 / sizeof FONT3[0]; i++) {
            if (FONT3[i].ch != *t) continue;
            for (int col = 0; col < 3; col++)
                for (int row = 0; row < 5; row++)
                    if (FONT3[i].col[col] & (1 << row))
                        box(x + col, y + row, x + col + 1, y + row + 1, c);
            break;
        }
}

/* Выход занимает заметное время: гаснет эмулятор, поднимается интерфейс. Без
   отклика непонятно, нажалось ли вообще, поэтому закрашиваем экран и пишем. */
static void draw_closing(void)
{
    /* Шрифт кнопок латинский, поэтому нужные буквы держим отдельной таблицей:
       ради одной фразы тащить сюда весь кириллический набор незачем. */
    static const unsigned char RUF[][5] = {
        { 0x7F,0x20,0x10,0x08,0x7F },   /* 0  И */
        { 0x7F,0x01,0x01,0x01,0x01 },   /* 1  Г */
        { 0x7F,0x09,0x09,0x09,0x06 },   /* 2  Р */
        { 0x7E,0x11,0x11,0x11,0x7E },   /* 3  А */
        { 0x00,0x00,0x00,0x00,0x00 },   /* 4  пробел */
        { 0x22,0x41,0x49,0x49,0x36 },   /* 5  З */
        { 0x7F,0x08,0x14,0x22,0x41 },   /* 6  К */
        { 0x7F,0x48,0x48,0x30,0x7F },   /* 7  Ы */
        { 0x7F,0x49,0x49,0x49,0x36 },   /* 8  В */
        { 0x7F,0x49,0x49,0x49,0x41 },   /* 9  Е */
        { 0x01,0x01,0x7F,0x01,0x01 },   /* 10 Т */
        { 0x3E,0x41,0x41,0x41,0x22 },   /* 11 С */
        { 0x46,0x29,0x19,0x09,0x7F },   /* 12 Я */
        { 0x40,0x00,0x00,0x00,0x00 },   /* 13 точка */
    };
    /* ИГРА ЗАКРЫВАЕТСЯ... */
    static const unsigned char MSG[] = {
        0,1,2,3, 4, 5,3,6,2,7,8,3,9,10,11,12, 13,13,13
    };
    const int n = (int)(sizeof MSG / sizeof MSG[0]);
    const int sc = 2, step = 6 * sc;
    int x0 = (LCD_W - (n * step - sc)) / 2, y0 = 112;

    box(0, 0, LCD_W, LCD_H, 0x0000);
    for (int g = 0; g < n; g++)
        for (int col = 0; col < 5; col++)
            for (int row = 0; row < 7; row++)
                if (RUF[MSG[g]][col] & (1 << row))
                    box(x0 + g * step + col * sc, y0 + row * sc,
                        x0 + g * step + col * sc + sc, y0 + row * sc + sc, 0xFFFF);
    if (lcd_fd >= 0) {
        lseek(lcd_fd, 0, SEEK_SET);
        write(lcd_fd, fb, FB_SZ);
    }
}

static void draw_bars_one(void)
{
    /* Кнопки отступают на 1px от края, обращённого к экрану: левые - справа,
       правые - слева, иначе они прилипают к картинке. Зазоры между всеми
       кнопками одинаковые, по 4px. */
    const int LX0 = 1,  LX1 = 30;
    const int RX0 = BAR_R_X0 + 2, RX1 = LCD_W - 1;
    const unsigned short BLACK = 0x0000, GREY = 0x4208, LIT = 0x6B4D;
    const unsigned short ON = 0x07E0, RED = 0xC000, WHITE = 0xFFFF;

    box(0, 0, BAR_L_X1, LCD_H, BLACK);
    box(BAR_R_X0, 0, LCD_W, LCD_H, BLACK);

    btn3d(LX0, 2, LX1, BTN_START_Y1 - 2, hold_start ? ON : GREY, LIT);
    icon_play((LX0 + LX1) / 2, (2 + BTN_START_Y1 - 2) / 2, WHITE);
    btn3d(LX0, BTN_START_Y1 + 2, LX1, BTN_SEL_Y1 - 2, hold_select ? ON : GREY, LIT);
    draw_tiny(LX0 + 4, (BTN_START_Y1 + BTN_SEL_Y1) / 2 - 2, "SELECT", WHITE);
    btn3d(LX0, BTN_UP_Y0, LX1, BTN_UP_Y1, hold_up ? ON : GREY, LIT);
    tri((LX0 + LX1) / 2, (BTN_UP_Y0 + BTN_UP_Y1) / 2, -1, WHITE);
    btn3d(LX0, BTN_DN_Y0, LX1, BTN_DN_Y1, hold_dn ? ON : GREY, LIT);
    tri((LX0 + LX1) / 2, (BTN_DN_Y0 + BTN_DN_Y1) / 2, 1, WHITE);

    btn3d(RX0, 2, RX1, BTN_EXIT_Y1 - 2, RED, 0xE800);
    icon_x((RX0 + RX1) / 2, (2 + BTN_EXIT_Y1 - 2) / 2, WHITE);
    btn3d(RX0, BTN_B_Y0, RX1, BTN_B_Y1, latch_b ? ON : GREY, LIT);
    draw_char((RX0 + RX1) / 2 - 7, (BTN_B_Y0 + BTN_B_Y1) / 2 - 10, 'B', WHITE, 3);
    btn3d(RX0, BTN_A_Y0, RX1, BTN_A_Y1, hold_a ? ON : GREY, LIT);
    draw_char((RX0 + RX1) / 2 - 7, (BTN_A_Y0 + BTN_A_Y1) / 2 - 10, 'A', WHITE, 3);
}

/* Полосы меняются редко, а буфера два - рисуем сразу в оба, иначе после обмена
   на экран попали бы кнопки от позапрошлого кадра. */
static void draw_bars(void)
{
    unsigned short *save = fb;
    for (int i = 0; i < 2; i++) {
        fb = fbuf[i];
        draw_bars_one();
    }
    fb = save;
}

/* ---- настройки ----
   Раньше их читало каждое ядро само, и настройка, добавленная к одному, во
   втором молчала. Теперь читает слой - ядро о них не знает. */
/* Звук. На этой плате динамик висит на PIC, а не на звуковой шине, поэтому
   выхода тут нет и по умолчанию звук выключен. Выключатель сделан заранее,
   под железо с нормальным динамиком: сэмплы уходят в aplay, а он уже разбира-
   ется с ALSA. Трубу держим неблокирующей и глотаем SIGPIPE - иначе стоило бы
   aplay захлебнуться или умереть, и эмуляция встала бы вместе с ним. */
static int sound_want;    /* чего просит настройка */
static int sound_on;      /* что реально открыто */
static FILE *snd_pipe;
static int snd_fd = -1;
static short snd_buf[4096];
static int snd_no_out;    /* выхода нет - больше не пробуем и не сорим в лог */

static void sound_apply(const nes_core_t *core)
{
    char cmd[128];
    int rate;

    if (sound_want == sound_on) return;

    if (!sound_want) {
        if (snd_pipe) { pclose(snd_pipe); snd_pipe = NULL; snd_fd = -1; }
        if (core->audio_close) core->audio_close();
        sound_on = 0;
        return;
    }
    if (!core->audio_open || !core->audio_read) {
        fprintf(stderr, "%s: звук: ядро его не отдаёт\n", core->name);
        sound_want = 0;
        return;
    }
    /* popen отдаёт успех, даже если команды нет вовсе: оболочка стартует и
       тут же умирает. Поэтому выход проверяем заранее сами, иначе настройка
       рапортовала бы о включённом звуке в полной тишине - и ядро зря считало
       бы каналы. */
    if (snd_no_out) { sound_want = 0; return; }
    if (access("/dev/snd", F_OK) != 0 ||
        (access("/usr/bin/aplay", X_OK) != 0 && access("/bin/aplay", X_OK) != 0)) {
        fprintf(stderr, "%s: звук: выхода нет (нужны /dev/snd и aplay)\n", core->name);
        snd_no_out = 1;
        sound_want = 0;
        return;
    }
    rate = core->audio_open();
    if (rate <= 0) { sound_want = 0; return; }

    snprintf(cmd, sizeof cmd,
             "aplay -q -t raw -f S16_LE -c 1 -r %d - 2>/dev/null", rate);
    snd_pipe = popen(cmd, "w");
    if (!snd_pipe) {
        fprintf(stderr, "%s: звук: aplay не запустился\n", core->name);
        if (core->audio_close) core->audio_close();
        sound_want = 0;
        return;
    }
    snd_fd = fileno(snd_pipe);
    fcntl(snd_fd, F_SETFL, O_NONBLOCK);
    sound_on = 1;
    fprintf(stderr, "%s: звук включён, %d Гц\n", core->name, rate);
}

/* Сэмплы отдаём в трубу как получится: не влезли - выбрасываем. Ровный темп
   картинки важнее, чем целость звука на железе, которого пока нет. */
static void sound_pump(const nes_core_t *core)
{
    int n;
    if (!sound_on) return;
    n = core->audio_read(snd_buf, (int)(sizeof snd_buf / sizeof snd_buf[0]));
    if (n > 0 && snd_fd >= 0)
        (void)!write(snd_fd, snd_buf, (size_t)n * sizeof snd_buf[0]);
}

static int fps_mode;      /* 0 - все кадры, 1 - 45, 2 - 30 */
static int cadence_even = 1;  /* по умолчанию: кадры через равные промежутки */
static int blend_mode;    /* 0 - выкл, 1 - полусумма, 2 - максимум */

static int read_word(const char *path, char *buf, int len)
{
    int fd = open(path, O_RDONLY), n;
    if (fd < 0) return 0;
    n = read(fd, buf, len - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    return 1;
}

static void settings_reload(void)
{
    static int tick;
    char c[16];
    if (++tick < 60) return;
    tick = 0;
    if (read_word("/etc/almond3s/nes_fps", c, sizeof c)) {
        if (!strncmp(c, "all", 3))     fps_mode = 0;
        else if (!strncmp(c, "45", 2)) fps_mode = 1;
        else if (!strncmp(c, "30", 2)) fps_mode = 2;
    }
    keymap_load();
    if (read_word("/etc/almond3s/nes_sound", c, sizeof c))
        sound_want = !strncmp(c, "on", 2);
    if (read_word("/etc/almond3s/nes_cadence", c, sizeof c))
        cadence_even = !strncmp(c, "even", 4);
    if (read_word("/etc/almond3s/nes_blend", c, sizeof c)) {
        if (!strncmp(c, "off", 3))     blend_mode = 0;
        else if (!strncmp(c, "avg", 3)) blend_mode = 1;
        else if (!strncmp(c, "max", 3)) blend_mode = 2;
    }
}

/* Склейка работает уже на готовой картинке в RGB565, поэтому одинаково годится
   любому ядру. Игры мигают спрайтом раз в кадр (неуязвимость после удара, и так
   же обходят предел в 8 спрайтов на строку); при выброшенных кадрах герой может
   пропасть совсем, а смесь с предыдущим кадром возвращает его на место - так
   это и выглядело на ЭЛТ. */
static unsigned short scratch[NES_W * NES_H];
static unsigned short prevf[NES_W * NES_H];

static void present(const nes_core_t *core)
{
    if (!blend_mode) {                       /* обычный путь: ядро пишет прямо в кадр */
        core->picture(&fb[X_OFF], LCD_W);
        return;
    }
    core->picture(scratch, NES_W);
    for (int y = 0; y < NES_H; y++) {
        unsigned short *s = &scratch[y * NES_W];
        unsigned short *p = &prevf[y * NES_W];
        unsigned short *d = &fb[y * LCD_W + X_OFF];
        for (int x = 0; x < NES_W; x++) {
            unsigned short a = s[x], b = p[x];
            if (blend_mode == 1) {
                d[x] = (unsigned short)(((a & 0xF7DE) >> 1) + ((b & 0xF7DE) >> 1));
            } else {
                unsigned short r = (a & 0xF800) > (b & 0xF800) ? (a & 0xF800) : (b & 0xF800);
                unsigned short g = (a & 0x07E0) > (b & 0x07E0) ? (a & 0x07E0) : (b & 0x07E0);
                unsigned short bl = (a & 0x001F) > (b & 0x001F) ? (a & 0x001F) : (b & 0x001F);
                d[x] = r | g | bl;
            }
            p[x] = a;
        }
    }
}

int platform_main(int argc, char **argv, const nes_core_t *core)
{
    if (argc != 2) {
        fprintf(stderr, "%s <файл.nes>\n", core->name);
        return 1;
    }
    if (core->load(argv[1]) != 0) {
        fprintf(stderr, "%s: не удалось загрузить %s\n", core->name, argv[1]);
        return 1;
    }

    lcd_fd = open("/dev/lcd", O_RDWR);
    if (lcd_fd < 0) { perror("/dev/lcd"); return 1; }
    memset(fb, 0, sizeof fb);
    /* Залежавшееся касание сработало бы первым же кадром - вплоть до выхода. */
    unlink(TOUCH_PATH);
    unlink(TOUCH_MOVE);
    signal(SIGPIPE, SIG_IGN);   /* см. комментарий у звука */
    kbd_open();
    keymap_load();
    if (pthread_create(&wr_th, NULL, writer_thread, NULL) == 0) wr_run = 1;
    else fprintf(stderr, "%s: поток вывода не запустился, рисуем как раньше\n", core->name);
    {
        int port = pad_net_init();
        if (port > 0)
            fprintf(stderr, "%s: джойстик в браузере на порту %d\n", core->name, port);
        else
            fprintf(stderr, "%s: сетевой джойстик не поднялся\n", core->name);
    }
    draw_bars();

    long next = 0, t_sec = 0, us_write = 0, us_pad = 0, cad_acc = 0;
    int frames = 0, fr = 0, bars_state = -1, shown = 0, dropped = 0;

    while (!quit_now) {
        struct timespec p0, p1;
        clock_gettime(CLOCK_MONOTONIC, &p0);
        int pd1 = pad_state(), pd2 = pad_net_state(1);   /* второй игрок - только сеть */
        clock_gettime(CLOCK_MONOTONIC, &p1);
        us_pad += (p1.tv_sec - p0.tv_sec) * 1000000L + (p1.tv_nsec - p0.tv_nsec) / 1000;
        core->run_frame(pd1, pd2);
        settings_reload();
        sound_apply(core);
        sound_pump(core);

        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        long now = ts.tv_sec * 1000000L + ts.tv_nsec / 1000;

        /* Панель тянет меньше, чем считает эмуляция, поэтому часть кадров
           всё равно не доедет. Вопрос в том, КАК их пропускать. Отдавая кадр
           «как только панель освободилась», мы роняем их вразнобой: то два
           подряд ушли, то один пропал - глаз читает это как рывки, хотя
           кадров в секунду много. Ровный ритм отдаёт реже, но через равные
           промежутки, и движение выглядит плавнее при меньшем числе кадров.
           Шаг считаем в тысячных долях кадра эмуляции - получается ровная
           раскладка вида «3 из 4» без дробной арифметики. */
        int show;
        if (cadence_even) {
            long step = ((long)panel_peak * 1000) / FRAME_US;
            if (step < 1000) step = 1000;
            cad_acc += 1000;
            show = 0;
            if (cad_acc >= step) { cad_acc -= step; show = 1; }
        } else {
            show = 1;
        }
        /* Ручной предел «Кадры» действует и поверх ровного ритма: он только
           убавляет, поэтому две настройки не спорят друг с другом. */
        if (fps_mode == 2 && (fr & 1)) show = 0;
        if (fps_mode == 1 && (fr & 3) == 3) show = 0;
        fr++;

        long t0 = 0, t1 = 0;
        if (show) {
            present(core);
            int st = latch_b | (hold_a ? 2 : 0) | (hold_left ? 4 : 0) |
                     (hold_right ? 8 : 0) | (hold_up ? 16 : 0) | (hold_dn ? 32 : 0) |
                     (hold_start ? 64 : 0) | (hold_select ? 128 : 0);
            if (st != bars_state) { bars_state = st; draw_bars(); }
            struct timespec w0, w1;
            clock_gettime(CLOCK_MONOTONIC, &w0);
            if (fb_publish()) shown++;
            else              dropped++;
            clock_gettime(CLOCK_MONOTONIC, &w1);
            t0 = (w1.tv_sec - w0.tv_sec) * 1000000L + (w1.tv_nsec - w0.tv_nsec) / 1000;
        }
        (void)t1;
        us_write += t0;

        if (!next) { next = now; t_sec = now; }
        next += 1000000L / 60;
        if (next > now) usleep(next - now);
        else next = now;
        frames++;
        if (now - t_sec >= 1000000L) {
            fprintf(stderr, "%s: %d кадров эмуляции/с, на панель %d, отдача %ld мкс/кадр, "
                    "ввод %ld мкс/кадр, панель %d/%d мкс, ошибок опкодов %lu\n",
                    core->name, frames, shown,
                    frames ? us_write / frames : 0, frames ? us_pad / frames : 0,
                    panel_us, panel_peak, core->errors ? core->errors() : 0UL);
            (void)dropped;
            frames = 0; shown = 0; dropped = 0; us_write = 0; us_pad = 0;
            t_sec = now;
        }
    }
    sound_want = 0;
    sound_apply(core);
    writer_finish();
    draw_closing();
    pad_net_stop();
    return 0;
}
