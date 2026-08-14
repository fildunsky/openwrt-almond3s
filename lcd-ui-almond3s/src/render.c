/*
 * render — рендерер экрана Almond 3S (ставится как /usr/libexec/almond3s/render)
 * mmap /dev/lcd → framebuffer 320x240 RGB565
 * Принимает JSON команды через unix socket /tmp/lcd.sock
 *
 * Компиляция вручную: zig cc -target mipsel-linux-musleabi -O2 -static -o render render.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stdint.h>
#include <sys/stat.h>

#define LCD_W 320
#define LCD_H 240
#define FB_SIZE (LCD_W * LCD_H * 2)
#define SOCK_PATH "/tmp/lcd.sock"

static uint16_t fb[320 * 240]; /* local framebuffer */
static int lcd_fd;

/* RGB888 → RGB565 */
static uint16_t rgb(uint8_t r, uint8_t g, uint8_t b)
{
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

/* Parse #RRGGBB → RGB565 */
static uint16_t parse_color(const char *s)
{
    if (!s) return 0xFFFF;
    if (s[0] == '#') {
        int len = strlen(s + 1);
        unsigned int v;
        if (len >= 6) {
            /* #RRGGBB → RGB888 → RGB565 */
            sscanf(s + 1, "%06x", &v);
            return rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
        }
        /* #XXXX or #XXX → raw RGB565 */
        sscanf(s + 1, "%x", &v);
        return (uint16_t)v;
    }
    if (!strcmp(s, "red"))    return 0xF800;
    if (!strcmp(s, "green"))  return 0x07E0;
    if (!strcmp(s, "blue"))   return 0x001F;
    if (!strcmp(s, "white"))  return 0xFFFF;
    if (!strcmp(s, "black"))  return 0x0000;
    if (!strcmp(s, "yellow")) return 0xFFE0;
    if (!strcmp(s, "cyan"))   return 0x07FF;
    return (uint16_t)strtol(s, NULL, 0);
}

static void fb_pixel(int x, int y, uint16_t c)
{
    if (x >= 0 && x < LCD_W && y >= 0 && y < LCD_H)
        fb[y * LCD_W + x] = c;
}

static void fb_fill(uint16_t c)
{
    int i;
    for (i = 0; i < LCD_W * LCD_H; i++) fb[i] = c;
}

static void fb_rect(int x, int y, int w, int h, uint16_t c)
{
    int i, j;
    for (j = y; j < y + h && j < LCD_H; j++)
        for (i = x; i < x + w && i < LCD_W; i++)
            if (i >= 0 && j >= 0) fb[j * LCD_W + i] = c;
}

/* Встроенный шрифт 5x7 ASCII */
static const uint8_t font5x7[96][5] = {
    {0x00,0x00,0x00,0x00,0x00},{0x00,0x00,0x5F,0x00,0x00},
    {0x00,0x07,0x00,0x07,0x00},{0x14,0x7F,0x14,0x7F,0x14},
    {0x24,0x2A,0x7F,0x2A,0x12},{0x23,0x13,0x08,0x64,0x62},
    {0x36,0x49,0x55,0x22,0x50},{0x00,0x05,0x03,0x00,0x00},
    {0x00,0x1C,0x22,0x41,0x00},{0x00,0x41,0x22,0x1C,0x00},
    {0x14,0x08,0x3E,0x08,0x14},{0x08,0x08,0x3E,0x08,0x08},
    {0x00,0x50,0x30,0x00,0x00},{0x08,0x08,0x08,0x08,0x08},
    {0x00,0x60,0x60,0x00,0x00},{0x20,0x10,0x08,0x04,0x02},
    {0x3E,0x51,0x49,0x45,0x3E},{0x00,0x42,0x7F,0x40,0x00},
    {0x42,0x61,0x51,0x49,0x46},{0x21,0x41,0x45,0x4B,0x31},
    {0x18,0x14,0x12,0x7F,0x10},{0x27,0x45,0x45,0x45,0x39},
    {0x3C,0x4A,0x49,0x49,0x30},{0x01,0x71,0x09,0x05,0x03},
    {0x36,0x49,0x49,0x49,0x36},{0x06,0x49,0x49,0x29,0x1E},
    {0x00,0x6C,0x6C,0x00,0x00},{0x00,0x56,0x36,0x00,0x00},
    {0x08,0x14,0x22,0x41,0x00},{0x14,0x14,0x14,0x14,0x14},
    {0x00,0x41,0x22,0x14,0x08},{0x02,0x01,0x51,0x09,0x06},
    {0x32,0x49,0x79,0x41,0x3E},{0x7E,0x11,0x11,0x11,0x7E},
    {0x7F,0x49,0x49,0x49,0x36},{0x3E,0x41,0x41,0x41,0x22},
    {0x7F,0x41,0x41,0x22,0x1C},{0x7F,0x49,0x49,0x49,0x41},
    {0x7F,0x09,0x09,0x09,0x01},{0x3E,0x41,0x49,0x49,0x7A},
    {0x7F,0x08,0x08,0x08,0x7F},{0x00,0x41,0x7F,0x41,0x00},
    {0x20,0x40,0x41,0x3F,0x01},{0x7F,0x08,0x14,0x22,0x41},
    {0x7F,0x40,0x40,0x40,0x40},{0x7F,0x02,0x0C,0x02,0x7F},
    {0x7F,0x04,0x08,0x10,0x7F},{0x3E,0x41,0x41,0x41,0x3E},
    {0x7F,0x09,0x09,0x09,0x06},{0x3E,0x41,0x51,0x21,0x5E},
    {0x7F,0x09,0x19,0x29,0x46},{0x46,0x49,0x49,0x49,0x31},
    {0x01,0x01,0x7F,0x01,0x01},{0x3F,0x40,0x40,0x40,0x3F},
    {0x1F,0x20,0x40,0x20,0x1F},{0x3F,0x40,0x38,0x40,0x3F},
    {0x63,0x14,0x08,0x14,0x63},{0x07,0x08,0x70,0x08,0x07},
    {0x61,0x51,0x49,0x45,0x43},{0x00,0x7F,0x41,0x41,0x00},
    {0x02,0x04,0x08,0x10,0x20},{0x00,0x41,0x41,0x7F,0x00},
    {0x04,0x02,0x01,0x02,0x04},{0x40,0x40,0x40,0x40,0x40},
    {0x00,0x01,0x02,0x04,0x00},{0x20,0x54,0x54,0x54,0x78},
    {0x7F,0x48,0x44,0x44,0x38},{0x38,0x44,0x44,0x44,0x20},
    {0x38,0x44,0x44,0x48,0x7F},{0x38,0x54,0x54,0x54,0x18},
    {0x08,0x7E,0x09,0x01,0x02},{0x0C,0x52,0x52,0x52,0x3E},
    {0x7F,0x08,0x04,0x04,0x78},{0x00,0x44,0x7D,0x40,0x00},
    {0x20,0x40,0x44,0x3D,0x00},{0x7F,0x10,0x28,0x44,0x00},
    {0x00,0x41,0x7F,0x40,0x00},{0x7C,0x04,0x18,0x04,0x78},
    {0x7C,0x08,0x04,0x04,0x78},{0x38,0x44,0x44,0x44,0x38},
    {0x7C,0x14,0x14,0x14,0x08},{0x08,0x14,0x14,0x18,0x7C},
    {0x7C,0x08,0x04,0x04,0x08},{0x48,0x54,0x54,0x54,0x20},
    {0x04,0x3F,0x44,0x40,0x20},{0x3C,0x40,0x40,0x20,0x7C},
    {0x1C,0x20,0x40,0x20,0x1C},{0x3C,0x40,0x30,0x40,0x3C},
    {0x44,0x28,0x10,0x28,0x44},{0x0C,0x50,0x50,0x50,0x3C},
    {0x44,0x64,0x54,0x4C,0x44},{0x00,0x08,0x36,0x41,0x00},
    {0x00,0x00,0x7F,0x00,0x00},{0x00,0x41,0x36,0x08,0x00},
    {0x10,0x08,0x08,0x10,0x08},{0x00,0x00,0x00,0x00,0x00},
};

/* Кириллица 5x7: А-Я, а-я (Ё/ё внутри алфавита). Формат тот же,
   что у font5x7 - байт на колонку, бит 0 сверху. */
static const uint8_t font5x7_cyr[66][5] = {
    {0x7C,0x12,0x11,0x12,0x7C},{0x7F,0x49,0x49,0x49,0x31},
    {0x7F,0x49,0x49,0x49,0x36},{0x7F,0x01,0x01,0x01,0x01},
    {0x60,0x3F,0x21,0x21,0x7F},{0x7F,0x49,0x49,0x49,0x41},
    {0x77,0x08,0x7F,0x08,0x77},{0x41,0x49,0x49,0x49,0x36},
    {0x7F,0x10,0x08,0x04,0x7F},{0x7E,0x11,0x09,0x05,0x7E},
    {0x7F,0x08,0x16,0x61,0x00},{0x60,0x1E,0x01,0x01,0x7F},
    {0x7F,0x02,0x0C,0x02,0x7F},{0x7F,0x08,0x08,0x08,0x7F},
    {0x3E,0x41,0x41,0x41,0x3E},{0x7F,0x01,0x01,0x01,0x7F},
    {0x7F,0x09,0x09,0x09,0x06},{0x3E,0x41,0x41,0x41,0x22},
    {0x01,0x01,0x7F,0x01,0x01},{0x27,0x48,0x48,0x48,0x3F},
    {0x1C,0x22,0x7F,0x22,0x1C},{0x63,0x14,0x08,0x14,0x63},
    {0x3F,0x20,0x20,0x3F,0x60},{0x07,0x08,0x08,0x08,0x7F},
    {0x7F,0x40,0x7F,0x40,0x7F},{0x3F,0x20,0x3F,0x20,0x7F},
    {0x01,0x7F,0x48,0x48,0x30},{0x7F,0x48,0x78,0x00,0x7F},
    {0x7F,0x48,0x48,0x48,0x30},{0x41,0x49,0x49,0x49,0x3E},
    {0x7F,0x08,0x7F,0x41,0x3E},{0x06,0x69,0x19,0x09,0x7F},
    {0x20,0x54,0x54,0x54,0x78},{0x38,0x44,0x46,0x45,0x38},
    {0x7C,0x54,0x54,0x54,0x28},{0x7C,0x04,0x04,0x04,0x04},
    {0x60,0x38,0x24,0x3C,0x60},{0x38,0x54,0x54,0x54,0x18},
    {0x6C,0x10,0x7C,0x10,0x6C},{0x44,0x54,0x54,0x54,0x28},
    {0x7C,0x20,0x10,0x08,0x7C},{0x78,0x24,0x14,0x0C,0x78},
    {0x7C,0x10,0x28,0x44,0x00},{0x40,0x38,0x04,0x04,0x7C},
    {0x7C,0x08,0x10,0x08,0x7C},{0x7C,0x10,0x10,0x10,0x7C},
    {0x38,0x44,0x44,0x44,0x38},{0x7C,0x04,0x04,0x04,0x7C},
    {0x7C,0x24,0x24,0x24,0x18},{0x38,0x44,0x44,0x44,0x00},
    {0x04,0x04,0x7C,0x04,0x04},{0x0C,0x50,0x50,0x50,0x3C},
    {0x0C,0x12,0x7F,0x12,0x0C},{0x44,0x28,0x10,0x28,0x44},
    {0x3C,0x20,0x20,0x3C,0x60},{0x0C,0x10,0x10,0x10,0x7C},
    {0x7C,0x40,0x7C,0x40,0x7C},{0x3C,0x20,0x3C,0x20,0x7C},
    {0x04,0x7C,0x50,0x50,0x20},{0x7C,0x50,0x70,0x00,0x7C},
    {0x7C,0x50,0x50,0x50,0x20},{0x44,0x54,0x54,0x54,0x38},
    {0x7C,0x10,0x7C,0x44,0x38},{0x08,0x54,0x34,0x14,0x7C},
    {0x7C,0x55,0x54,0x55,0x44},{0x38,0x55,0x54,0x55,0x18},
};

/* Спецсимволы: то, что реально встречается в SMS операторов и в нашем
   интерфейсе. Ищем перебором - записей мало, а таблица разрежена. */
static const struct { uint16_t cp; uint8_t g[5]; } font5x7_sym[] = {
    { 0x00B0, {0x02,0x05,0x05,0x02,0x00} },   /* degree */
    { 0x00AB, {0x08,0x14,0x2A,0x14,0x22} },   /* laquo */
    { 0x00BB, {0x22,0x14,0x2A,0x14,0x08} },   /* raquo */
    { 0x2116, {0x1F,0x06,0x1F,0x20,0x23} },   /* numero */
    { 0x20BD, {0x20,0x7F,0x29,0x29,0x26} },   /* rouble */
    { 0x2192, {0x08,0x08,0x2A,0x1C,0x08} },   /* rarr */
    { 0x2190, {0x08,0x1C,0x2A,0x08,0x08} },   /* larr */
    { 0x2191, {0x04,0x02,0x7F,0x02,0x04} },   /* uarr */
    { 0x2193, {0x10,0x20,0x7F,0x20,0x10} },   /* darr */
    { 0x2197, {0x10,0x09,0x05,0x03,0x07} },   /* nearr */
    { 0x2198, {0x01,0x12,0x14,0x18,0x1C} },   /* searr */
    { 0x2196, {0x07,0x03,0x05,0x09,0x10} },   /* nwarr */
    { 0x2199, {0x1C,0x18,0x14,0x12,0x01} },   /* swarr */
    { 0x2022, {0x00,0x1C,0x1C,0x1C,0x00} },   /* bullet */
    { 0x2713, {0x08,0x10,0x20,0x1C,0x02} },   /* check */
    { 0x2026, {0x40,0x00,0x40,0x00,0x40} },   /* hellip */
    { 0x2013, {0x08,0x08,0x08,0x08,0x08} },   /* ndash */
    { 0x2014, {0x08,0x08,0x08,0x08,0x08} },   /* mdash */
    { 0x2011, {0x00,0x08,0x08,0x08,0x00} },   /* nbhyph */
    { 0x201C, {0x03,0x00,0x03,0x00,0x00} },   /* ldquo */
    { 0x201D, {0x03,0x00,0x03,0x00,0x00} },   /* rdquo */
    { 0x2018, {0x00,0x00,0x03,0x00,0x00} },   /* lsquo */
    { 0x2019, {0x00,0x00,0x03,0x00,0x00} },   /* rsquo */
};

#include "flipper_fonts.h"

/* Режим шрифта: 0 - встроенный 5x7, 1 - haxrcorp4089 из Flipper Zero.
   Рисуем его МОНОШИРИННО в ту же клетку 6x8, что и 5x7: вся геометрия
   страниц посчитана из ширины 6*scale на символ, и пропорциональный вывод
   разъехался бы по всем правым краям и центровкам. */
static int font_mode = 0;

static const struct fz_glyph *fz_find(const struct fz_glyph *g, int n, unsigned cp)
{
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g[mid].cp == cp) return &g[mid];
        if (g[mid].cp < cp) lo = mid + 1; else hi = mid - 1;
    }
    return NULL;
}

