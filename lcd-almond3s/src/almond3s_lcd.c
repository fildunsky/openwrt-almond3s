/*
 * almond3s-lcd.ko — драйвер панели ILI9341 на Securifi Almond 3S
 * Framebuffer в памяти + mmap для userspace + kernel thread для отрисовки
 *
 * /dev/lcd:
 *   mmap() — 320*240*2 = 153600 байт framebuffer (RGB565)
 *   write "flush" — принудительно отрисовать
 *   write "fps N" — установить fps (0=ручной flush)
 */

#define pr_fmt(fmt) "almond3s-lcd: " fmt

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/uaccess.h>
#include <linux/kthread.h>
#include <linux/sched.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/i2c.h>
#include <linux/kmsg_dump.h>
#include <linux/mutex.h>

#include "splash_4pda.h"
#include "pic_calib.h"

#define DEVICE_NAME  "lcd"
#define LCD_DRV_VERSION "V260401"
#ifndef LCD_DRV_BUILD
#define LCD_DRV_BUILD "unknown"
#endif
#define LCD_W        320
#define LCD_H        240
#define FB_SIZE      (LCD_W * LCD_H * 2)  /* RGB565 */

#define PALMBUS_BASE 0x1E000000
#define GPIOMODE_OFF 0x060
#define GPIO_DATA_OFF 0x600
#define GPIO_DIR_OFF  0x620

#define BIT_D0  (1u<<13)
#define BIT_D1  (1u<<18)
#define BIT_D2  (1u<<22)
#define BIT_D3  (1u<<23)
#define BIT_D4  (1u<<24)
#define BIT_D5  (1u<<25)
#define BIT_D6  (1u<<26)
#define BIT_D7  (1u<<27)
#define BIT_WRX (1u<<14)
#define BIT_RST (1u<<15)
#define BIT_CSX (1u<<16)
#define BIT_DCX (1u<<17)
#define BIT_BL  (1u<<31)

/* Mask of all LCD GPIO pins in bank0 — ONLY these may be touched */
#define LCD_PIN_MASK (BIT_D0|BIT_D1|BIT_D2|BIT_D3|BIT_D4|BIT_D5|BIT_D6|BIT_D7| \
                      BIT_WRX|BIT_RST|BIT_CSX|BIT_DCX|BIT_BL)

static void __iomem *gpio_base;
static u32 shadow_dir;
static u32 base_dir;           /* non-LCD DIR bits, preserved across writes */
static u8 *framebuffer;        /* kernel buffer */
static struct page **fb_pages; /* pages for mmap */
static int fb_npages;
static struct task_struct *render_thread;
static int __maybe_unused target_fps = 0;  /* manual flush only */
static int fb_dirty = 1;
static int fb_writing = 0;  /* 1 while userspace write() in progress */
static int splash_active = 1; /* demoscene animation until userspace takes over */

/*
 * fb_writing выставляется только при записи с pos == 0, поэтому поток
 * отрисовки успевал войти в memcpy снимка ДО того, как userspace начнёт
 * новый кадр: снимок получался склейкой двух кадров, и заметнее всего это
 * в начале буфера, то есть в левом верхнем углу экрана. Лочим только сам
 * снимок и саму запись - вывод по GPIO идёт уже из flush_snap, без лока,
 * поэтому userspace не ждёт всю прошивку кадра.
 */
static DEFINE_MUTEX(fb_lock);

/* === GPIO bit-bang (exact U-Boot replica) === */

static inline void gw(u32 off, u32 v) { __raw_writel(v, gpio_base + off); }
static inline u32 gr(u32 off) { return __raw_readl(gpio_base + off); }

/*
 * Write GPIO DIR register preserving non-LCD pins.
 * Only LCD_PIN_MASK bits come from lcd_bits, rest from base_dir.
 */
static inline void gw_dir(u32 lcd_bits) {
    gw(GPIO_DIR_OFF, base_dir | (lcd_bits & LCD_PIN_MASK));
}

static void gpio_set_byte(u8 val)
{
    if (val & 0x01) shadow_dir |= BIT_D0; else shadow_dir &= ~BIT_D0;
    if (val & 0x02) shadow_dir |= BIT_D1; else shadow_dir &= ~BIT_D1;
    if (val & 0x04) shadow_dir |= BIT_D2; else shadow_dir &= ~BIT_D2;
    if (val & 0x08) shadow_dir |= BIT_D3; else shadow_dir &= ~BIT_D3;
    if (val & 0x10) shadow_dir |= BIT_D4; else shadow_dir &= ~BIT_D4;
    if (val & 0x20) shadow_dir |= BIT_D5; else shadow_dir &= ~BIT_D5;
    if (val & 0x40) shadow_dir |= BIT_D6; else shadow_dir &= ~BIT_D6;
    if (val & 0x80) shadow_dir |= BIT_D7; else shadow_dir &= ~BIT_D7;
    gw_dir(shadow_dir);
}

static void lcd_cmd(u8 cmd)
{
    shadow_dir |= BIT_CSX;  gw_dir(shadow_dir);
    shadow_dir |= BIT_WRX;  gw_dir(shadow_dir);
    shadow_dir |= BIT_DCX;  gw_dir(shadow_dir);
    shadow_dir &= ~BIT_WRX; gw_dir(shadow_dir);
    shadow_dir &= ~BIT_CSX; gw_dir(shadow_dir);
    gpio_set_byte(cmd);
    u32 a = shadow_dir & ~BIT_DCX;
    u32 b = a | BIT_DCX;
    u32 c = b | BIT_CSX;
    gw_dir(a);
    gw_dir(b);
    gw_dir(c);
    shadow_dir = c | BIT_WRX;
    gw_dir(shadow_dir);
}

static void lcd_dat(u8 dat)
{
    shadow_dir |= BIT_WRX;  gw_dir(shadow_dir);
    shadow_dir &= ~BIT_CSX; gw_dir(shadow_dir);
    gpio_set_byte(dat);
    u32 a = shadow_dir & ~BIT_DCX;
    gw_dir(a);
    a |= BIT_DCX; gw_dir(a);
    a |= BIT_CSX; shadow_dir = a;
    gw_dir(shadow_dir);
}

static void lcd_write_16d(u16 val)
{
    gpio_set_byte(val >> 8);
    shadow_dir &= ~BIT_DCX; gw_dir(shadow_dir);
    shadow_dir |= BIT_DCX;  gw_dir(shadow_dir);
    gpio_set_byte(val & 0xFF);
    shadow_dir &= ~BIT_DCX; gw_dir(shadow_dir);
    shadow_dir |= BIT_DCX;  gw_dir(shadow_dir);
}

static void lcd_write_mem(void)
{
    shadow_dir |= BIT_WRX; gw_dir(shadow_dir);
    shadow_dir |= BIT_CSX; gw_dir(shadow_dir);
    shadow_dir |= BIT_DCX; gw_dir(shadow_dir);
    gpio_set_byte(0x2C);
    shadow_dir &= ~BIT_WRX; shadow_dir &= ~BIT_CSX;
    gw_dir(shadow_dir);
    u32 a = shadow_dir & ~BIT_DCX;
    u32 b = a | BIT_DCX;
    gw_dir(shadow_dir);
    gw_dir(a);
    gw_dir(b);
    b |= BIT_WRX;
    u32 c = b | BIT_CSX;
    gw_dir(b);
    gw_dir(c);
    c &= ~BIT_CSX;
    shadow_dir = c;
    gw_dir(shadow_dir);
}

static void lcd_cs_deselect(void)
{
    shadow_dir |= BIT_CSX;
    gw_dir(shadow_dir);
}

/* === LCD Hardware Init === */

static void lcd_gpio_init(void)
{
    u32 data;
    /*
     * GPIOMODE is now configured via DTS pinctrl (jtag/wdt/rgmii2 → gpio).
     * DO NOT write GPIOMODE here — it would clobber MDIO and kill MT7530 LAN!
     * Old value 0x95A8 had bit 12 set = MDIO→GPIO = LAN dead.
     */

    pr_info("GPIOMODE=0x%08x DIR=0x%08x DATA=0x%08x\n",
            gr(GPIOMODE_OFF), gr(GPIO_DIR_OFF), gr(GPIO_DATA_OFF));

    /* Save non-LCD DIR bits to preserve other GPIO settings */
    base_dir = gr(GPIO_DIR_OFF) & ~LCD_PIN_MASK;

    data = gr(GPIO_DATA_OFF);
    data |= BIT_CSX; gw(GPIO_DATA_OFF, data);
    data |= BIT_RST; gw(GPIO_DATA_OFF, data);
    data |= BIT_DCX; gw(GPIO_DATA_OFF, data);
    data |= BIT_WRX; gw(GPIO_DATA_OFF, data);
    data |= BIT_D0;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D1;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D2;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D3;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D4;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D5;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D6;  gw(GPIO_DATA_OFF, data);
    data |= BIT_D7;  gw(GPIO_DATA_OFF, data);
    udelay(10);
    shadow_dir = 0;
}

static void lcd_hw_reset(void)
{
    udelay(100000);
    shadow_dir |= BIT_RST; gw_dir(shadow_dir); udelay(10000);
    shadow_dir &= ~BIT_RST; gw_dir(shadow_dir); udelay(10000);
    shadow_dir |= BIT_RST; gw_dir(shadow_dir); udelay(120000);
    shadow_dir |= BIT_CSX; gw_dir(shadow_dir);
    shadow_dir |= BIT_DCX; gw_dir(shadow_dir);
    udelay(5000);
    shadow_dir &= ~BIT_CSX; gw_dir(shadow_dir);
}

static void lcd_init_ili9341(void)
{
    lcd_cmd(0xCF); lcd_dat(0x00); lcd_dat(0xC1); lcd_dat(0x30);
    lcd_cmd(0xED); lcd_dat(0x64); lcd_dat(0x03); lcd_dat(0x12); lcd_dat(0x81);
    lcd_cmd(0xE8); lcd_dat(0x85); lcd_dat(0x00); lcd_dat(0x78);
    lcd_cmd(0xCB); lcd_dat(0x39); lcd_dat(0x2C); lcd_dat(0x00); lcd_dat(0x34); lcd_dat(0x02);
    lcd_cmd(0xF7); lcd_dat(0x20);
    lcd_cmd(0xEA); lcd_dat(0x00); lcd_dat(0x00);
    lcd_cmd(0xC0); lcd_dat(0x1B);
    lcd_cmd(0xC1); lcd_dat(0x11);
    lcd_cmd(0xC5); lcd_dat(0x3F); lcd_dat(0x3C);
    lcd_cmd(0xC7); lcd_dat(0x8E);
    lcd_cmd(0x36); lcd_dat(0xA8);
    lcd_cmd(0x3A); lcd_dat(0x55);
    lcd_cmd(0xB1); lcd_dat(0x00); lcd_dat(0x15);
    lcd_cmd(0xB6); lcd_dat(0x0A); lcd_dat(0xA2);
    lcd_cmd(0xF2); lcd_dat(0x00);
    lcd_cmd(0x26); lcd_dat(0x01);
    lcd_cmd(0xE0);
    lcd_dat(0x0F); lcd_dat(0x0C); lcd_dat(0x0B); lcd_dat(0x07);
    lcd_dat(0x09); lcd_dat(0x00); lcd_dat(0x41); lcd_dat(0x67);
    lcd_dat(0x37); lcd_dat(0x07); lcd_dat(0x12); lcd_dat(0x06);
    lcd_dat(0x0F); lcd_dat(0x09); lcd_dat(0x00);
    lcd_cmd(0xE1);
    lcd_dat(0x00); lcd_dat(0x0B); lcd_dat(0x0E); lcd_dat(0x03);
    lcd_dat(0x0F); lcd_dat(0x04); lcd_dat(0x2C); lcd_dat(0x16);
    lcd_dat(0x43); lcd_dat(0x02); lcd_dat(0x0B); lcd_dat(0x0A);
    lcd_dat(0x2F); lcd_dat(0x30); lcd_dat(0x0F);
    lcd_cmd(0x11); mdelay(120);
    lcd_cmd(0x29);
}

/* === Framebuffer → Display === */

static u16 flush_snap[LCD_W * LCD_H]; /* snapshot buffer to prevent tearing */

static void lcd_flush_fb(void)
{
    int i;

    /* Snapshot framebuffer to avoid tearing during GPIO output */
    mutex_lock(&fb_lock);
    memcpy(flush_snap, framebuffer, FB_SIZE);
    mutex_unlock(&fb_lock);

    /* Refresh non-LCD DIR bits in case other drivers changed them */
    base_dir = gr(GPIO_DIR_OFF) & ~LCD_PIN_MASK;

    lcd_cmd(0x2A); lcd_dat(0); lcd_dat(0); lcd_dat(1); lcd_dat(0x3F);
    lcd_cmd(0x2B); lcd_dat(0); lcd_dat(0); lcd_dat(0); lcd_dat(0xEF);

    {
        lcd_write_mem();
        for (i = 0; i < LCD_W * LCD_H; i++) {
            lcd_write_16d(flush_snap[i]);
            if ((i & 0x3FF) == 0) cond_resched(); /* yield every 1024 pixels */
        }
        lcd_cs_deselect();
    }
}

/* === Demoscene animated splash (plasma + palette cycling) === */

/* Forward declarations — font/putchar are defined further below */
static const u8 kfont[96][5];
static void fb_putchar(u16 *fb, int x, int y, char ch, u16 fg, u16 bg);
static void fb_puts(u16 *fb, int x, int y, const char *s, u16 fg, u16 bg);

/* Sine LUT: 256 entries, values 0-255 (fixed-point sin*127+128) */
static const u8 sin_lut[256] = {
    128,131,134,137,140,143,146,149,152,155,158,162,165,167,170,173,
    176,179,182,185,188,190,193,196,198,201,203,206,208,211,213,215,
    218,220,222,224,226,228,230,232,234,235,237,238,240,241,243,244,
    245,246,248,249,250,250,251,252,253,253,254,254,254,255,255,255,
    255,255,255,255,254,254,254,253,253,252,251,250,250,249,248,246,
    245,244,243,241,240,238,237,235,234,232,230,228,226,224,222,220,
    218,215,213,211,208,206,203,201,198,196,193,190,188,185,182,179,
    176,173,170,167,165,162,158,155,152,149,146,143,140,137,134,131,
    128,125,122,119,116,113,110,107,104,101,98,94,91,89,86,83,
    80,77,74,71,68,66,63,60,58,55,53,50,48,45,43,41,
    38,36,34,32,30,28,26,24,22,21,19,18,16,15,13,12,
    11,10,8,7,6,6,5,4,3,3,2,2,2,1,1,1,
    1,1,1,1,2,2,2,3,3,4,5,6,6,7,8,10,
    11,12,13,15,16,18,19,21,22,24,26,28,30,32,34,36,
    38,41,43,45,48,50,53,55,58,60,63,66,68,71,74,77,
    80,83,86,89,91,94,98,101,104,107,110,113,116,119,122,125,
};