/* Символ шрифтом Flipper в клетке 6x8: фон клетки, базовая линия на 7-й
   строке, как у 5x7. Вернуть 0, если глифа нет - вызывающий нарисует 5x7. */
static int fz_char_mono(int x, int y, unsigned cp, uint16_t fg, uint16_t bg, int scale, int draw_bg)
{
    const struct fz_glyph *g = fz_find(fz_hax_glyphs, FZ_HAX_COUNT, cp);
    int row, col, sx, sy;
    if (!g) return 0;
    if (draw_bg)
        for (row = 0; row < 8 * scale; row++)
            for (sx = 0; sx < 6 * scale; sx++)
                fb_pixel(x + sx, y + row, bg);
    {
        int bpr = (g->w + 7) / 8;
        int gx = x + g->x * scale;
        int gy = y + (7 - g->h - g->y) * scale;
        for (row = 0; row < g->h; row++)
            for (col = 0; col < g->w; col++)
                if (fz_hax_bits[g->off + row * bpr + col / 8] & (0x80 >> (col % 8)))
                    for (sy = 0; sy < scale; sy++)
                        for (sx = 0; sx < scale; sx++)
                            fb_pixel(gx + col * scale + sx, gy + row * scale + sy, fg);
    }
    return 1;
}

/* cp - код символа Unicode. Латиница берётся из font5x7, кириллица - из
   font5x7_cyr (порядок юникодный, индекс - арифметика), остальное ищем в
   font5x7_sym. */
static void fb_char(int x, int y, unsigned cp, uint16_t fg, uint16_t bg, int scale)
{
    const uint8_t *g;
    int col, row, sx, sy;

    if (font_mode == 1 && fz_char_mono(x, y, cp, fg, bg, scale, 1))
        return;

    if (cp >= 0x0410 && cp <= 0x042F)      g = font5x7_cyr[cp - 0x0410];
    else if (cp >= 0x0430 && cp <= 0x044F) g = font5x7_cyr[32 + (cp - 0x0430)];
    else if (cp == 0x0401)                 g = font5x7_cyr[64];
    else if (cp == 0x0451)                 g = font5x7_cyr[65];
    else if (cp > 0x7F) {
        unsigned i;
        g = NULL;
        for (i = 0; i < sizeof(font5x7_sym) / sizeof(font5x7_sym[0]); i++)
            if (font5x7_sym[i].cp == cp) { g = font5x7_sym[i].g; break; }
        if (!g) g = font5x7[0];   /* нечем рисовать - пробел, а не мусор */
    }
    else {
        int idx = (int)cp - 32;
        if (idx < 0 || idx > 95) idx = 0;
        g = font5x7[idx];
    }
    for (row = 0; row < 7; row++)
        for (sy = 0; sy < scale; sy++)
            for (col = 0; col < 5; col++)
                for (sx = 0; sx < scale; sx++)
                    fb_pixel(x + col*scale + sx, y + row*scale + sy,
                             (g[col] & (1 << row)) ? fg : bg);
    /* space between chars */
    for (row = 0; row < 7*scale; row++)
        for (sx = 0; sx < scale; sx++)
            fb_pixel(x + 5*scale + sx, y + row, bg);
}