/* HSV-like palette: hue cycling through RGB565 */
static u16 plasma_color(u8 val, u8 phase)
{
    u8 h = val + phase;  /* rotate hue */
    u8 r, g, b;
    u8 sector = h / 43;  /* 0-5 */
    u8 frac = (h % 43) * 6;

    switch (sector) {
    case 0:  r = 255;     g = frac;     b = 0;       break;
    case 1:  r = 255-frac; g = 255;     b = 0;       break;
    case 2:  r = 0;       g = 255;      b = frac;    break;
    case 3:  r = 0;       g = 255-frac; b = 255;     break;
    case 4:  r = frac;    g = 0;        b = 255;     break;
    default: r = 255;     g = 0;        b = 255-frac; break;
    }
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

/* === Scene 1: Plasma === */
static void scene_plasma(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int x, y;
    u8 phase = (u8)(t * 7);

    for (y = 0; y < LCD_H; y++) {
        for (x = 0; x < LCD_W; x++) {
            u8 v = sin_lut[(x * 3 + t * 11) & 0xFF]
                 + sin_lut[(y * 5 + t * 7) & 0xFF]
                 + sin_lut[((x + y) * 2 + t * 3) & 0xFF]
                 + sin_lut[((x * x + y * y) / 64 + t * 5) & 0xFF];
            fb[y * LCD_W + x] = plasma_color(v, phase);
        }
    }
}

/* === Scene 2: Fire === */
static void scene_fire(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int x, y;
    /* Fire: propagate heat upward, random sparks at bottom */
    /* Seed bottom row with random heat */
    for (x = 0; x < LCD_W; x++) {
        u8 spark = sin_lut[(x * 7 + t * 13) & 0xFF]
                 + sin_lut[(x * 3 + t * 37) & 0xFF];
        fb[(LCD_H - 1) * LCD_W + x] = spark > 200 ? 0xFFE0 : 0;
    }
    /* Propagate upward with cooling */
    for (y = 0; y < LCD_H - 1; y++) {
        for (x = 1; x < LCD_W - 1; x++) {
            /* Average of 3 pixels below + decay */
            u16 below = fb[(y + 1) * LCD_W + x - 1];
            u16 belowc = fb[(y + 1) * LCD_W + x];
            u16 belowr = fb[(y + 1) * LCD_W + x + 1];
            /* Extract red channel as heat (top 5 bits of RGB565) */
            int heat_val = ((below >> 11) + (belowc >> 11) * 2 + (belowr >> 11)) / 4;
            if (heat_val > 0) heat_val--;
            /* Heat to fire color: black→red→yellow→white */
            u8 r, g, b;
            if (heat_val > 24) { r = 31; g = 63; b = (heat_val - 24) * 4; }
            else if (heat_val > 12) { r = 31; g = (heat_val - 12) * 5; b = 0; }
            else { r = heat_val * 2; g = 0; b = 0; }
            fb[y * LCD_W + x] = (r << 11) | (g << 5) | b;
        }
    }
}

/* === Scene 3: Starfield 3D === */
#define NUM_STARS 200
static struct { int x, y, z; } stars[NUM_STARS];
static int stars_init;

static void scene_starfield(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int i, sx, sy;

    if (!stars_init) {
        for (i = 0; i < NUM_STARS; i++) {
            stars[i].x = (sin_lut[(i * 7) & 0xFF] - 128) * 16;
            stars[i].y = (sin_lut[(i * 13 + 80) & 0xFF] - 128) * 12;
            stars[i].z = (sin_lut[(i * 3 + 40) & 0xFF]) + 1;
        }
        stars_init = 1;
    }

    memset(fb, 0, FB_SIZE);

    for (i = 0; i < NUM_STARS; i++) {
        stars[i].z -= 3;
        if (stars[i].z <= 0) {
            stars[i].x = (sin_lut[(t * 3 + i * 7) & 0xFF] - 128) * 16;
            stars[i].y = (sin_lut[(t * 5 + i * 13) & 0xFF] - 128) * 12;
            stars[i].z = 255;
        }
        sx = stars[i].x * 128 / (stars[i].z + 1) + LCD_W / 2;
        sy = stars[i].y * 128 / (stars[i].z + 1) + LCD_H / 2;
        if ((unsigned)sx < LCD_W && (unsigned)sy < LCD_H) {
            u8 bright = 255 - stars[i].z;
            u16 c = ((bright >> 3) << 11) | ((bright >> 2) << 5) | (bright >> 3);
            fb[sy * LCD_W + sx] = c;
            /* Bigger stars are closer */
            if (stars[i].z < 100 && sx + 1 < LCD_W)
                fb[sy * LCD_W + sx + 1] = c;
            if (stars[i].z < 50 && sy + 1 < LCD_H)
                fb[(sy + 1) * LCD_W + sx] = c;
        }
    }
}

/* === Scene 4: Interference / Moire === */
static void scene_interference(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int x, y;
    /* Two moving center points */
    int cx1 = 160 + sin_lut[(t * 5) & 0xFF] / 2 - 64;
    int cy1 = 120 + sin_lut[(t * 7 + 64) & 0xFF] / 2 - 64;
    int cx2 = 160 + sin_lut[(t * 3 + 128) & 0xFF] / 2 - 64;
    int cy2 = 120 + sin_lut[(t * 4 + 192) & 0xFF] / 2 - 64;

    for (y = 0; y < LCD_H; y++) {
        for (x = 0; x < LCD_W; x++) {
            int dx1 = x - cx1, dy1 = y - cy1;
            int dx2 = x - cx2, dy2 = y - cy2;
            /* isqrt approximation: use sum of abs as cheap distance */
            int d1 = (dx1 * dx1 + dy1 * dy1) >> 5;
            int d2 = (dx2 * dx2 + dy2 * dy2) >> 5;
            u8 v = sin_lut[(d1 + t * 3) & 0xFF]
                 + sin_lut[(d2 + t * 5) & 0xFF];
            fb[y * LCD_W + x] = plasma_color(v, (u8)(t * 3));
        }
    }
}

/* === Scene 5: Rotozoom XOR === */
static void scene_rotozoom(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int x, y;
    int angle = t * 4;
    int cosA = (int)sin_lut[(angle + 64) & 0xFF] - 128;
    int sinA = (int)sin_lut[angle & 0xFF] - 128;
    int zoom = sin_lut[(t * 3) & 0xFF] / 2 + 32;

    for (y = 0; y < LCD_H; y++) {
        for (x = 0; x < LCD_W; x++) {
            int cx = x - LCD_W / 2, cy = y - LCD_H / 2;
            int u = (cx * cosA - cy * sinA) / zoom + t * 2;
            int v = (cx * sinA + cy * cosA) / zoom + t * 3;
            u8 pattern = (u ^ v) & 0xFF;
            fb[y * LCD_W + x] = plasma_color(pattern, (u8)(t * 5));
        }
    }
}

/* === Logo overlay (4PDA from splash RLE, transparent black) === */
static void overlay_logo(void)
{
    u16 *fb = (u16 *)framebuffer;
    int i, j = 0;
    for (i = 0; i < SPLASH_RLE_LEN && j < LCD_W * LCD_H; i++) {
        int k;
        for (k = 0; k < splash_cnt[i] && j < LCD_W * LCD_H; k++, j++) {
            if (splash_clr[i] != 0x0000)  /* non-black = logo pixel */
                fb[j] = splash_clr[i];
        }
    }
}

/* === Scene 6: Dashboard Plasma — functional router visualization === */
/*
 * Each client has individual params:
 *   traffic_kbps: wave amplitude / "pressure" (heavy user = deep distortion)
 *   signal_dbm:   WiFi signal = distance from router (strong = close = center)
 *
 * Global: lte_rsrp = color palette, vpn_ms = pulsing rings
 */
#define MAX_DASH_CLIENTS 12

static struct {
    int num_clients;
    int lte_rsrp;       /* dBm, 0=no LTE */
    int vpn_ms;         /* -1=no tunnel */
    struct {
        int kbps;       /* traffic: amplitude of distortion */
        int signal;     /* WiFi dBm: -30(close) to -90(far) */
    } cl[MAX_DASH_CLIENTS];
} dash_params = { .lte_rsrp = -100, .vpn_ms = -1 };

/* LTE-based palette */
static u16 dash_color(u8 val, int rsrp, u8 phase)
{
    u8 h = val + phase;
    u8 r, g, b;

    if (rsrp == 0) {
        u8 gray = h >> 2;
        return ((gray >> 3) << 11) | ((gray >> 2) << 5) | (gray >> 3);
    }
    if (rsrp > -80) {
        r = h / 4; g = 128 + h / 2; b = 128 + h / 3;
    } else if (rsrp > -95) {
        r = h / 6; g = 64 + h / 2; b = 128 + h / 2;
    } else if (rsrp > -105) {
        r = 128 + h / 3; g = 96 + h / 4; b = h / 4;
    } else {
        r = 160 + h / 3; g = h / 4; b = h / 8;
    }
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

static void scene_dashboard(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int x, y, i;
    int nc = dash_params.num_clients;
    int rsrp = dash_params.lte_rsrp;
    int vpn = dash_params.vpn_ms;

    /* Total traffic for global animation speed */
    int total_kbps = 0;
    for (i = 0; i < nc && i < MAX_DASH_CLIENTS; i++)
        total_kbps += dash_params.cl[i].kbps;
    int gspeed = total_kbps / 200 + 1;  /* global time scale */
    if (gspeed > 30) gspeed = 30;
    int ts = t * gspeed;
    u8 phase = (u8)(t * gspeed / 3);

    /* Precompute client centers + amplitude */
    int cx[MAX_DASH_CLIENTS], cy[MAX_DASH_CLIENTS], amp[MAX_DASH_CLIENTS], cspeed[MAX_DASH_CLIENTS];
    for (i = 0; i < nc && i < MAX_DASH_CLIENTS; i++) {
        /* Distance from center: signal -30=0px(center), -90=140px(edge) */
        int radius = ((-dash_params.cl[i].signal) - 30) * 140 / 60;
        if (radius < 0) radius = 0;
        if (radius > 140) radius = 140;
        /* Orbit angle: each client at different position, slowly drifting */
        int angle_idx = (i * 256 / (nc + 1) + t * 2) & 0xFF;
        cx[i] = 160 + ((int)sin_lut[angle_idx] - 128) * radius / 128;
        cy[i] = 120 + ((int)sin_lut[(angle_idx + 64) & 0xFF] - 128) * radius / 128;
        /* Amplitude: traffic → pressure (0..128) */
        amp[i] = dash_params.cl[i].kbps / 100;
        if (amp[i] > 128) amp[i] = 128;
        if (amp[i] < 5) amp[i] = 5;
        /* Individual speed: more traffic = faster local waves */
        cspeed[i] = dash_params.cl[i].kbps / 500 + 1;
        if (cspeed[i] > 20) cspeed[i] = 20;
    }

    for (y = 0; y < LCD_H; y++) {
        for (x = 0; x < LCD_W; x++) {
            /* Ambient base: gentle waves */
            int v = sin_lut[(x * 2 + ts / 3) & 0xFF]
                  + sin_lut[(y * 3 + ts / 4) & 0xFF];

            /* Each client: wave source with individual pressure + speed */
            for (i = 0; i < nc && i < MAX_DASH_CLIENTS; i++) {
                int dx = x - cx[i], dy = y - cy[i];
                int dist_sq = dx * dx + dy * dy;
                int dist = dist_sq >> 5;
                /* Wave from this client: freq based on distance, speed individual */
                int wave = sin_lut[(dist + t * cspeed[i]) & 0xFF];
                /* Pressure: amplitude falls off with distance (gravity well) */
                int falloff = 256 - (dist_sq >> 8);
                if (falloff < 0) falloff = 0;
                v += (wave * amp[i] * falloff) >> 15;
            }

            /* VPN tunnel: concentric rings */
            if (vpn >= 0) {
                int dx = x - 160, dy = y - 120;
                int dist = (dx * dx + dy * dy) >> 5;
                int rspeed = vpn < 10 ? 20 : (vpn < 50 ? 10 : (vpn < 200 ? 5 : 2));
                u8 ring = sin_lut[(dist - t * rspeed) & 0xFF];
                if (ring > 200)
                    v += (vpn < 50) ? 40 : 20;
            }

            /* Clamp */
            if (v < 0) v = 0;
            if (v > 255) v = 255;
            fb[y * LCD_W + x] = dash_color((u8)v, rsrp, phase);
        }
    }
}

/* Logo overlay with alpha blending (95% background, 5% logo) */
static void overlay_logo_alpha(void)
{
    u16 *fb = (u16 *)framebuffer;
    int i, j = 0;
    for (i = 0; i < SPLASH_RLE_LEN && j < LCD_W * LCD_H; i++) {
        int k;
        for (k = 0; k < splash_cnt[i] && j < LCD_W * LCD_H; k++, j++) {
            u16 logo = splash_clr[i];
            if (logo != 0x0000) {
                u16 bg = fb[j];
                /* 95%/5% blend in RGB565 */
                int br = (bg >> 11) & 0x1F, bg2 = (bg >> 5) & 0x3F, bb = bg & 0x1F;
                int lr = (logo >> 11) & 0x1F, lg = (logo >> 5) & 0x3F, lb = logo & 0x1F;
                int r = (br * 19 + lr) / 20;
                int g = (bg2 * 19 + lg) / 20;
                int b = (bb * 19 + lb) / 20;
                fb[j] = (r << 11) | (g << 5) | b;
            }
        }
    }
}

/* === Scene 7: Matrix rain forming a rabbit — "Wake up, Neo..." ===
 *
 * Green characters fall down each column. In the accumulation phase
 * (mid-timeline), any glyph that drops through a cell belonging to the
 * rabbit mask gets imprinted into a sticky layer — so over time the
 * rain visibly traces the silhouette of a rabbit.  The last kmsg line
 * is shown along the very bottom as a live console status.
 */
#define MATRIX_COLS 53                /* LCD_W / 6 */
#define MATRIX_ROWS 34                /* LCD_H / 7 */

static char matrix_dmesg_line[128];

static void matrix_update_dmesg(void)
{
    struct kmsg_dump_iter iter;
    char buf[256];
    size_t len;
    kmsg_dump_rewind(&iter);
    while (kmsg_dump_get_line(&iter, true, buf, sizeof(buf) - 1, &len)) {
        if (!len) continue;
        buf[len] = 0;
        while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
            buf[--len] = 0;
        char *msg = buf;
        if (msg[0] == '[') {
            char *p = strchr(msg, ']');
            if (p) msg = p + 2;
        }
        if (*msg) {
            strncpy(matrix_dmesg_line, msg, sizeof(matrix_dmesg_line) - 1);
            matrix_dmesg_line[sizeof(matrix_dmesg_line) - 1] = 0;
        }
    }
}
#define RAB_W 20
#define RAB_H 22
#define RAB_X0 ((MATRIX_COLS - RAB_W) / 2)   /* 16 */
#define RAB_Y0 3                              /* upper half so text fits below */

static int   matrix_init;
static u8    m_drop_y[MATRIX_COLS];
static u8    m_drop_sp[MATRIX_COLS];
static u8    m_drop_tick[MATRIX_COLS];
static char  m_chr[MATRIX_ROWS][MATRIX_COLS];
static u8    m_sticky[MATRIX_ROWS][MATRIX_COLS];   /* 0 = empty, else brightness */
static char  m_sticky_chr[MATRIX_ROWS][MATRIX_COLS];

/* 20×22 rabbit mask, '#' = filled, ' ' = empty */
static const char *rabbit_mask[RAB_H] = {
    "   ##        ##     ",
    "   ##        ##     ",
    "   ##        ##     ",
    "   ####    ####     ",
    "   #####  #####     ",
    "   ################ ",
    "  ################# ",
    " ################## ",
    " ################## ",
    "####################",
    "## ############## ##",
    "## ############## ##",
    "####################",
    " ################## ",
    " ################## ",
    "  ################# ",
    "   ################ ",
    "    ##############  ",
    "     ############   ",
    "      ##########    ",
    "       ########     ",
    "         ####       ",
};

static inline int in_rabbit(int r, int c)
{
    int lr = r - RAB_Y0, lc = c - RAB_X0;
    if (lr < 0 || lr >= RAB_H) return 0;
    if (lc < 0 || lc >= RAB_W) return 0;
    return rabbit_mask[lr][lc] == '#';
}

static void matrix_draw_char(int row, int col, char ch, u16 color)
{
    u16 *fb = (u16 *)framebuffer;
    int idx = ch - 32;
    const u8 *gp;
    int ci, ri;
    int px = col * 6, py = row * 7;
    if (idx < 0 || idx > 94) idx = 0;
    gp = kfont[idx];
    for (ri = 0; ri < 7; ri++)
        for (ci = 0; ci < 5; ci++)
            if ((unsigned)(px + ci) < LCD_W &&
                (unsigned)(py + ri) < LCD_H &&
                (gp[ci] & (1 << ri)))
                fb[(py + ri) * LCD_W + px + ci] = color;
}

static void scene_matrix(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int i, k, r, c;
    int accumulating;

    if (!matrix_init) {
        for (i = 0; i < MATRIX_COLS; i++) {
            m_drop_y[i]    = sin_lut[(i * 7) & 0xFF] % MATRIX_ROWS;
            m_drop_sp[i]   = 1 + (sin_lut[(i * 13) & 0xFF] & 0x07);
            m_drop_tick[i] = 0;
        }
        for (r = 0; r < MATRIX_ROWS; r++) {
            for (c = 0; c < MATRIX_COLS; c++) {
                m_chr[r][c] = 33 + ((r * 7 + c * 13) % 94);
                m_sticky[r][c] = 0;
                m_sticky_chr[r][c] = m_chr[r][c];
            }
        }
        matrix_init = 1;
    }

    /* Fade green channel everywhere for trail decay */
    for (i = 0; i < LCD_W * LCD_H; i++) {
        u16 pxv = fb[i];
        u8 g = (pxv >> 5) & 0x3F;
        g = (g * 13) >> 4;
        fb[i] = (u16)g << 5;
    }

    /* Accumulation window: drops entering rabbit cells imprint permanently.
     * Before — pure rain. After — rabbit stays fully lit. */
    accumulating = (t >= 28 && t < 115);

    /* Advance columns and draw rain */
    for (i = 0; i < MATRIX_COLS; i++) {
        m_drop_tick[i]++;
        if (m_drop_tick[i] >= m_drop_sp[i]) {
            m_drop_tick[i] = 0;
            m_drop_y[i]++;
            if (m_drop_y[i] >= MATRIX_ROWS + 12) {
                m_drop_y[i] = 0;
                m_drop_sp[i] = 1 + (sin_lut[(t + i * 11) & 0xFF] & 0x07);
            }
            r = m_drop_y[i];
            if (r < MATRIX_ROWS) {
                char ch = 33 + (sin_lut[(t * 3 + i * 17 + r * 5) & 0xFF] % 94);
                m_chr[r][i] = ch;
                if (accumulating && in_rabbit(r, i)) {
                    m_sticky[r][i] = 255;
                    m_sticky_chr[r][i] = ch;
                }
            }
        }
        int head = m_drop_y[i];
        for (k = 0; k < 10; k++) {
            int rr = head - k;
            if (rr < 0 || rr >= MATRIX_ROWS) continue;
            u16 color;
            if (k == 0) {
                color = 0xFFFF;              /* bright white head */
            } else {
                int g = 58 - k * 6;
                if (g < 4) g = 4;
                color = (u16)g << 5;         /* green trail */
            }
            matrix_draw_char(rr, i, m_chr[rr][i], color);
        }
    }

    /* Sticky layer: rabbit imprint, bright green */
    for (r = 0; r < MATRIX_ROWS; r++) {
        for (c = 0; c < MATRIX_COLS; c++) {
            u8 s = m_sticky[r][c];
            if (!s) continue;
            int g = ((int)s * 60) / 255 + 3;
            if (g > 63) g = 63;
            u16 col = (u16)g << 5;
            matrix_draw_char(r, c, m_sticky_chr[r][c], col);
        }
    }

    /* Matrix text phases — white, mid-bottom strip */
    const char *msg = NULL;
    if      (t >= 10 && t <  40) msg = "Wake up, Neo...";
    else if (t >= 60 && t <  92) msg = "The Matrix has you...";
    else if (t >= 112 && t < 150) msg = "Follow the white rabbit.";

    if (msg) {
        int len = 0;
        const char *s = msg;
        while (*s++) len++;
        int tx = (LCD_W - len * 6) / 2;
        int ty = LCD_H - 22;
        int y2, x2;
        for (y2 = ty - 2; y2 < ty + 10 && y2 < LCD_H; y2++)
            for (x2 = 0; x2 < LCD_W; x2++)
                fb[y2 * LCD_W + x2] = 0x0000;
        fb_puts(fb, tx, ty, msg, 0xFFFF, 0x0000);
        if ((t & 3) < 2) {
            int cx = tx + len * 6;
            if (cx + 2 < LCD_W) {
                int ri;
                for (ri = 0; ri < 7; ri++)
                    fb[(ty + ri) * LCD_W + cx] = 0xFFFF;
            }
        }
    }

    /* Live kmsg tail at very bottom — green console feel */
    if ((t % 10) == 0 || matrix_dmesg_line[0] == 0)
        matrix_update_dmesg();
    {
        int ty = LCD_H - 9;
        int y2, x2;
        for (y2 = ty - 1; y2 < ty + 8 && y2 < LCD_H; y2++)
            for (x2 = 0; x2 < LCD_W; x2++)
                fb[y2 * LCD_W + x2] = 0x0000;
        if (matrix_dmesg_line[0]) {
            const char *line = matrix_dmesg_line;
            int total = 0;
            while (line[total]) total++;
            if (total > MATRIX_COLS) line += total - MATRIX_COLS;
            int llen = 0;
            while (line[llen]) llen++;
            int tx = (LCD_W - llen * 6) / 2;
            if (tx < 0) tx = 0;
            fb_puts(fb, tx, ty, line, 0x07E0, 0x0000);
        }
    }
}

/* Scene dispatch */
#define NUM_SCENES 7
static int current_scene = 6;   /* 6 = Matrix boot splash */

static void render_scene(int scene, int t)
{
    switch (scene) {
    case 0: scene_plasma(t); break;
    case 1: scene_fire(t); break;
    case 2: scene_starfield(t); break;
    case 3: scene_interference(t); break;
    case 4: scene_rotozoom(t); break;
    case 5: scene_dashboard(t); break;
    case 6: scene_matrix(t); break;
    default: scene_plasma(t); break;
    }
    if (scene == 5)
        overlay_logo_alpha();
    else if (scene != 6)        /* matrix — no 4PDA logo, it ruins the vibe */
        overlay_logo();
}

/* === Boot console: dmesg on LCD === */

/* Minimal 5x7 font (ASCII 32-126, same as lcd_render) */
static const u8 kfont[96][5] = {
    {0x00,0x00,0x00,0x00,0x00},{0x00,0x00,0x5F,0x00,0x00}, /* sp ! */
    {0x00,0x07,0x00,0x07,0x00},{0x14,0x7F,0x14,0x7F,0x14}, /* " # */
    {0x24,0x2A,0x7F,0x2A,0x12},{0x23,0x13,0x08,0x64,0x62}, /* $ % */
    {0x36,0x49,0x55,0x22,0x50},{0x00,0x05,0x03,0x00,0x00}, /* & ' */
    {0x00,0x1C,0x22,0x41,0x00},{0x00,0x41,0x22,0x1C,0x00}, /* ( ) */
    {0x14,0x08,0x3E,0x08,0x14},{0x08,0x08,0x3E,0x08,0x08}, /* * + */
    {0x00,0x50,0x30,0x00,0x00},{0x08,0x08,0x08,0x08,0x08}, /* , - */
    {0x00,0x60,0x60,0x00,0x00},{0x20,0x10,0x08,0x04,0x02}, /* . / */
    {0x3E,0x51,0x49,0x45,0x3E},{0x00,0x42,0x7F,0x40,0x00}, /* 0 1 */
    {0x42,0x61,0x51,0x49,0x46},{0x21,0x41,0x45,0x4B,0x31}, /* 2 3 */
    {0x18,0x14,0x12,0x7F,0x10},{0x27,0x45,0x45,0x45,0x39}, /* 4 5 */
    {0x3C,0x4A,0x49,0x49,0x30},{0x01,0x71,0x09,0x05,0x03}, /* 6 7 */
    {0x36,0x49,0x49,0x49,0x36},{0x06,0x49,0x49,0x29,0x1E}, /* 8 9 */
    {0x00,0x36,0x36,0x00,0x00},{0x00,0x56,0x36,0x00,0x00}, /* : ; */
    {0x08,0x14,0x22,0x41,0x00},{0x14,0x14,0x14,0x14,0x14}, /* < = */
    {0x00,0x41,0x22,0x14,0x08},{0x02,0x01,0x51,0x09,0x06}, /* > ? */
    {0x32,0x49,0x79,0x41,0x3E},{0x7E,0x11,0x11,0x11,0x7E}, /* @ A */
    {0x7F,0x49,0x49,0x49,0x36},{0x3E,0x41,0x41,0x41,0x22}, /* B C */
    {0x7F,0x41,0x41,0x22,0x1C},{0x7F,0x49,0x49,0x49,0x41}, /* D E */
    {0x7F,0x09,0x09,0x09,0x01},{0x3E,0x41,0x49,0x49,0x7A}, /* F G */
    {0x7F,0x08,0x08,0x08,0x7F},{0x00,0x41,0x7F,0x41,0x00}, /* H I */
    {0x20,0x40,0x41,0x3F,0x01},{0x7F,0x08,0x14,0x22,0x41}, /* J K */
    {0x7F,0x40,0x40,0x40,0x40},{0x7F,0x02,0x0C,0x02,0x7F}, /* L M */
    {0x7F,0x04,0x08,0x10,0x7F},{0x3E,0x41,0x41,0x41,0x3E}, /* N O */
    {0x7F,0x09,0x09,0x09,0x06},{0x3E,0x41,0x51,0x21,0x5E}, /* P Q */
    {0x7F,0x09,0x19,0x29,0x46},{0x46,0x49,0x49,0x49,0x31}, /* R S */
    {0x01,0x01,0x7F,0x01,0x01},{0x3F,0x40,0x40,0x40,0x3F}, /* T U */
    {0x1F,0x20,0x40,0x20,0x1F},{0x3F,0x40,0x38,0x40,0x3F}, /* V W */
    {0x63,0x14,0x08,0x14,0x63},{0x07,0x08,0x70,0x08,0x07}, /* X Y */
    {0x61,0x51,0x49,0x45,0x43},{0x00,0x7F,0x41,0x41,0x00}, /* Z [ */
    {0x02,0x04,0x08,0x10,0x20},{0x00,0x41,0x41,0x7F,0x00}, /* \ ] */
    {0x04,0x02,0x01,0x02,0x04},{0x40,0x40,0x40,0x40,0x40}, /* ^ _ */
    {0x00,0x01,0x02,0x04,0x00},{0x20,0x54,0x54,0x54,0x78}, /* ` a */
    {0x7F,0x48,0x44,0x44,0x38},{0x38,0x44,0x44,0x44,0x20}, /* b c */
    {0x38,0x44,0x44,0x48,0x7F},{0x38,0x54,0x54,0x54,0x18}, /* d e */
    {0x08,0x7E,0x09,0x01,0x02},{0x0C,0x52,0x52,0x52,0x3E}, /* f g */
    {0x7F,0x08,0x04,0x04,0x78},{0x00,0x44,0x7D,0x40,0x00}, /* h i */
    {0x20,0x40,0x44,0x3D,0x00},{0x7F,0x10,0x28,0x44,0x00}, /* j k */
    {0x00,0x41,0x7F,0x40,0x00},{0x7C,0x04,0x18,0x04,0x78}, /* l m */
    {0x7C,0x08,0x04,0x04,0x78},{0x38,0x44,0x44,0x44,0x38}, /* n o */
    {0x7C,0x14,0x14,0x14,0x08},{0x08,0x14,0x14,0x18,0x7C}, /* p q */
    {0x7C,0x08,0x04,0x04,0x08},{0x48,0x54,0x54,0x54,0x20}, /* r s */
    {0x04,0x3F,0x44,0x40,0x20},{0x3C,0x40,0x40,0x20,0x7C}, /* t u */
    {0x1C,0x20,0x40,0x20,0x1C},{0x3C,0x40,0x30,0x40,0x3C}, /* v w */
    {0x44,0x28,0x10,0x28,0x44},{0x0C,0x50,0x50,0x50,0x3C}, /* x y */
    {0x44,0x64,0x54,0x4C,0x44},{0x00,0x08,0x36,0x41,0x00}, /* z { */
    {0x00,0x00,0x7F,0x00,0x00},{0x00,0x41,0x36,0x08,0x00}, /* | } */
    {0x10,0x08,0x08,0x10,0x08},{0x00,0x00,0x00,0x00,0x00}, /* ~ del */
};

static void fb_putchar(u16 *fb, int x, int y, char ch, u16 fg, u16 bg)
{
    int idx = ch - 32, col, row;
    const u8 *g;
    if (idx < 0 || idx > 94) idx = 0;
    g = kfont[idx];
    for (row = 0; row < 7; row++)
        for (col = 0; col < 5; col++)
            if ((unsigned)(x + col) < LCD_W && (unsigned)(y + row) < LCD_H)
                fb[(y + row) * LCD_W + x + col] = (g[col] & (1 << row)) ? fg : bg;
}

static void fb_puts(u16 *fb, int x, int y, const char *s, u16 fg, u16 bg)
{
    while (*s) {
        if (*s == '\n' || x + 6 > LCD_W) { y += 8; x = 0; if (y + 7 > LCD_H) return; }
        if (*s != '\n') { fb_putchar(fb, x, y, *s, fg, bg); x += 6; }
        s++;
    }
}

static int console_phase = 0;         /* 0=splash, 2=userspace */

/* Render thread */
static int render_fn(void *data)
{
    int frame = 0;
    unsigned long splash_start;

    /* Random scene at boot (based on jiffies) */
    if (current_scene < 0)
        current_scene = jiffies % NUM_SCENES;

    splash_start = jiffies;
    console_phase = 0; /* splash */

    while (!kthread_should_stop()) {
        if (splash_active) {
            /* Splash runs until userspace writes to /dev/lcd. Live kmsg tail
             * is overlaid inside the matrix scene itself, so no separate
             * full-screen dmesg phase. */
            render_scene(current_scene, frame++);
            lcd_flush_fb();
            msleep(100);
            if (kthread_should_stop()) break;
        } else if (fb_dirty && !fb_writing) {
            console_phase = 2; /* userspace took over */
            lcd_flush_fb();
            fb_dirty = 0;
        } else {
            msleep(50);
        }
    }
    return 0;
}

/* === /dev/lcd file operations === */

/* Raw write: записать пиксели напрямую в framebuffer */
static ssize_t lcd_fb_write(struct file *f, const char __user *buf,
                             size_t cnt, loff_t *p)
{
    loff_t pos = *p;

    splash_active = 0;  /* userspace took over — stop animation */
    console_phase = 2;  /* stop dmesg rendering */

    if (pos >= FB_SIZE) return 0;
    if (pos + cnt > FB_SIZE) cnt = FB_SIZE - pos;

    if (pos == 0)
        fb_writing = 1;  /* block render thread from flushing */

    mutex_lock(&fb_lock);
    if (copy_from_user(framebuffer + pos, buf, cnt)) {
        mutex_unlock(&fb_lock);
        return -EFAULT;
    }
    mutex_unlock(&fb_lock);

    *p = pos + cnt;

    /* Полный кадр записан — разрешить flush */
    if (pos + cnt >= FB_SIZE) {
        fb_writing = 0;
        fb_dirty = 1;
    }

    return cnt;
}

/* === SX8650 Touchscreen via palmbus I2C (SM0 direct) === */
/*
 * SX8650 requires SM0_CTL1=0x90644042 (raw master mode) for touch reads.
 * Linux I2C (SM0_CTL1=0x8064800E) returns FF for SELECT(X/Y) commands.
 * We save/restore SM0_CTL1 around each palmbus access to coexist with
 * the Linux i2c-mt7621 driver.
 */

#define SX8650_ADDR  0x48

/* SM0 I2C controller registers */
#define SM0_CFG     0x900
#define SM0_DATA    0x908
#define SM0_DATAOUT 0x910
#define SM0_DATAIN  0x914
#define SM0_STATUS  0x91C
#define SM0_START   0x920
#define SM0_CTL1    0x940

/* New SM0 registers (kernel 6.12 i2c-mt7621) */
#define NEW_CTL0  0x940
#define NEW_CTL1  0x944
#define NEW_D0    0x950
#define NEW_D1    0x954
#define N_TRI     0x01
#define N_START   0x10
#define N_WRITE   0x20
#define N_STOP    0x30
#define N_READ_L  0x40
#define N_READ    0x50
#define N_PGLEN(x) ((((x)-1)<<8) & 0x700)

static int touch_x, touch_y;
static int touch_pressed;
static struct task_struct *touch_thread;
static struct i2c_adapter *touch_i2c_adap;

/* === PIC16 Battery via Linux I2C === */
#define PIC_ADDR  0x2A
#define PIC_BATTERY_LEN  17

static u8 pic_battery_raw[PIC_BATTERY_LEN];
static int pic_battery_valid;
static int pic_beep_request;  /* set from ioctl, executed in touch thread */
static int pic_beep_ms = 150;

/* Palmbus I2C raw helpers */
static void i2c_raw_write(u8 val)
{
    gw(SM0_DATAOUT, val);
    gw(SM0_STATUS, 0);
    udelay(150);
    gw(SM0_START, 0);
    udelay(150);
}

static void i2c_raw_start(void)
{
    gw(SM0_DATA, SX8650_ADDR);
    gw(SM0_START, 0);
    udelay(150);
}

static void i2c_raw_stop(void)
{
    gw(SM0_STATUS, 2);
    udelay(150);
    gw(SM0_START, 0);
    udelay(150);
}

static void sx8650_hw_init(void)
{
    u32 saved_ctl1 = gr(SM0_CTL1);

    /* Get I2C adapter for PIC battery (Linux I2C) */
    touch_i2c_adap = i2c_get_adapter(0);
    if (!touch_i2c_adap)
        pr_warn("cannot get I2C adapter 0 (PIC battery won't work)\n");

    /* SX8650 init via palmbus (needs SM0_CTL1=0x90644042) */
    gw(SM0_CTL1, 0x90644042);
    gw(0x928, 1);

    /* 1. Soft Reset */
    i2c_raw_start(); i2c_raw_write(0x1F); i2c_raw_write(0xDE); i2c_raw_stop();
    mdelay(50);

    /* 2. Registers from stock firmware */
    i2c_raw_start(); i2c_raw_write(0x00); i2c_raw_write(0x00); i2c_raw_stop(); udelay(150);
    i2c_raw_start(); i2c_raw_write(0x01); i2c_raw_write(0x27); i2c_raw_stop(); udelay(150);
    i2c_raw_start(); i2c_raw_write(0x02); i2c_raw_write(0x00); i2c_raw_stop(); udelay(150);
    i2c_raw_start(); i2c_raw_write(0x03); i2c_raw_write(0x2D); i2c_raw_stop(); udelay(150);
    i2c_raw_start(); i2c_raw_write(0x04); i2c_raw_write(0xC0); i2c_raw_stop(); udelay(150);

    /* 3. PenTrg mode */
    i2c_raw_start();
    gw(SM0_DATAOUT, 0x80); gw(SM0_STATUS, 2); udelay(150);
    gw(SM0_START, 0); udelay(150);
    i2c_raw_start();
    gw(SM0_DATAOUT, 0x90); gw(SM0_STATUS, 2); udelay(150);

    gw(SM0_CFG, 0xFA);

    /* Restore SM0_CTL1 for Linux I2C driver */
    gw(SM0_CTL1, saved_ctl1); udelay(10);

    pr_info("SX8650 init done (palmbus + SM0 save/restore)\n");
}

/*
 * Read touch X/Y via palmbus direct (SM0_CTL1 saved/restored).
 * Format: [0|CHAN(2:0)|D(11:8)] [D(7:0)]
 */
static int sx8650_read_xy(int *rx, int *ry)
{
    int raw_x = 0, raw_y = 0;
    u8 h, l;
    u32 saved_ctl1 = gr(SM0_CTL1);

    /* --- Read X: SELECT(X)=0x80 --- */
    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_DATA, SX8650_ADDR);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_DATAOUT, 0x80);
    gw(SM0_STATUS, 2); udelay(150);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_DATAOUT, 0x91);
    gw(SM0_STATUS, 2); udelay(150);
    gw(SM0_CFG, 0xFA);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_START, 1); gw(SM0_START, 1); udelay(10);
    gw(SM0_STATUS, 1); udelay(150);
    h = gr(SM0_DATAIN) & 0xFF; udelay(150);
    l = gr(SM0_DATAIN) & 0xFF; udelay(150);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_START, 1);

    if (h != 0xFF) {
        int ch = (h >> 4) & 7;
        int val = ((h & 0x0F) << 8) | l;
        if (ch == 0) raw_x = val;
        if (ch == 1) raw_y = val;
    }

    /* --- Read Y: SELECT(Y)=0x81 --- */
    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_DATA, SX8650_ADDR);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_DATAOUT, 0x81);
    gw(SM0_STATUS, 2); udelay(150);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_DATAOUT, 0x91);
    gw(SM0_STATUS, 2); udelay(150);
    gw(SM0_CFG, 0xFA);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_START, 1); gw(SM0_START, 1); udelay(10);
    gw(SM0_STATUS, 1); udelay(150);
    h = gr(SM0_DATAIN) & 0xFF; udelay(150);
    l = gr(SM0_DATAIN) & 0xFF; udelay(150);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_START, 1);

    /* Restore SM0_CTL1 for Linux I2C driver */
    gw(SM0_CTL1, saved_ctl1); udelay(10);

    if (h != 0xFF) {
        int ch = (h >> 4) & 7;
        int val = ((h & 0x0F) << 8) | l;
        if (ch == 0) raw_x = val;
        if (ch == 1) raw_y = val;
    }

    if (raw_x > 0 || raw_y > 0) {
        *rx = (raw_y > 0) ? (4096 - raw_y) * 320 / 4096 : 160;
        *ry = (raw_x > 0) ? raw_x * 240 / 4096 : 120;
        return 1;
    }
    return 0;
}

/* === PIC16 I2C via Linux I2C subsystem === */

static int pic_i2c_read(u8 *buf, int len)
{
    struct i2c_msg msg = {
        .addr = PIC_ADDR,
        .flags = I2C_M_RD,
        .len = len,
        .buf = buf,
    };
    int ret;

    if (!touch_i2c_adap)
        return -ENODEV;

    ret = i2c_transfer(touch_i2c_adap, &msg, 1);
    if (ret < 0)
        return ret;
    return (ret == 1) ? 0 : -EIO;
}

static int __maybe_unused pic_i2c_write(u8 *data, int len)
{
    struct i2c_msg msg = {
        .addr = PIC_ADDR,
        .flags = 0,
        .len = len,
        .buf = data,
    };
    int ret;

    if (!touch_i2c_adap)
        return -ENODEV;

    ret = i2c_transfer(touch_i2c_adap, &msg, 1);
    if (ret < 0)
        return ret;
    return (ret == 1) ? 0 : -EIO;
}

/*
 * Read battery data from PIC16:
 * Try multiple approaches:
 * 1. Write {0x2F, 0x00, 0x02} then read
 * 2. Simple read (no command)
 */
static int __maybe_unused pic_read_battery(void)
{
    int ret;
    {
        u8 wake[3] = { 0x33, 0x00, 0x01 };
        pic_i2c_write(wake, 3);
        mdelay(50);
    }
    ret = pic_i2c_read(pic_battery_raw, PIC_BATTERY_LEN);
    if (!ret) {
        pic_battery_valid = 1;
    } else {
        pr_info("PIC not responding (%d)\n", ret);
    }

    return 0;
}