/* Текст приходит в UTF-8: кириллица это два байта (0xD0/0xD1 + продолжение).
   Разбираем двухбайтовые последовательности, остальное считаем ASCII. */
static void fb_text(int x, int y, const char *s, uint16_t fg, uint16_t bg, int scale)
{
    int x0 = x;
    unsigned cps[256];
    int cx[256], cy[256], adv[256];
    int n = 0, i;
    const unsigned char *p = (const unsigned char *)s;

    while (*p && n < 256) {
        unsigned cp;
        if (*p == '\n') { y += 8 * scale; x = x0; p++; continue; }
        if ((*p & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) {
            cp = ((unsigned)(*p & 0x1F) << 6) | (p[1] & 0x3F);
            p += 2;
        } else if ((*p & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
            cp = ((unsigned)(*p & 0x0F) << 12) | ((unsigned)(p[1] & 0x3F) << 6)
                 | (p[2] & 0x3F);
            p += 3;
        } else {
            cp = *p;
            p++;
        }
        cps[n] = cp; cx[n] = x; cy[n] = y;
        if (font_mode == 1) {
            const struct fz_glyph *g = fz_find(fz_hax_glyphs, FZ_HAX_COUNT, cp);
            adv[n] = (g ? g->adv : 6) * scale;
        } else {
            adv[n] = 6 * scale;
        }
        x += adv[n];
        n++;
    }

    if (font_mode == 1) {
        /* Два прохода: сперва фон всех клеток, затем глифы. Иначе широкий
           глиф (W, Ж, Щ) срезается фоном соседней клетки. */
        int row, sx;
        for (i = 0; i < n; i++)
            for (row = 0; row < 8 * scale; row++)
                for (sx = 0; sx < adv[i]; sx++)
                    fb_pixel(cx[i] + sx, cy[i] + row, bg);
        for (i = 0; i < n; i++)
            if (!fz_char_mono(cx[i], cy[i], cps[i], fg, bg, scale, 0))
                fb_char(cx[i], cy[i], cps[i], fg, bg, scale);
        return;
    }

    for (i = 0; i < n; i++)
        fb_char(cx[i], cy[i], cps[i], fg, bg, scale);
}

static void flush_cmd(void)
{
    int total = 0, n;
    lseek(lcd_fd, 0, SEEK_SET);
    while (total < FB_SIZE) {
        n = write(lcd_fd, (char *)fb + total, FB_SIZE - total);
        if (n <= 0) break;
        total += n;
    }
}

/* === Простой JSON парсер === */

static char *json_str(const char *json, const char *key, char *out, int outlen)
{
    char search[64];
    const char *found;
    char *p;
    snprintf(search, sizeof(search), "\"%s\"", key);
    /* Find "key" followed by : (skip matches in values) */
    found = json;
    while ((found = strstr(found, search)) != NULL) {
        p = (char *)found + strlen(search);
        while (*p == ' ' || *p == '\t') p++;
        if (*p == ':') { p++; break; }  /* found the KEY, not a value */
        found++;  /* skip this match, try next */
    }
    if (!found) { out[0] = 0; return out; }
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '"') {
        /* Экранирование разбираем по-настоящему: без этого \" внутри значения
         * обрывал строку на середине, а в тексте оставался хвостовой слеш -
         * ловилось на SMS с кавычками. */
        p++;
        int i = 0;
        while (*p && *p != '"' && i < outlen - 1) {
            if (*p == '\\' && p[1]) {
                p++;
                switch (*p) {
                case 'n': out[i++] = '\n'; break;
                case 't': out[i++] = '\t'; break;
                case 'r': break;
                default:  out[i++] = *p; break;
                }
                p++;
                continue;
            }
            out[i++] = *p++;
        }
        out[i] = 0;
    } else {
        int i = 0;
        while (*p && *p != ',' && *p != '}' && i < outlen - 1) out[i++] = *p++;
        out[i] = 0;
    }
    return out;
}

static int json_int(const char *json, const char *key, int def)
{
    char buf[32];
    json_str(json, key, buf, sizeof(buf));
    if (buf[0]) return atoi(buf);
    return def;
}

static void handle_cmd(const char *json)
{
    char cmd[32], color[32], text[256];

    json_str(json, "cmd", cmd, sizeof(cmd));

    if (!strcmp(cmd, "clear")) {
        json_str(json, "color", color, sizeof(color));
        fb_fill(parse_color(color[0] ? color : "black"));
    }
    else if (!strcmp(cmd, "rect")) {
        int x = json_int(json, "x", 0);
        int y = json_int(json, "y", 0);
        int w = json_int(json, "w", 10);
        int h = json_int(json, "h", 10);
        json_str(json, "color", color, sizeof(color));
        fb_rect(x, y, w, h, parse_color(color));
    }
    else if (!strcmp(cmd, "text")) {
        int x = json_int(json, "x", 0);
        int y = json_int(json, "y", 0);
        int size = json_int(json, "size", 1);
        json_str(json, "color", color, sizeof(color));
        char bg_color[32];
        json_str(json, "bg", bg_color, sizeof(bg_color));
        json_str(json, "text", text, sizeof(text));
        /* unescape \n */
        char *p;
        /* \n уже развёрнут в json_str */
        fb_text(x, y, text, parse_color(color[0] ? color : "white"),
                parse_color(bg_color[0] ? bg_color : "black"), size);
    }
    else if (!strcmp(cmd, "fontmode")) {
        font_mode = json_int(json, "mode", 0);
    }
    else if (!strcmp(cmd, "flush")) {
        flush_cmd();
        return;
    }
    else if (!strcmp(cmd, "fps")) {
        char buf[32];
        int fps = json_int(json, "value", 10);
        snprintf(buf, sizeof(buf), "fps %d\n", fps);
        write(lcd_fd, buf, strlen(buf));
        return;
    }

    /* No auto-flush — only "flush" command triggers write to LCD */
}

int main(int argc, char *argv[])
{
    int sock_fd, client_fd;
    struct sockaddr_un addr;

    /* Open /dev/lcd */
    lcd_fd = open("/dev/lcd", O_RDWR);
    if (lcd_fd < 0) { perror("/dev/lcd"); return 1; }

    printf("almond3s render: framebuffer %dx%d (%d bytes), write mode\n", LCD_W, LCD_H, FB_SIZE);

    /* One-shot mode: if args, process and exit (no splash) */
    if (argc > 1) {
        handle_cmd(argv[1]);
        close(lcd_fd);
        return 0;
    }

    /* No splash — kernel module shows 4PDA logo at boot */

    /* Unix socket server */
    unlink(SOCK_PATH);
    sock_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock_fd < 0) { perror("socket"); return 1; }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);

    if (bind(sock_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    listen(sock_fd, 5);
    chmod(SOCK_PATH, 0666);

    printf("almond3s render: listening on %s\n", SOCK_PATH);

    while (1) {
        client_fd = accept(sock_fd, NULL, NULL);
        if (client_fd < 0) continue;

        /*
         * read() на потоковом сокете режет данные по ПРОИЗВОЛЬНОЙ границе, а не
         * по строкам. Прежний код разбирал каждый кусок как набор целых команд:
         * команда, попавшая на границу буфера, разбиралась как законченная,
         * недостающие поля брались по умолчанию - и на экране появлялся
         * прямоугольник с чужими координатами. Копим до перевода строки.
         */
        char buf[4096];
        char acc[8192];
        int acc_len = 0;
        int n, i;
        while ((n = read(client_fd, buf, sizeof(buf))) > 0) {
            for (i = 0; i < n; i++) {
                if (buf[i] == '\n') {
                    acc[acc_len] = 0;
                    if (acc_len > 0 && acc[0] == '{')
                        handle_cmd(acc);
                    acc_len = 0;
                } else if (acc_len < (int)sizeof(acc) - 1) {
                    acc[acc_len++] = buf[i];
                } else {
                    /* строка длиннее буфера - бросаем целиком,половина команды хуже */
                    acc_len = 0;
                }
            }
        }
        /* хвост без перевода строки не исполняем: команда неполная */
        close(client_fd);
    }

    close(lcd_fd);
    close(sock_fd);
    return 0;
}