/* Touch polling thread */
/*
 * Read PIC battery via OLD SM0 registers — EXACT stock kernel protocol.
 * Captured via sm0_spy on stock kernel 3.10.14:
 *   WRITE: ADDR=0x2A, START=1, DOUT=0x36, MODE=0
 *   READ:  START=5 (6 bytes), MODE=1, poll DATARDY, read DATAIN
 *
 * Called from touch thread — SM0 is in known state after touch read.
 * Touch read uses SM0_CTL1=0x90644042, then restores saved_ctl1.
 * We use the SAME OLD SM0 registers (0x900-0x920).
 */
static void pic_read_battery_palmbus(void)
{
    u8 resp[6] = {0};
    u32 saved_ctl1 = gr(SM0_CTL1);
    int i, p;

    /*
     * EXACT same protocol as lcd_drv init (which WORKS for buzzer!):
     * CTL1 → CFG → ADDR → START → DOUT → STATUS, poll COMPLETE
     * NO RSTCTRL, NO dummy, NO cmd 0x39
     */
    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_CFG, 0xFA);

    /* WRITE cmd 0x39 (SSP REINIT — clears SSPOV, resets PIC I2C!) */
    gw(SM0_DATA, PIC_ADDR);
    gw(SM0_START, 1);
    gw(SM0_DATAOUT, 0x39);
    gw(SM0_STATUS, 0);
    { int w; for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); } }
    mdelay(10);  /* stock: 10ms delay after 0x39 */

    /* WRITE cmd 0x36 (ADC read) */
    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_CFG, 0xFA);
    gw(SM0_DATA, PIC_ADDR);
    gw(SM0_START, 1);
    gw(SM0_DATAOUT, 0x36);
    gw(SM0_STATUS, 0);
    { int w; for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); } }

    pr_info("PIC[v14] W: PS=%02x CTL0=%08x\n", gr(0x918), gr(SM0_CTL1));

    udelay(5000);

    /* === READ 6 bytes — re-init SM0 for read like touch does === */
    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_CFG, 0xFA);
    gw(SM0_DATA, PIC_ADDR);
    gw(SM0_START, 5);
    gw(SM0_STATUS, 1);  /* read mode, triggers */

    for (i = 0; i < 6; i++) {
        for (p = 0; p < 100000; p++) {
            if (gr(0x918) & 0x04) break;
        }
        if (p < 100000) {
            udelay(10);
            resp[i] = gr(SM0_DATAIN) & 0xFF;
        } else {
            resp[i] = 0xFF;
            pr_info("PIC R timeout@%d PS=%02x\n", i, gr(0x918));
            break;  /* stop on first timeout */
        }
    }

    /* Restore SM0_CTL1 for Linux I2C driver */
    gw(SM0_CTL1, saved_ctl1); udelay(10);

    /* Log */
    pr_info("PIC bat: %02x %02x %02x %02x %02x %02x\n",
            resp[0], resp[1], resp[2], resp[3], resp[4], resp[5]);

    /* Parse: stock format byte0=ADC_lo, byte1=ADC_hi, byte2=status */
    {
        int adc = ((resp[1] & 0x03) << 8) | resp[0];
        int adc_alt = (resp[1] << 8) | resp[0];
        /* Validate: resp[3]==0x02 (vref) && resp[4]==0x04 (status marker) */
        if (resp[3] == 0x02 && resp[4] == 0x04) {
            pic_battery_raw[0] = resp[0];
            pic_battery_raw[1] = resp[1];
            pic_battery_raw[2] = resp[2];
            pic_battery_raw[3] = resp[3];
            pic_battery_raw[4] = resp[4];
            pic_battery_raw[5] = resp[5];
            pic_battery_valid = 1;
            pr_info("PIC ADC=%d (alt=%d) status=%02x\n",
                    adc, adc_alt, resp[2]);
        }
    }
}

static int touch_fn(void *data)
{
    int x, y, was_pressed = 0;
    int no_touch_count = 0;
    int battery_counter = 0;

    while (!kthread_should_stop()) {
        /* Touch read (palmbus direct, SM0_CTL1 saved/restored) */
        if (sx8650_read_xy(&x, &y)) {
            touch_x = x;
            touch_y = y;
            touch_pressed = 1;
            no_touch_count = 0;
            if (!was_pressed)
                pr_info("touch DOWN x=%d y=%d (raw data logged)\n", x, y);
            was_pressed = 1;
        } else {
            no_touch_count++;
            if (no_touch_count > 10 && was_pressed) {
                touch_pressed = 0;
                was_pressed = 0;
                pr_info("touch UP\n");
            }
        }

        /* Battery read every ~10 sec (200 * 50ms) */
        battery_counter++;
        if (battery_counter >= 200) {
            battery_counter = 0;
            pic_read_battery_palmbus();
        }

        /* PIC command from ioctl (beep or raw cmd) */
        if (pic_beep_request) {
            u32 s_ctl1 = gr(SM0_CTL1);
            int bw;
            pic_beep_request = 0;

            /* Helper macro: SM0 init + 3-byte write (like battery write) */
            #define PW3(b0,b1,b2) do { \
                gw(SM0_CTL1, 0x90644042); udelay(10); \
                gw(SM0_CFG, 0xFA); \
                gw(SM0_DATA, PIC_ADDR); \
                gw(SM0_START, 3); \
                gw(SM0_DATAOUT, (b0)); \
                gw(SM0_STATUS, 0); \
                for(bw=0;bw<500;bw++){if(gr(0x918)&0x02)break;udelay(10);} \
                udelay(1000); \
                gw(SM0_DATAOUT, (b1)); \
                for(bw=0;bw<500;bw++){if(gr(0x918)&0x02)break;udelay(10);} \
                udelay(1000); \
                gw(SM0_DATAOUT, (b2)); \
                for(bw=0;bw<500;bw++){if(gr(0x918)&0x01)break;udelay(10);} \
                mdelay(15); \
            } while(0)

            if (pic_beep_request == 2) {
                /* Raw PIC cmd: ms field = cmd_byte | (data << 8)
                 * If data present (ms > 0xFF): send 3-byte {cmd, 0x00, data>>8}
                 * Else: send 1-byte {cmd} */
                u8 raw_cmd = (u8)(pic_beep_ms & 0xFF);
                u8 raw_data = (u8)((pic_beep_ms >> 8) & 0xFF);

                /* 0x39 SSP reinit */
                gw(SM0_CTL1, 0x90644042); udelay(10);
                gw(SM0_CFG, 0xFA);
                gw(SM0_DATA, PIC_ADDR);
                gw(SM0_START, 1);
                gw(SM0_DATAOUT, 0x39);
                gw(SM0_STATUS, 0);
                for(bw=0;bw<500;bw++){if(gr(0x918)&0x01)break;udelay(10);}
                mdelay(10);

                if (raw_data > 0) {
                    /* 3-byte write: {cmd, 0x00, data}
                     * Use FIXED 15ms delays (stock timing), no SDOEMPTY poll */
                    gw(SM0_CTL1, 0x90644042); udelay(10);
                    gw(SM0_CFG, 0xFA);
                    gw(SM0_DATA, PIC_ADDR);
                    gw(SM0_START, 3);
                    gw(SM0_DATAOUT, raw_cmd);
                    gw(SM0_STATUS, 0);
                    mdelay(15);
                    gw(SM0_DATAOUT, 0x00);
                    mdelay(15);
                    gw(SM0_DATAOUT, raw_data);
                    mdelay(15);
                    pr_info("PIC cmd {%02x,00,%02x} 3-byte\n", raw_cmd, raw_data);
                } else {
                    /* 1-byte write */
                    gw(SM0_CTL1, 0x90644042); udelay(10);
                    gw(SM0_CFG, 0xFA);
                    gw(SM0_DATA, PIC_ADDR);
                    gw(SM0_START, 1);
                    gw(SM0_DATAOUT, raw_cmd);
                    gw(SM0_STATUS, 0);
                    for(bw=0;bw<500;bw++){if(gr(0x918)&0x01)break;udelay(10);}
                    pr_info("PIC cmd 0x%02x 1-byte\n", raw_cmd);
                }

                gw(SM0_CTL1, s_ctl1); udelay(10);
                goto beep_done;
            }

            /* 0x39 SSP reinit ONCE */
            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 1);
            gw(SM0_DATAOUT, 0x39);
            gw(SM0_STATUS, 0);
            for(bw=0;bw<500;bw++){if(gr(0x918)&0x01)break;udelay(10);}
            mdelay(10);

            /* WAKE: {0x33, 0x00, 0x01} = 1 note */
            PW3(0x33, 0x00, 0x01);

            /* Table1: {0x2D, freq_hi, freq_lo} = 0x0496 (D#5, 1174)
             * Stock byte-swap: 0x0496 → {0x96, 0x04} */
            PW3(0x2D, 0x96, 0x04);

            /* Table2: {0x2E, dur_hi, dur_lo} = 600ms = 0x0258
             * Byte-swap: {0x58, 0x02} */
            PW3(0x2E, 0x58, 0x02);

            /* Play: {0x2F, 0x00, 0x01} */
            PW3(0x2F, 0x00, 0x01);

            gw(SM0_CTL1, s_ctl1); udelay(10);
            /* Also test: 1-byte LED cmd (0x30=blink) — visible effect! */
            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 1);
            gw(SM0_DATAOUT, 0x30);  /* LED BLINK */
            gw(SM0_STATUS, 0);
            for(bw=0;bw<500;bw++){if(gr(0x918)&0x01)break;udelay(10);}

            pr_info("beep sent + LED blink (0x30)\n");
beep_done:
            #undef PW3
        }

        msleep(50);
    }
    return 0;
}

/* ioctl: 0=flush, 1=read touch, 2=read battery, 3=raw PIC read, 4=backlight */
static long lcd_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
    if (cmd == 0) {
        splash_active = 0;  /* userspace flush — stop animation */
        console_phase = 2;
        fb_dirty = 1;
        return 0;
    }
    if (cmd == 1) {
        int data[3] = { touch_x, touch_y, touch_pressed };
        if (copy_to_user((void __user *)arg, data, sizeof(data)))
            return -EFAULT;
        return 0;
    }
    if (cmd == 2) {
        /* Return latest battery data from periodic palmbus read */
        if (copy_to_user((void __user *)arg, pic_battery_raw, PIC_BATTERY_LEN))
            return -EFAULT;
        return 0;  /* always return data, let userspace decide validity */
    }
    if (cmd == 3) {
        /* Raw PIC read (no write command, just read) */
        u8 buf[PIC_BATTERY_LEN];
        int ret = pic_i2c_read(buf, PIC_BATTERY_LEN);
        if (ret)
            return ret;
        pr_info("PIC raw: %02x %02x %02x %02x %02x %02x %02x %02x "
                "%02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
                buf[0], buf[1], buf[2], buf[3], buf[4], buf[5],
                buf[6], buf[7], buf[8], buf[9], buf[10], buf[11],
                buf[12], buf[13], buf[14], buf[15], buf[16]);
        if (copy_to_user((void __user *)arg, buf, PIC_BATTERY_LEN))
            return -EFAULT;
        return 0;
    }
    if (cmd == 4) {
        /* Backlight control: arg=0 off, arg=1 on, arg=2 show splash */
        if (arg == 2) {
            /* Redraw splash screen (4PDA logo) */
            u16 *fb16 = (u16 *)framebuffer;
            int i, j = 0;
            for (i = 0; i < SPLASH_RLE_LEN && j < LCD_W * LCD_H; i++) {
                int k;
                for (k = 0; k < splash_cnt[i] && j < LCD_W * LCD_H; k++)
                    fb16[j++] = splash_clr[i];
            }
            fb_dirty = 1;
            return 0;
        }
        /* Backlight control: arg=0 off, arg=1 on */
        if (arg)
            shadow_dir |= BIT_BL;
        else
            shadow_dir &= ~BIT_BL;
        gw_dir(shadow_dir);
        return 0;
    }
    if (cmd == 5) {
        /* Scene control: arg=0..5 select scene, arg=99 random, arg=100 stop */
        if (arg == 100) {
            splash_active = 0;
            console_phase = 2;
        } else {
            current_scene = (arg == 99) ? (jiffies % NUM_SCENES) : (arg % NUM_SCENES);
            splash_active = 1;
        }
        return 0;
    }
    if (cmd == 6) {
        /* Dashboard params: [nc, lte_rsrp, vpn_ms, kbps0, sig0, kbps1, sig1, ...] */
        int p[3 + MAX_DASH_CLIENTS * 2];
        int nc, i;
        if (copy_from_user(p, (void __user *)arg, sizeof(p)))
            return -EFAULT;
        nc = p[0];
        if (nc > MAX_DASH_CLIENTS) nc = MAX_DASH_CLIENTS;
        dash_params.num_clients = nc;
        dash_params.lte_rsrp = p[1];
        dash_params.vpn_ms = p[2];
        for (i = 0; i < nc; i++) {
            dash_params.cl[i].kbps = p[3 + i * 2];
            dash_params.cl[i].signal = p[3 + i * 2 + 1];
        }
        return 0;
    }
    if (cmd == 7) {
        /* Version info: copy "v1.0 Mar 22 2026 18:00:00" to userspace */
        char ver[64];
        int len;
        len = snprintf(ver, sizeof(ver), "v%s %s", LCD_DRV_VERSION, LCD_DRV_BUILD);
        if (copy_to_user((void __user *)arg, ver, len + 1))
            return -EFAULT;
        return 0;
    }
    if (cmd == 9) {
        int val = (int)arg;
        if (val >= 10000) {
            /* Raw 1-byte PIC cmd: arg = cmd + 10000 */
            pic_beep_ms = val - 10000;  /* abuse ms field as raw cmd */
            pic_beep_request = 2;       /* 2 = raw cmd mode */
        } else {
            /* Beep: arg = duration in ms */
            if (val <= 0 || val > 5000) val = 150;
            pic_beep_ms = val;
            pic_beep_request = 1;
        }
        return 0;
    }
    if (cmd == 8) {
        /* PIC SM0 write: send up to 8 bytes to PIC via auto mode.
         * arg = pointer to struct { u8 len; u8 data[8]; } */
        u8 p[9];
        u32 saved_ctl1 = gr(SM0_CTL1);
        int i;
        if (copy_from_user(p, (void __user *)arg, 9))
            return -EFAULT;
        if (p[0] < 1 || p[0] > 8)
            return -EINVAL;

        /* Send cmd 0x39 first (SSP REINIT — clears PIC SSPOV!) */
        gw(SM0_CTL1, 0x90644042); udelay(10);
        gw(SM0_CFG, 0xFA);
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, 1);
        gw(SM0_DATAOUT, 0x39);
        gw(SM0_STATUS, 0);
        { int w; for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); } }
        mdelay(10);

        /* Now send actual command */
        gw(SM0_CTL1, 0x90644042); udelay(10);
        gw(SM0_CFG, 0xFA);
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, p[0]);
        gw(SM0_DATAOUT, p[1]);
        gw(SM0_STATUS, 0);
        for (i = 2; i <= p[0]; i++) {
            int w; for (w = 0; w < 500; w++) { if (gr(0x918) & 0x02) break; udelay(10); }
            udelay(1000);
            gw(SM0_DATAOUT, p[i]);
        }
        { int w; for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); } }
        gw(SM0_CTL1, saved_ctl1); udelay(10);

        pr_info("PIC write [%d]: %02x %02x %02x\n", p[0], p[1], p[2], p[3]);
        return 0;
    }
    return -ENOTTY;
}


/* mmap: map framebuffer to userspace (zero-copy rendering) */
static int lcd_mmap(struct file *f, struct vm_area_struct *vma)
{
    unsigned long size = vma->vm_end - vma->vm_start;
    int i;

    if (size > fb_npages * PAGE_SIZE)
        return -EINVAL;

    for (i = 0; i < fb_npages && i * PAGE_SIZE < size; i++) {
        if (vm_insert_page(vma, vma->vm_start + i * PAGE_SIZE, fb_pages[i]))
            return -EAGAIN;
    }
    return 0;
}

static const struct file_operations lcd_fops = {
    .owner          = THIS_MODULE,
    .write          = lcd_fb_write,
    .llseek         = default_llseek,
    .unlocked_ioctl = lcd_ioctl,
    .mmap           = lcd_mmap,
};

static struct miscdevice lcd_dev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = DEVICE_NAME,
    .fops  = &lcd_fops,
    .mode  = 0666,
};

/* === Module init/exit === */

static int __init lcd_drv_init(void)
{
    int ret, i;

    gpio_base = ioremap(PALMBUS_BASE, 0x1000);
    if (!gpio_base) return -ENOMEM;

    /* Allocate framebuffer */
    fb_npages = (FB_SIZE + PAGE_SIZE - 1) / PAGE_SIZE;
    fb_pages = kmalloc(fb_npages * sizeof(struct page *), GFP_KERNEL);
    if (!fb_pages) { iounmap(gpio_base); return -ENOMEM; }

    framebuffer = vzalloc(fb_npages * PAGE_SIZE);
    if (!framebuffer) { kfree(fb_pages); iounmap(gpio_base); return -ENOMEM; }

    for (i = 0; i < fb_npages; i++)
        fb_pages[i] = vmalloc_to_page(framebuffer + i * PAGE_SIZE);

    /* Register device */
    ret = misc_register(&lcd_dev);
    if (ret) { kfree(framebuffer); kfree(fb_pages); iounmap(gpio_base); return ret; }

    /* Init LCD hardware */
    lcd_gpio_init();
    lcd_hw_reset();
    lcd_init_ili9341();
    shadow_dir |= BIT_BL; gw_dir(shadow_dir);

    /* First scene frame + logo — render thread continues animation.
     * Scene 6 = Matrix ("Wake up, Neo...") as the boot splash. */
    current_scene = 6;
    render_scene(current_scene, 0);
    lcd_flush_fb();

    /* SX8650 touchscreen init */
    sx8650_hw_init();

    /* PIC16 battery: send calibration via palmbus STOCK PROTOCOL,
     * then read battery via Linux I2C.
     *
     * Stock protocol: SM0_START = total_len (ONCE), poll 0x918 bit 1,
     * then SM0_DATAOUT for each byte. NOT SM0_START=0 per byte!
     */
    {
        int ci;
        u32 saved_ctl1 = gr(SM0_CTL1);
        u32 saved_cfg = gr(SM0_CFG);

        pr_info("PIC init 0x39 + 0x41 + calibration...\n");

        /* Step -1: SSP REINIT {0x39} — clear SSPOV from i2c-mt7621 boot! */
        gw(SM0_CTL1, 0x90644042); udelay(10);
        gw(SM0_CFG, 0xFA);
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, 1);
        gw(SM0_DATAOUT, 0x39);
        gw(SM0_STATUS, 0);
        { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
        mdelay(10);

        /* Step 0: PIC INIT {0x41} — required for ADC to start.
         * Side effect: buzzer ON. Immediately send buzzer OFF after. */
        gw(SM0_CTL1, 0x90644042); udelay(10);
        gw(SM0_CFG, 0xFA);
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, 1);
        gw(SM0_DATAOUT, 0x41);
        gw(SM0_STATUS, 0);
        { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
        mdelay(500);

        /* Buzzer OFF {0x34, 0x00, 0x00} */
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, 3);
        gw(SM0_DATAOUT, 0x34);
        gw(SM0_STATUS, 0);
        { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
        udelay(1000);
        gw(SM0_DATAOUT, 0x00);
        { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
        udelay(1000);
        gw(SM0_DATAOUT, 0x00);
        { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
        mdelay(100);

        pr_info("PIC init done, buzzer off sent\n");

        /* Byte-swap helper: stock firmware swaps each int16 before sending.
         * Our pic_calib.h has big-endian {0x00,0x04} = value 4.
         * Stock sends as {0x04,0x00} (swapped). */
        {
            u8 calib_buf[401];

            /* Step 0: Wake command {0x33, 0x00, 0x01} before calibration */
            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 3);
            gw(SM0_DATAOUT, 0x33);
            gw(SM0_STATUS, 0);
            { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
            udelay(1000);
            gw(SM0_DATAOUT, 0x00);
            { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
            udelay(1000);
            gw(SM0_DATAOUT, 0x01);
            { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
            mdelay(5);

            /* Step 1: Table 1 — byte-swap int16 pairs, keep cmd byte */
            calib_buf[0] = pic_calib1[0]; /* cmd = 0x03, no swap */
            for (ci = 1; ci < 401; ci += 2) {
                calib_buf[ci]     = pic_calib1[ci + 1]; /* swap: low byte first */
                calib_buf[ci + 1] = pic_calib1[ci];     /* then high byte */
            }
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 401);
            gw(SM0_DATAOUT, calib_buf[0]);
            gw(SM0_STATUS, 0);
            for (ci = 1; ci < 401; ci++) {
                { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
                udelay(1000);
                gw(SM0_DATAOUT, calib_buf[ci]);
            }
            { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
            mdelay(5);

            /* Step 2: Table 2 — byte-swap */
            calib_buf[0] = pic_calib2[0]; /* cmd = 0x2E */
            for (ci = 1; ci < 401; ci += 2) {
                calib_buf[ci]     = pic_calib2[ci + 1];
                calib_buf[ci + 1] = pic_calib2[ci];
            }
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 401);
            gw(SM0_DATAOUT, calib_buf[0]);
            gw(SM0_STATUS, 0);
            for (ci = 1; ci < 401; ci++) {
                { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
                udelay(1000);
                gw(SM0_DATAOUT, calib_buf[ci]);
            }
            { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
        }

        /* Restore ALL SM0 registers for Linux I2C driver */
        gw(SM0_CTL1, saved_ctl1); udelay(10);
        gw(SM0_CFG, saved_cfg); udelay(10);

        pr_info("PIC calibration sent (stock protocol)\n");

        /* Wait for PIC to process calibration */
        mdelay(2000);

        /* Send battery read command {0x2F, 0x00, 0x02} via palmbus write */
        {
            u8 bat_cmd[3] = { 0x2F, 0x00, 0x02 };
            u8 bat_resp[17] = {0};

            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 3);
            gw(SM0_DATAOUT, bat_cmd[0]);
            gw(SM0_STATUS, 0);
            for (ci = 1; ci < 3; ci++) {
                { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x02) break; udelay(10); } }
                udelay(1000);
                gw(SM0_DATAOUT, bat_cmd[ci]);
            }
            { int p; for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); } }
            mdelay(200);

            /* Read 17 bytes using NEW i2c-mt7621 register interface (6.12+)
             * Registers at base 0x900:
             *   SM0CTL0 = 0x940, SM0CTL1 = 0x944
             *   SM0D0 = 0x950, SM0D1 = 0x954
             * Protocol: START → addr+R → READ chunks → STOP
             */
            /* Restore SM0CTL0 for normal operation */
            gw(NEW_CTL0, saved_ctl1); udelay(10);

            /* Wait idle */
            { int p; for (p = 0; p < 5000; p++) { if (!(gr(NEW_CTL1) & N_TRI)) break; udelay(10); } }

            /* START */
            gw(NEW_CTL1, N_START | N_TRI);
            { int p; for (p = 0; p < 5000; p++) { if (!(gr(NEW_CTL1) & N_TRI)) break; udelay(10); } }

            /* Write address + R bit */
            gw(NEW_D0, (PIC_ADDR << 1) | 1);
            gw(NEW_CTL1, N_WRITE | N_TRI | N_PGLEN(1));
            { int p; for (p = 0; p < 5000; p++) { if (!(gr(NEW_CTL1) & N_TRI)) break; udelay(10); } }

            /* Read 17 bytes in 8+8+1 chunks */
            {
                int rd_off = 0;
                int remaining = 17;
                while (remaining > 0) {
                    int chunk = (remaining > 8) ? 8 : remaining;
                    u32 cmd = (remaining > 8) ? N_READ : N_READ_L;
                    u32 d0, d1;

                    gw(NEW_CTL1, cmd | N_TRI | N_PGLEN(chunk));
                    { int p; for (p = 0; p < 5000; p++) { if (!(gr(NEW_CTL1) & N_TRI)) break; udelay(10); } }

                    d0 = gr(NEW_D0);
                    d1 = gr(NEW_D1);
                    memcpy(&bat_resp[rd_off], &d0, chunk > 4 ? 4 : chunk);
                    if (chunk > 4)
                        memcpy(&bat_resp[rd_off + 4], &d1, chunk - 4);

                    rd_off += chunk;
                    remaining -= chunk;
                }
            }

            /* STOP */
            gw(NEW_CTL1, N_STOP | N_TRI);
            { int p; for (p = 0; p < 5000; p++) { if (!(gr(NEW_CTL1) & N_TRI)) break; udelay(10); } }

            pr_info("PIC raw [17]: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
                    bat_resp[0], bat_resp[1], bat_resp[2], bat_resp[3],
                    bat_resp[4], bat_resp[5], bat_resp[6], bat_resp[7],
                    bat_resp[8], bat_resp[9], bat_resp[10], bat_resp[11],
                    bat_resp[12], bat_resp[13], bat_resp[14], bat_resp[15],
                    bat_resp[16]);
            {
                /* Parse: try stock format interpretation */
                int raw_adc = (bat_resp[0] << 8) | bat_resp[1];
                int vref = bat_resp[2];
                int c_pct = (signed char)bat_resp[6];
                int f_pct = (signed char)bat_resp[7];
                int batstat = bat_resp[10];
                int batcount = bat_resp[11];
                pr_info("PIC parse: raw=%d(0x%03x) vref=%d C%%=%d F%%=%d BatStat=%d BatCnt=%d\n",
                        raw_adc, raw_adc, vref, c_pct, f_pct, batstat, batcount);
            }
            memcpy(pic_battery_raw, bat_resp, 17);
            pic_battery_valid = (bat_resp[0] != 0xAA && bat_resp[0] != 0xFF && bat_resp[0] != 0x55);
        }
    }

    /* Start render thread */
    render_thread = kthread_run(render_fn, NULL, "lcd_render");

    /* Start touch thread */
    touch_thread = kthread_run(touch_fn, NULL, "lcd_touch");

    pr_info("%s by Sublimity — START (fb=%dx%d, %d bytes)\n",
            LCD_DRV_VERSION, LCD_W, LCD_H, FB_SIZE);
    return 0;
}

static void __exit lcd_drv_exit(void)
{
    if (touch_thread) kthread_stop(touch_thread);
    if (render_thread) kthread_stop(render_thread);
    if (touch_i2c_adap) i2c_put_adapter(touch_i2c_adap);
    misc_deregister(&lcd_dev);
    vfree(framebuffer);
    kfree(fb_pages);
    if (gpio_base) iounmap(gpio_base);
    pr_info("%s by Sublimity — STOP\n", LCD_DRV_VERSION);
}

module_init(lcd_drv_init);
module_exit(lcd_drv_exit);
MODULE_VERSION(LCD_DRV_VERSION);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ILI9341 LCD + SX8650 Touch + PIC16 Battery for Almond 3S");
MODULE_AUTHOR("Sublimity");
