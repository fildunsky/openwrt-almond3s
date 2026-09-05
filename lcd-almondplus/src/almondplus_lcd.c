// SPDX-License-Identifier: GPL-2.0-only

#define pr_fmt(fmt) "almondplus-lcd: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/kthread.h>
#include <linux/mutex.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>
#include <linux/kmsg_dump.h>
#include <linux/input.h>
#include <linux/string.h>
#include <linux/jiffies.h>
#include <linux/math64.h>
#include <linux/workqueue.h>
#include <linux/i2c.h>

#define DEVICE_NAME "lcd"

#ifndef LCD_DRV_BUILD
#define LCD_DRV_BUILD "unknown"
#endif

#define LCD_W 480
#define LCD_H 320
#define FB_SIZE (LCD_W * LCD_H * 2)

#define GPIO4_PHYS 0xF0070250
#define MUX4_PHYS  0xF000002C
#define OFFS_CFG 0x00
#define OFFS_OUT 0x04
#define OFFS_IN  0x08

#define DATA_MASK 0x0000FFFFu
#define BIT_WR  BIT(18)
#define BIT_RST BIT(20)
#define BIT_CS  BIT(21)
#define BIT_DC  BIT(22)
#define BIT_RD  BIT(23)
#define BIT_BL  BIT(27)
#define LCD_PIN_MASK (DATA_MASK | BIT_WR | BIT_RST | BIT_CS | BIT_DC | BIT_RD | BIT_BL)

#define TOUCH_RAW_MAX 4095

static void __iomem *gpio_base;
static void __iomem *mux_reg;
static u32 shadow;
static u32 bl_bit;

static u16 *framebuffer;
static struct page **fb_pages;
static int fb_npages;
static u16 *flush_snap;
static u16 *prev_snap;
static bool prev_valid;
static u32 inval_gen;
static u8 *ufb;

static int lg_w = LCD_W, lg_h = LCD_H, lg_ox, lg_oy;
static size_t lg_size = FB_SIZE;

static int fill = 1;
module_param(fill, int, 0644);
MODULE_PARM_DESC(fill, "1 = scale logical frame to fill panel, 0 = center it");
static int fill_active;
static u16 sx_map[LCD_W];
static u16 sy_map[LCD_H];

static struct task_struct *render_thread;
static int fb_dirty = 1;
static int fb_writing;
static struct file *fb_writer;
static int splash_active = 1;
static int console_phase;
static volatile bool snap_ready;
static volatile bool flush_busy;
static DEFINE_MUTEX(fb_lock);

static int stat_rows, stat_us, stat_frames;

static int lcd_rot;
static int lcd_rot_pending;
static int panel_reinit_pending;
static u32 pcmd_q[16];
static int pcmd_head, pcmd_tail;

static int splash = 1;
module_param(splash, int, 0644);
MODULE_PARM_DESC(splash, "1 = boot banner with kernel log until userspace draws");

static int stage = 7;
module_param(stage, int, 0644);
MODULE_PARM_DESC(stage, "bit0=touch handler, bit1=render thread, bit2=panel init");

static int rcpu = 0;
module_param(rcpu, int, 0644);
MODULE_PARM_DESC(rcpu, "pin render thread to this CPU, -1 = unpinned");

static int tcal[4] = { 290, 3685, 350, 3585 };
module_param_array(tcal, int, NULL, 0644);
MODULE_PARM_DESC(tcal, "touch calibration raw x0,x1,y0,y1");
static int tswap = 1;
module_param(tswap, int, 0644);
static int tinvx = 1;
module_param(tinvx, int, 0644);
static int tinvy;
module_param(tinvy, int, 0644);

static int touch_x, touch_y, touch_pressed;
static int touch_raw_x, touch_raw_y, touch_raw_pressed;
static int touch_events;


static inline void bus_out(u32 v)
{
	__raw_writel(v, gpio_base + OFFS_OUT);
}

static inline u32 bus_idle(void)
{
	return (shadow & ~(DATA_MASK | BIT_BL)) | BIT_WR | BIT_CS | bl_bit;
}

static void lcd_cmd(u8 c)
{
	shadow = (shadow & ~(DATA_MASK | BIT_CS | BIT_DC | BIT_WR | BIT_BL)) | bl_bit | c;
	bus_out(shadow);
	shadow |= BIT_WR;
	bus_out(shadow);
}

static void lcd_dat(u8 d)
{
	shadow = (shadow & ~(DATA_MASK | BIT_CS | BIT_WR | BIT_BL)) | BIT_DC | bl_bit | d;
	bus_out(shadow);
	shadow |= BIT_WR;
	bus_out(shadow);
}

static void lcd_cs_deselect(void)
{
	shadow = bus_idle();
	bus_out(shadow);
}

static void lcd_window(int c0, int c1, int r0, int r1)
{
	lcd_cmd(0x2A);
	lcd_dat(c0 >> 8); lcd_dat(c0 & 0xFF);
	lcd_dat(c1 >> 8); lcd_dat(c1 & 0xFF);
	lcd_cmd(0x2B);
	lcd_dat(r0 >> 8); lcd_dat(r0 & 0xFF);
	lcd_dat(r1 >> 8); lcd_dat(r1 & 0xFF);
}

static void lcd_gpio_init(void)
{
	u32 v;

	v = __raw_readl(mux_reg);
	v |= LCD_PIN_MASK;
	__raw_writel(v, mux_reg);

	v = __raw_readl(gpio_base + OFFS_CFG);
	v &= ~LCD_PIN_MASK;
	__raw_writel(v, gpio_base + OFFS_CFG);

	shadow = __raw_readl(gpio_base + OFFS_OUT) & ~LCD_PIN_MASK;
	shadow |= BIT_WR | BIT_CS | BIT_RD | BIT_DC | BIT_RST | bl_bit;
	bus_out(shadow);
}

static void lcd_hw_reset(void)
{
	shadow = bus_idle() | BIT_RST;
	bus_out(shadow);
	msleep(1);
	shadow &= ~BIT_RST;
	bus_out(shadow);
	msleep(10);
	shadow |= BIT_RST;
	bus_out(shadow);
	msleep(120);
}

static u8 madctl(void)
{
	return lcd_rot ? 0x28 : 0xE8;
}

static void lcd_read_regs(u8 c, u8 *out, int n)
{
	u32 cfg;
	int i;

	lcd_cmd(c);
	cfg = __raw_readl(gpio_base + OFFS_CFG);
	__raw_writel(cfg | DATA_MASK, gpio_base + OFFS_CFG);
	shadow = (shadow & ~(BIT_CS | BIT_BL)) | BIT_DC | BIT_WR | BIT_RD | bl_bit;
	bus_out(shadow);
	ndelay(500);
	for (i = 0; i < n; i++) {
		shadow &= ~BIT_RD;
		bus_out(shadow);
		ndelay(500);
		out[i] = __raw_readl(gpio_base + OFFS_IN) & DATA_MASK;
		shadow |= BIT_RD;
		bus_out(shadow);
		ndelay(500);
	}
	__raw_writel(cfg, gpio_base + OFFS_CFG);
	lcd_cs_deselect();
}

static void lcd_init_panel(void)
{
	static const u8 gamma_p[] = { 0x00, 0x07, 0x10, 0x09, 0x17, 0x0B, 0x40, 0x8A,
				      0x4B, 0x0A, 0x0D, 0x0F, 0x15, 0x16, 0x0F };
	static const u8 gamma_n[] = { 0x00, 0x1A, 0x1B, 0x02, 0x0D, 0x05, 0x30, 0x35,
				      0x43, 0x02, 0x0A, 0x09, 0x32, 0x36, 0x0F };
	int i;

	lcd_cmd(0xE0);
	for (i = 0; i < ARRAY_SIZE(gamma_p); i++)
		lcd_dat(gamma_p[i]);
	lcd_cmd(0xE1);
	for (i = 0; i < ARRAY_SIZE(gamma_n); i++)
		lcd_dat(gamma_n[i]);
	msleep(120);
	lcd_cmd(0xB1); lcd_dat(0xA0);
	lcd_cmd(0xB4); lcd_dat(0x02);
	lcd_cmd(0xC0); lcd_dat(0x17); lcd_dat(0x15);
	lcd_cmd(0xC1); lcd_dat(0x41);
	lcd_cmd(0xC5); lcd_dat(0x00); lcd_dat(0x0A); lcd_dat(0x80);
	msleep(120);
	lcd_cmd(0xB6); lcd_dat(0x02);
	lcd_cmd(0x36); lcd_dat(madctl());
	lcd_cmd(0x3A); lcd_dat(0x55);
	lcd_cmd(0xBE); lcd_dat(0x00); lcd_dat(0x04);
	lcd_cmd(0xE9); lcd_dat(0x00);
	lcd_cmd(0xF7); lcd_dat(0xA9); lcd_dat(0x51); lcd_dat(0x2C); lcd_dat(0x82);
	lcd_cmd(0x11);
	msleep(120);
	lcd_cmd(0x29);
	lcd_window(0, LCD_W - 1, 0, LCD_H - 1);
	lcd_cmd(0x2C);
	lcd_cs_deselect();
	msleep(20);
}


#define BL_MAX 255
#define BL_SLOT_PIXELS 4

static volatile bool bl_bus_busy;
static int bl_level = BL_MAX;
static int touch_irq = -1;
static int mask = 0;

static inline void bl_pin(bool on)
{
	bl_bit = on ? BIT_BL : 0;
	if (!bl_bus_busy) {
		if (mask && touch_irq >= 0)
			disable_irq(touch_irq);
		shadow = (shadow & ~BIT_BL) | bl_bit;
		bus_out(shadow);
		if (mask && touch_irq >= 0)
			enable_irq(touch_irq);
	}
}

#define BL_PWM_NS   4000000UL
#define BL_PWM_MIN  120000UL
static struct hrtimer bl_timer;
static int bl_timer_on;
static int bl_duty = BL_MAX;
static bool bl_on_phase = true;

static enum hrtimer_restart bl_timer_fn(struct hrtimer *t)
{
	int d = bl_duty;
	u64 on_ns, off_ns, next;

	if (d < 0) d = 0;
	if (d > BL_MAX) d = BL_MAX;
	on_ns = (u64)BL_PWM_NS * d / BL_MAX;
	off_ns = BL_PWM_NS - on_ns;

	if (d >= BL_MAX) { bl_bit = BIT_BL; next = BL_PWM_NS; }
	else if (d <= 0) { bl_bit = 0; next = BL_PWM_NS; }
	else if (bl_on_phase) { bl_bit = BIT_BL; next = on_ns; bl_on_phase = false; }
	else { bl_bit = 0; next = off_ns; bl_on_phase = true; }

	if (!bl_bus_busy && gpio_base) {
		shadow = (shadow & ~BIT_BL) | bl_bit;
		bus_out(shadow);
	}
	if (next < BL_PWM_MIN) next = BL_PWM_MIN;
	hrtimer_forward_now(t, ns_to_ktime(next));
	return HRTIMER_RESTART;
}

static void bl_pwm_start(void)
{
	if (bl_timer_on)
		return;
	hrtimer_setup(&bl_timer, bl_timer_fn, CLOCK_MONOTONIC, HRTIMER_MODE_REL_PINNED);
	bl_timer_on = 1;
	hrtimer_start(&bl_timer, ns_to_ktime(BL_PWM_NS), HRTIMER_MODE_REL_PINNED);
}

static void bl_set_level(int level)
{
	if (level < 0) level = 0;
	if (level > BL_MAX) level = BL_MAX;
	bl_level = level;
	bl_duty = level;
}

module_param(mask, int, 0644);
MODULE_PARM_DESC(mask, "mask the touch IRQ around bus bursts");

static inline void bus_begin(void)
{
	if (mask && touch_irq >= 0)
		disable_irq(touch_irq);
	bl_bus_busy = true;
}

static inline void bus_end(void)
{
	lcd_cs_deselect();
	bl_bus_busy = false;
	if (mask && touch_irq >= 0)
		enable_irq(touch_irq);
}


static u8 digR[32], digG[64], digB[32];
static int dig_level = BL_MAX;
static int warm_level;
static int dig_plain = 1;
static int warm_req = -1, dig_req = -1;
static int bl_req = -1;

static void dig_build(void)
{
	int i;
	int gk = 255 - warm_level * 55 / 100;
	int bk = 255 - warm_level * 135 / 100;

	for (i = 0; i < 32; i++) {
		digR[i] = i * dig_level / BL_MAX;
		digB[i] = i * dig_level / BL_MAX * bk / 255;
	}
	for (i = 0; i < 64; i++)
		digG[i] = i * dig_level / BL_MAX * gk / 255;
	dig_plain = (dig_level == BL_MAX && warm_level == 0);
}

static inline u16 dig_pixel(u16 p)
{
	return ((u16)digR[(p >> 11) & 0x1F] << 11) |
	       ((u16)digG[(p >> 5) & 0x3F] << 5) |
	       (u16)digB[p & 0x1F];
}

static void prev_invalidate(void)
{
	prev_valid = false;
	inval_gen++;
}


static void lcd_send_rows(int r0, int r1, int c0, int c1)
{
	const int w = c1 - c0 + 1;
	int n = (r1 - r0 + 1) * w;
	const u16 *src = flush_snap + r0 * LCD_W + c0;
	const int plain = dig_plain;
	static int slot_pos, since_yield;
	u32 hi;
	int i, col = 0;

	lcd_cmd(0x2B);
	lcd_dat(r0 >> 8); lcd_dat(r0 & 0xFF);
	lcd_dat(r1 >> 8); lcd_dat(r1 & 0xFF);
	lcd_cmd(0x2C);

	hi = (shadow & ~(DATA_MASK | BIT_CS | BIT_WR | BIT_BL)) | BIT_DC | bl_bit;

	for (i = 0; i < n; i++) {
		u16 px = plain ? src[col] : dig_pixel(src[col]);
		u32 v = hi | px;

		bus_out(v);
		bus_out(v | BIT_WR);
		if (++col == w) {
			col = 0;
			src += LCD_W;
		}
		if ((++slot_pos & (BL_SLOT_PIXELS - 1)) != 0)
			continue;
		if (++since_yield >= 512) {
			since_yield = 0;
			cond_resched();
		}
	}
	shadow = hi | BIT_WR;
	bus_out(shadow);
}

static int win_c0, win_c1;

static void lcd_flush_fb(void)
{
	int r, r0;
	u32 gen0;
	bool snap_partial = false;

	if (!snap_ready) {
		mutex_lock(&fb_lock);
		memcpy(flush_snap, framebuffer, FB_SIZE);
		mutex_unlock(&fb_lock);
	}
	snap_ready = false;
	flush_busy = true;
	gen0 = inval_gen;

	{
		int c, lo = LCD_W, hi = -1;

		if (!prev_valid || !prev_snap) {
			lo = 0; hi = LCD_W - 1;
		} else {
			for (r = 0; r < LCD_H; r++) {
				const u16 *a = flush_snap + r * LCD_W;
				const u16 *b = prev_snap + r * LCD_W;

				if (!memcmp(a, b, LCD_W * sizeof(u16)))
					continue;
				for (c = 0; c < lo; c++)
					if (a[c] != b[c]) { lo = c; break; }
				for (c = LCD_W - 1; c > hi; c--)
					if (a[c] != b[c]) { hi = c; break; }
			}
		}
		if (hi < lo) { lo = 0; hi = LCD_W - 1; }
		win_c0 = lo; win_c1 = hi;
	}

	bus_begin();
	lcd_cmd(0x2A);
	lcd_dat(win_c0 >> 8); lcd_dat(win_c0 & 0xFF);
	lcd_dat(win_c1 >> 8); lcd_dat(win_c1 & 0xFF);

	{
		ktime_t t0 = ktime_get();

		stat_rows = 0;
		if (!prev_valid || !prev_snap) {
			lcd_send_rows(0, LCD_H - 1, win_c0, win_c1);
			stat_rows = LCD_H;
		} else {
			r = 0;
			while (r < LCD_H) {
				if (!memcmp(flush_snap + r * LCD_W, prev_snap + r * LCD_W,
					    LCD_W * sizeof(u16))) {
					r++;
					continue;
				}
				r0 = r;
				while (r < LCD_H && memcmp(flush_snap + r * LCD_W,
							   prev_snap + r * LCD_W,
							   LCD_W * sizeof(u16)))
					r++;
				lcd_send_rows(r0, r - 1, win_c0, win_c1);
				stat_rows += r - r0;
			}
		}
		stat_us = (int)ktime_to_us(ktime_sub(ktime_get(), t0));
		stat_frames++;
	}
	bus_end();

	if (prev_snap && !snap_partial && gen0 == inval_gen) {
		memcpy(prev_snap, flush_snap, FB_SIZE);
		prev_valid = true;
	}
	flush_busy = false;
}


static const u8 kfont[96][5] = {
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
	{0x00,0x36,0x36,0x00,0x00},{0x00,0x56,0x36,0x00,0x00},
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

static void fb_putchar(u16 *fb, int x, int y, char ch, u16 fg, u16 bg, int s)
{
	int idx = ch - 32, col, row, sx, sy;
	const u8 *g;

	if (idx < 0 || idx > 94)
		idx = 0;
	g = kfont[idx];
	for (row = 0; row < 7; row++)
		for (col = 0; col < 5; col++) {
			u16 c = (g[col] & (1 << row)) ? fg : bg;

			for (sy = 0; sy < s; sy++)
				for (sx = 0; sx < s; sx++) {
					int px = x + col * s + sx, py = y + row * s + sy;

					if ((unsigned)px < LCD_W && (unsigned)py < LCD_H)
						fb[py * LCD_W + px] = c;
				}
		}
}

static const char *banner_lines[] = {
	"  _______ __                          __         ",
	" |   _   |  |.--------.-----.-----.--|  |  _     ",
	" |       |  ||        |  _  |     |  _  |_| |_   ",
	" |___|___|  ||__|__|__|_____|__|__|_____|_   _|  ",
	"         |____|  S E C O N D   L I F E    |_|  ",
};
#define BANNER_NLINES ((int)ARRAY_SIZE(banner_lines))
#define BANNER_GREEN 0x1C6A
#define BANNER_LOGO  0x258C
#define BANNER_LINE_H 10
#define BANNER_TOP 16
#define BANNER_PAD 22

#define BLOG_LINES 32
#define BLOG_W 80
static char blog_ring[BLOG_LINES][BLOG_W];
static int blog_head, blog_total;
static char ext_line[128];
static int ext_ttl;

static unsigned long scene_ms(void)
{
	return jiffies_to_msecs(jiffies);
}

static void banner_update_log(void)
{
	struct kmsg_dump_iter iter;
	char buf[256];
	size_t len;

	blog_head = 0;
	blog_total = 0;
	kmsg_dump_rewind(&iter);
	while (kmsg_dump_get_line(&iter, false, buf, sizeof(buf) - 1, &len)) {
		char *msg;

		if (!len)
			continue;
		buf[len] = 0;
		while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
			buf[--len] = 0;
		msg = buf;
		if (msg[0] == '<') {
			char *p = strchr(msg, '>');

			if (p)
				msg = p + 1;
		}
		if (msg[0] == '[') {
			char *p = strchr(msg, ']');

			if (p) {
				msg = p + 1;
				if (*msg == ' ')
					msg++;
			}
		}
		if (!*msg)
			continue;
		strscpy(blog_ring[blog_head], msg, BLOG_W);
		blog_head = (blog_head + 1) % BLOG_LINES;
		blog_total++;
	}
}

static void scene_banner(void)
{
	u16 *fb = framebuffer;
	int i, j, maxlen = 0, left, top, total_h, cy;
	int boot = (console_phase == 0);

	memset(fb, 0, FB_SIZE);
	for (i = 0; i < BANNER_NLINES; i++) {
		int l = (int)strlen(banner_lines[i]);

		if (l > maxlen)
			maxlen = l;
	}
	total_h = (BANNER_NLINES - 1) * BANNER_LINE_H + 7;
	if (boot) {
		left = (LCD_W - maxlen * 6) / 2;
		if (left < 0)
			left = 0;
		top = BANNER_PAD;
	} else {
		left = (LCD_W - maxlen * 6) / 2;
		if (left < 0)
			left = 0;
		top = (LCD_H - total_h) / 2;
	}
	cy = top + (BANNER_NLINES - 1) * BANNER_LINE_H;
	for (i = 0; i < BANNER_NLINES; i++) {
		const char *s = banner_lines[i];
		int x = left, y = top + i * BANNER_LINE_H;

		for (j = 0; s[j]; j++) {
			fb_putchar(fb, x, y, s[j], BANNER_LOGO, 0x0000, 1);
			x += 6;
		}
	}
	if ((scene_ms() / 500) % 2 == 0) {
		int cx = left + ((int)strlen(banner_lines[BANNER_NLINES - 1]) + 1 - 8) * 6;
		int rr, cc;

		for (rr = 0; rr < 7; rr++)
			for (cc = 0; cc < 5; cc++)
				if ((unsigned)(cx + cc) < LCD_W && (unsigned)(cy + rr) < LCD_H)
					fb[(cy + rr) * LCD_W + cx + cc] = BANNER_LOGO;
	}
	if (boot) {
		int logx = BANNER_PAD;
		int logy = top + total_h + 14;
		int shown, start, k;
		static unsigned long log_at;

		if (scene_ms() - log_at >= 150) {
			log_at = scene_ms();
			banner_update_log();
		}
		shown = blog_total < BLOG_LINES ? blog_total : BLOG_LINES;
		start = blog_total < BLOG_LINES ? 0 : blog_head;
		for (k = 0; k < shown; k++) {
			int s = (start + k) % BLOG_LINES;
			int yy = logy + k * 8;
			const char *ls = blog_ring[s];
			int x = logx;

			if (yy + 7 > LCD_H - BANNER_PAD)
				break;
			for (j = 0; ls[j] && x + 6 <= LCD_W - BANNER_PAD; j++) {
				fb_putchar(fb, x, yy, ls[j], BANNER_GREEN, 0x0000, 1);
				x += 6;
			}
		}
	}
	if (ext_ttl > 0) {
		int x = 4, y = LCD_H - 9;

		ext_ttl--;
		for (j = 0; ext_line[j] && x + 6 <= LCD_W; j++) {
			fb_putchar(fb, x, y, ext_line[j], BANNER_GREEN, 0x0000, 1);
			x += 6;
		}
	}
}


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

#define MATRIX_COLS (LCD_W / 6)
#define MATRIX_ROWS (LCD_H / 7)
#define RAB_W 20
#define RAB_H 22
#define RAB_X0 ((MATRIX_COLS - RAB_W) / 2)
#define RAB_Y0 6

static char matrix_line[128];
static int matrix_init;
static unsigned long matrix_t0;
static int matrix_ms;
static u8 m_drop_y[MATRIX_COLS];
static u8 m_drop_sp[MATRIX_COLS];
static u8 m_drop_tick[MATRIX_COLS];
static char m_chr[MATRIX_ROWS][MATRIX_COLS];
static u8 m_sticky[MATRIX_ROWS][MATRIX_COLS];
static char m_sticky_chr[MATRIX_ROWS][MATRIX_COLS];
static int current_scene = 1;

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

static void translit(const char *src, char *dst, int dstsz)
{
	static const char *TAB[32] = {
		"A","B","V","G","D","E","Zh","Z","I","Y","K","L","M","N","O","P",
		"R","S","T","U","F","H","Ts","Ch","Sh","Sch","","Y","","E","Yu","Ya"
	};
	int o = 0;

	while (*src && o < dstsz - 4) {
		unsigned char c = (unsigned char)*src;
		unsigned int cp;

		if (c < 0x80) {
			dst[o++] = (c >= 32) ? (char)c : ' ';
			src++;
			continue;
		}
		if ((c & 0xE0) == 0xC0 && (src[1] & 0xC0) == 0x80) {
			cp = ((c & 0x1F) << 6) | (src[1] & 0x3F);
			src += 2;
		} else {
			src++;
			continue;
		}
		if (cp == 0x401) cp = 0x415;
		if (cp == 0x451) cp = 0x435;
		if (cp >= 0x410 && cp <= 0x42F) {
			const char *t = TAB[cp - 0x410];

			while (*t && o < dstsz - 1)
				dst[o++] = *t++;
		} else if (cp >= 0x430 && cp <= 0x44F) {
			const char *t = TAB[cp - 0x430];
			int first = 1;

			while (*t && o < dstsz - 1) {
				char ch = *t++;

				dst[o++] = first ? (char)(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch) : ch;
				first = 0;
			}
		}
	}
	dst[o] = 0;
}

static void matrix_update_line(void)
{
	struct kmsg_dump_iter iter;
	char buf[256];
	size_t len;

	if (ext_ttl > 0)
		return;
	kmsg_dump_rewind(&iter);
	while (kmsg_dump_get_line(&iter, false, buf, sizeof(buf) - 1, &len)) {
		char *msg;

		if (!len)
			continue;
		buf[len] = 0;
		while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
			buf[--len] = 0;
		msg = buf;
		if (msg[0] == '<') {
			char *p = strchr(msg, '>');

			if (p)
				msg = p + 1;
		}
		if (msg[0] == '[') {
			char *p = strchr(msg, ']');

			if (p) {
				msg = p + 1;
				if (*msg == ' ')
					msg++;
			}
		}
		if (strncmp(msg, "almondplus-lcd", 14) == 0)
			continue;
		if (*msg)
			translit(msg, matrix_line, sizeof(matrix_line));
	}
}

static inline int in_rabbit(int r, int c)
{
	int lr = r - RAB_Y0, lc = c - RAB_X0;

	if (lr < 0 || lr >= RAB_H || lc < 0 || lc >= RAB_W)
		return 0;
	return rabbit_mask[lr][lc] == '#';
}

static void matrix_draw_char(u16 *fb, int row, int col, char ch, u16 color)
{
	int idx = ch - 32;
	const u8 *gp;
	int ci, ri;
	int px = col * 6, py = row * 7;

	if (idx < 0 || idx > 94)
		idx = 0;
	gp = kfont[idx];
	for (ri = 0; ri < 7; ri++)
		for (ci = 0; ci < 5; ci++)
			if ((unsigned)(px + ci) < LCD_W && (unsigned)(py + ri) < LCD_H &&
			    (gp[ci] & (1 << ri)))
				fb[(py + ri) * LCD_W + px + ci] = color;
}

static void matrix_text(u16 *fb, int ty, const char *s, u16 fg, int sc)
{
	int len = (int)strlen(s);
	int tx = (LCD_W - len * 6 * sc) / 2;
	int y2, x2, j;

	if (tx < 0)
		tx = 0;
	for (y2 = ty - 2; y2 < ty + 7 * sc + 2 && y2 < LCD_H; y2++)
		for (x2 = 0; x2 < LCD_W; x2++)
			fb[y2 * LCD_W + x2] = 0;
	for (j = 0; s[j]; j++)
		fb_putchar(fb, tx + j * 6 * sc, ty, s[j], fg, 0, sc);
}

static void scene_matrix(int t)
{
	u16 *fb = framebuffer;
	int i, k, r, c, ms, accumulating, steps;
	const char *msg = NULL;
	static unsigned long line_at;

	if (!matrix_init) {
		for (i = 0; i < MATRIX_COLS; i++) {
			m_drop_y[i] = sin_lut[(i * 7) & 0xFF] % MATRIX_ROWS;
			m_drop_sp[i] = 1 + (sin_lut[(i * 13) & 0xFF] & 0x03);
			m_drop_tick[i] = 0;
		}
		for (r = 0; r < MATRIX_ROWS; r++)
			for (c = 0; c < MATRIX_COLS; c++) {
				m_chr[r][c] = 33 + ((r * 7 + c * 13) % 94);
				m_sticky[r][c] = 0;
				m_sticky_chr[r][c] = m_chr[r][c];
			}
		memset(fb, 0, FB_SIZE);
		matrix_init = 1;
		matrix_t0 = jiffies;
		matrix_ms = 0;
	}

	for (i = 0; i < LCD_W * LCD_H; i++) {
		u16 pxv = fb[i];
		u8 g;

		if (!pxv)
			continue;
		g = (pxv >> 5) & 0x3F;
		fb[i] = (u16)((g * 13) >> 4) << 5;
	}

	ms = (int)jiffies_to_msecs(jiffies - matrix_t0);
	accumulating = (ms >= 1400 && ms < 5750);
	steps = (ms - matrix_ms) / 25;
	if (steps < 1)
		steps = 1;
	if (steps > 8)
		steps = 8;
	matrix_ms = ms;

	while (steps-- > 0) {
		t++;
		for (i = 0; i < MATRIX_COLS; i++) {
			m_drop_tick[i]++;
			if (m_drop_tick[i] < m_drop_sp[i])
				continue;
			m_drop_tick[i] = 0;
			m_drop_y[i]++;
			if (m_drop_y[i] >= MATRIX_ROWS + 12) {
				m_drop_y[i] = 0;
				m_drop_sp[i] = 1 + (sin_lut[(t + i * 11) & 0xFF] & 0x03);
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
	}

	for (i = 0; i < MATRIX_COLS; i++) {
		int head = m_drop_y[i];
		for (k = 0; k < 10; k++) {
			int rr = head - k;
			u16 color;

			if (rr < 0 || rr >= MATRIX_ROWS)
				continue;
			if (k == 0) {
				color = 0xFFFF;
			} else {
				int g = 58 - k * 6;

				if (g < 4)
					g = 4;
				color = (u16)g << 5;
			}
			matrix_draw_char(fb, rr, i, m_chr[rr][i], color);
		}
	}

	for (r = 0; r < MATRIX_ROWS; r++)
		for (c = 0; c < MATRIX_COLS; c++) {
			u8 s = m_sticky[r][c];
			int g;

			if (!s)
				continue;
			g = ((int)s * 60) / 255 + 3;
			if (g > 63)
				g = 63;
			matrix_draw_char(fb, r, c, m_sticky_chr[r][c], (u16)g << 5);
		}

	if (ms >= 500 && ms < 2000)
		msg = "Wake up, Neo...";
	else if (ms >= 3000 && ms < 4600)
		msg = "The Matrix has you...";
	else if (ms >= 5600 && ms < 7500)
		msg = "Follow the white rabbit.";
	if (msg) {
		int ty = LCD_H - 44;

		matrix_text(fb, ty, msg, 0xFFFF, 2);
		if ((t & 3) < 2) {
			int cx = (LCD_W + (int)strlen(msg) * 12) / 2 + 2;
			int ri;

			for (ri = 0; ri < 14; ri++)
				if (cx + 1 < LCD_W)
					fb[(ty + ri) * LCD_W + cx] = fb[(ty + ri) * LCD_W + cx + 1] = 0xFFFF;
		}
	}

	if (scene_ms() - line_at >= 500 || matrix_line[0] == 0) {
		line_at = scene_ms();
		matrix_update_line();
	}
	if (ext_ttl > 0) {
		ext_ttl--;
		strscpy(matrix_line, ext_line, sizeof(matrix_line));
	}
	if (matrix_line[0]) {
		const char *line = matrix_line;
		int total = (int)strlen(line);

		if (total > MATRIX_COLS)
			line += total - MATRIX_COLS;
		matrix_text(fb, LCD_H - 9, line, 0x07E0, 1);
	}
}

static int render_fn(void *data)
{
	int t = 0;

	console_phase = 0;
	bl_pwm_start();

	while (!kthread_should_stop()) {
		if (bl_req >= 0) {
			int lvl = bl_req;

			bl_req = -1;
			bl_set_level(lvl);
		}
		if (warm_req >= 0 || dig_req >= 0) {
			if (warm_req >= 0) { warm_level = warm_req; warm_req = -1; }
			if (dig_req >= 0) { dig_level = dig_req; dig_req = -1; }
			dig_build();
			prev_invalidate();
			fb_dirty = 1;
		}
		if (lcd_rot_pending) {
			lcd_rot_pending = 0;
			bus_begin();
			lcd_cmd(0x36);
			lcd_dat(madctl());
			bus_end();
			prev_invalidate();
			fb_dirty = 1;
		}
		if (panel_reinit_pending) {
			panel_reinit_pending = 0;
			bus_begin();
			lcd_hw_reset();
			lcd_init_panel();
			bus_end();
			prev_invalidate();
			fb_dirty = 1;
		}
		while (pcmd_tail != pcmd_head) {
			u32 pc = pcmd_q[pcmd_tail];
			u8 c = (pc >> 16) & 0xFF, dt = (pc >> 8) & 0xFF, n = pc & 0xFF;

			bus_begin();
			lcd_cmd(c);
			if (n)
				lcd_dat(dt);
			bus_end();
			pcmd_tail = (pcmd_tail + 1) & 15;
		}
		if (splash_active) {
			int mtx = (current_scene == 0 && console_phase != 0);

			if (mtx)
				scene_matrix(t++);
			else
				scene_banner();
			lcd_flush_fb();
			msleep_interruptible(mtx ? 25 : 40);
			if (kthread_should_stop())
				break;
		} else if (fb_dirty && !fb_writing) {
			console_phase = 2;
			fb_dirty = 0;
			lcd_flush_fb();
		} else {
			static int repaint_tick;

			if (++repaint_tick >= 12000) {
				repaint_tick = 0;
				prev_invalidate();
				fb_dirty = 1;
			}
			msleep_interruptible(50);
		}
	}
	return 0;
}


static void touch_apply(void)
{
	int rx = touch_raw_x, ry = touch_raw_y, x, y, t;
	int x0 = tcal[0], x1 = tcal[1], y0 = tcal[2], y1 = tcal[3];

	if (tswap) {
		t = rx; rx = ry; ry = t;
	}
	if (x1 == x0) x1 = x0 + 1;
	if (y1 == y0) y1 = y0 + 1;
	x = (rx - x0) * LCD_W / (x1 - x0);
	y = (ry - y0) * LCD_H / (y1 - y0);
	if (tinvx) x = LCD_W - 1 - x;
	if (tinvy) y = LCD_H - 1 - y;
	if (lcd_rot) {
		x = LCD_W - 1 - x;
		y = LCD_H - 1 - y;
	}
	if (x < 0) x = 0;
	if (x >= LCD_W) x = LCD_W - 1;
	if (y < 0) y = 0;
	if (y >= LCD_H) y = LCD_H - 1;
	if (fill_active) {
		x = x * lg_w / LCD_W;
		y = y * lg_h / LCD_H;
	} else {
		x -= lg_ox;
		y -= lg_oy;
	}
	if (x < 0) x = 0;
	if (x >= lg_w) x = lg_w - 1;
	if (y < 0) y = 0;
	if (y >= lg_h) y = lg_h - 1;
	touch_x = x;
	touch_y = y;
	touch_pressed = touch_raw_pressed;
}

static void touch_event(struct input_handle *handle, unsigned int type,
			unsigned int code, int value)
{
	switch (type) {
	case EV_ABS:
		if (code == ABS_X)
			touch_raw_x = value;
		else if (code == ABS_Y)
			touch_raw_y = value;
		break;
	case EV_KEY:
		if (code == BTN_TOUCH)
			touch_raw_pressed = !!value;
		break;
	case EV_SYN:
		if (code == SYN_REPORT) {
			touch_events++;
			touch_apply();
		}
		break;
	}
}

static bool touch_match(struct input_handler *handler, struct input_dev *dev)
{
	return dev->name && strstr(dev->name, "SX86");
}

static int touch_connect(struct input_handler *handler, struct input_dev *dev,
			 const struct input_device_id *id)
{
	struct input_handle *handle;
	int err;

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;
	handle->dev = dev;
	handle->handler = handler;
	handle->name = "almondplus-lcd";
	err = input_register_handle(handle);
	if (err)
		goto err_free;
	err = input_open_device(handle);
	if (err)
		goto err_unregister;
	if (dev->dev.parent) {
		struct i2c_client *cl = to_i2c_client(dev->dev.parent);

		if (cl && cl->irq > 0)
			touch_irq = cl->irq;
	}
	pr_info("touch source: %s irq %d\n", dev->name, touch_irq);
	return 0;

err_unregister:
	input_unregister_handle(handle);
err_free:
	kfree(handle);
	return err;
}

static void touch_disconnect(struct input_handle *handle)
{
	touch_irq = -1;
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id touch_ids[] = {
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_ABSBIT,
		.evbit = { BIT_MASK(EV_ABS) },
		.absbit = { [BIT_WORD(ABS_X)] = BIT_MASK(ABS_X) },
	},
	{ },
};

static struct input_handler touch_handler = {
	.event = touch_event,
	.match = touch_match,
	.connect = touch_connect,
	.disconnect = touch_disconnect,
	.name = "almondplus-lcd",
	.id_table = touch_ids,
};


static void lg_build_maps(void)
{
	int i;

	for (i = 0; i < LCD_W; i++)
		sx_map[i] = (u16)((i * lg_w) / LCD_W);
	for (i = 0; i < LCD_H; i++)
		sy_map[i] = (u16)((i * lg_h) / LCD_H);
}

static void lg_blit(void)
{
	int r, c;
	const u16 *src16 = (const u16 *)ufb;
	u16 *dst;

	if (fill_active) {
		for (r = 0; r < LCD_H; r++) {
			const u16 *srow = src16 + sy_map[r] * lg_w;

			dst = framebuffer + r * LCD_W;
			for (c = 0; c < LCD_W; c++)
				dst[c] = srow[sx_map[c]];
		}
		return;
	}

	dst = framebuffer + lg_oy * LCD_W + lg_ox;
	for (r = 0; r < lg_h; r++) {
		memcpy(dst, (const u8 *)src16 + r * lg_w * 2, lg_w * 2);
		dst += LCD_W;
	}
}

static ssize_t lcd_fb_write(struct file *f, const char __user *buf,
			    size_t cnt, loff_t *p)
{
	loff_t pos = *p;
	u8 *target = (lg_w == LCD_W && lg_h == LCD_H) ? (u8 *)framebuffer : ufb;

	splash_active = 0;
	console_phase = 2;

	if (pos >= lg_size)
		return 0;
	if (pos + cnt > lg_size)
		cnt = lg_size - pos;

	if (pos == 0) {
		fb_writing = 1;
		fb_writer = f;
	}
	if (mutex_lock_interruptible(&fb_lock)) {
		fb_writing = 0;
		fb_writer = NULL;
		return -ERESTARTSYS;
	}
	if (copy_from_user(target + pos, buf, cnt)) {
		mutex_unlock(&fb_lock);
		fb_writing = 0;
		fb_writer = NULL;
		return -EFAULT;
	}
	mutex_unlock(&fb_lock);
	*p = pos + cnt;

	if (pos + cnt >= lg_size) {
		int wait = 0;

		while (flush_busy && wait++ < 200)
			msleep_interruptible(2);
		if (mutex_lock_interruptible(&fb_lock)) {
			fb_writing = 0;
			fb_writer = NULL;
			return -ERESTARTSYS;
		}
		if (target == ufb)
			lg_blit();
		memcpy(flush_snap, framebuffer, FB_SIZE);
		mutex_unlock(&fb_lock);
		if (flush_busy)
			prev_invalidate();
		snap_ready = true;
		fb_writing = 0;
		fb_writer = NULL;
		fb_dirty = 1;
	}
	return cnt;
}

static int lg_set(int w, int h)
{
	if (w < 16 || h < 16 || w > LCD_W || h > LCD_H)
		return -EINVAL;
	mutex_lock(&fb_lock);
	lg_w = w;
	lg_h = h;
	fill_active = fill && (w != LCD_W || h != LCD_H);
	if (fill_active) {
		lg_ox = 0;
		lg_oy = 0;
		lg_build_maps();
	} else {
		lg_ox = (LCD_W - w) / 2;
		lg_oy = (LCD_H - h) / 2;
	}
	lg_size = (size_t)w * h * 2;
	memset(framebuffer, 0, FB_SIZE);
	mutex_unlock(&fb_lock);
	prev_invalidate();
	fb_dirty = 1;
	pr_info("logical frame %dx%d at %d,%d fill=%d\n", w, h, lg_ox, lg_oy, fill_active);
	return 0;
}

static long lcd_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	switch (cmd) {
	case 0:
		splash_active = 0;
		console_phase = 2;
		fb_dirty = 1;
		return 0;
	case 1: {
		int data[3] = { touch_x, touch_y, touch_pressed };

		if (copy_to_user((void __user *)arg, data, sizeof(data)))
			return -EFAULT;
		return 0;
	}
	case 4:
		if (arg == 2) {
			fb_dirty = 1;
			return 0;
		}
		bl_req = arg ? BL_MAX : 0;
		return 0;
	case 5:
		if (arg == 100) {
			splash_active = 0;
			console_phase = 2;
		} else {
			current_scene = (arg == 0) ? 0 : 1;
			matrix_init = 0;
			splash_active = 1;
		}
		return 0;
	case 7: {
		char ver[64];
		int len = snprintf(ver, sizeof(ver), "%s", LCD_DRV_BUILD);

		if (copy_to_user((void __user *)arg, ver, len + 1))
			return -EFAULT;
		return 0;
	}
	case 16: {
		int lvl = (int)arg;

		if (lvl < 0) lvl = 0;
		if (lvl > BL_MAX) lvl = BL_MAX;
		bl_req = lvl;
		return 0;
	}
	case 17: {
		int lvl[2] = { bl_level, dig_level };

		if (copy_to_user((void __user *)arg, lvl, sizeof(lvl)))
			return -EFAULT;
		return 0;
	}
	case 18: {
		int d[3] = { stat_rows, stat_us, stat_frames };

		if (copy_to_user((void __user *)arg, d, sizeof(d)))
			return -EFAULT;
		return 0;
	}
	case 19: {
		int lvl = (int)arg;

		if (lvl < 0) lvl = 0;
		if (lvl > BL_MAX) lvl = BL_MAX;
		dig_req = lvl;
		fb_dirty = 1;
		return 0;
	}
	case 20: {
		int d[4] = { touch_raw_x, touch_raw_y, touch_raw_pressed, touch_events };

		if (copy_to_user((void __user *)arg, d, sizeof(d)))
			return -EFAULT;
		return 0;
	}
	case 22:
		lcd_rot = arg ? 1 : 0;
		lcd_rot_pending = 1;
		return 0;
	case 23:
		if (mutex_lock_interruptible(&fb_lock))
			return -ERESTARTSYS;
		if (((pcmd_head + 1) & 15) == pcmd_tail) {
			mutex_unlock(&fb_lock);
			return -EBUSY;
		}
		pcmd_q[pcmd_head] = (u32)arg;
		pcmd_head = (pcmd_head + 1) & 15;
		mutex_unlock(&fb_lock);
		return 0;
	case 24:
		return 0;
	case 25: {
		int d[4] = { 0, 0, 0, 0 };

		if (copy_to_user((void __user *)arg, d, sizeof(d)))
			return -EFAULT;
		return 0;
	}
	case 26:
		panel_reinit_pending = 1;
		return 0;
	case 27: {
		int w = (int)arg;

		if (w < 0) w = 0;
		if (w > 100) w = 100;
		warm_req = w;
		fb_dirty = 1;
		return 0;
	}
	case 30: {
		int iters = (int)arg, k, p, total_us;
		ktime_t t0;

		if (iters < 1) iters = 1;
		if (iters > 200) iters = 200;
		fb_writing = 1;
		t0 = ktime_get();
		for (k = 0; k < iters; k++) {
			mutex_lock(&fb_lock);
			for (p = 0; p < LCD_W * LCD_H; p++)
				framebuffer[p] = (u16)(p + k * 7);
			mutex_unlock(&fb_lock);
			snap_ready = false;
			prev_invalidate();
			lcd_flush_fb();
		}
		total_us = (int)ktime_to_us(ktime_sub(ktime_get(), t0));
		fb_writing = 0;
		fb_dirty = 1;
		return total_us;
	}
	case 32: {
		char buf[128];

		if (copy_from_user(buf, (void __user *)arg, sizeof(buf)))
			return -EFAULT;
		buf[sizeof(buf) - 1] = 0;
		strscpy(ext_line, buf, sizeof(ext_line));
		ext_ttl = 40;
		return 0;
	}
	case 33:
		return lg_set((int)(arg >> 16) & 0xFFFF, (int)arg & 0xFFFF);
	case 34:
		return (LCD_W << 16) | LCD_H;
	case 35:
		return (lg_w << 16) | lg_h;
	case 36: {
		u8 buf[18];
		int n, w;

		if (copy_from_user(buf, (void __user *)arg, 2))
			return -EFAULT;
		n = buf[1];
		if (n < 1 || n > 16)
			return -EINVAL;
		fb_writing = 1;
		for (w = 0; w < 200 && flush_busy; w++)
			msleep(1);
		bus_begin();
		lcd_read_regs(buf[0], buf + 2, n);
		bus_end();
		fb_writing = 0;
		if (copy_to_user((void __user *)arg, buf, 2 + n))
			return -EFAULT;
		return 0;
	}
	}
	return -ENOTTY;
}

static int lcd_mmap(struct file *f, struct vm_area_struct *vma)
{
	unsigned long size = vma->vm_end - vma->vm_start;
	int i;

	if (size > (unsigned long)fb_npages * PAGE_SIZE)
		return -EINVAL;
	for (i = 0; i < fb_npages && (unsigned long)i * PAGE_SIZE < size; i++)
		if (vm_insert_page(vma, vma->vm_start + i * PAGE_SIZE, fb_pages[i]))
			return -EAGAIN;
	return 0;
}

static int lcd_release(struct inode *inode, struct file *f)
{
	if (f == fb_writer) {
		fb_writing = 0;
		fb_writer = NULL;
	}
	return 0;
}

static const struct file_operations lcd_fops = {
	.owner = THIS_MODULE,
	.write = lcd_fb_write,
	.llseek = default_llseek,
	.unlocked_ioctl = lcd_ioctl,
	.release = lcd_release,
	.mmap = lcd_mmap,
};

static struct miscdevice lcd_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = DEVICE_NAME,
	.fops = &lcd_fops,
	.mode = 0666,
};

static long panel_init_on_cpu(void *unused)
{
	bus_begin();
	lcd_gpio_init();
	lcd_hw_reset();
	lcd_init_panel();
	bus_end();
	return 0;
}

static int __init lcd_drv_init(void)
{
	int ret, i;

	gpio_base = ioremap(GPIO4_PHYS, 0x20);
	mux_reg = ioremap(MUX4_PHYS, 4);
	if (!gpio_base || !mux_reg) {
		ret = -ENOMEM;
		goto err_unmap;
	}

	fb_npages = (FB_SIZE + PAGE_SIZE - 1) / PAGE_SIZE;
	fb_pages = kmalloc_array(fb_npages, sizeof(struct page *), GFP_KERNEL);
	framebuffer = vzalloc((size_t)fb_npages * PAGE_SIZE);
	flush_snap = vzalloc(FB_SIZE);
	prev_snap = vzalloc(FB_SIZE);
	ufb = vzalloc(FB_SIZE);
	if (!fb_pages || !framebuffer || !flush_snap || !prev_snap || !ufb) {
		ret = -ENOMEM;
		goto err_free;
	}
	for (i = 0; i < fb_npages; i++)
		fb_pages[i] = vmalloc_to_page((u8 *)framebuffer + i * PAGE_SIZE);
	prev_invalidate();

	dig_build();
	bl_bit = BIT_BL;

	ret = misc_register(&lcd_dev);
	if (ret)
		goto err_free;

	if (stage & 1) {
		ret = input_register_handler(&touch_handler);
		if (ret)
			pr_warn("touch handler not registered (%d)\n", ret);
	}

	if (stage & 4)
		work_on_cpu(0, panel_init_on_cpu, NULL);

	splash_active = splash ? 1 : 0;
	if (!splash_active)
		fb_dirty = 0;

	if (stage & 2) {
		render_thread = kthread_create(render_fn, NULL, "lcd_render");
		if (IS_ERR(render_thread)) {
			ret = PTR_ERR(render_thread);
			render_thread = NULL;
			goto err_dereg;
		}
		if (rcpu >= 0)
			kthread_bind(render_thread, rcpu);
		wake_up_process(render_thread);
	}

	pr_info("%s: panel %dx%d ready\n", LCD_DRV_BUILD, LCD_W, LCD_H);
	return 0;

err_dereg:
	if (stage & 1)
		input_unregister_handler(&touch_handler);
	misc_deregister(&lcd_dev);
err_free:
	vfree(ufb);
	vfree(prev_snap);
	vfree(flush_snap);
	vfree(framebuffer);
	kfree(fb_pages);
err_unmap:
	if (mux_reg)
		iounmap(mux_reg);
	if (gpio_base)
		iounmap(gpio_base);
	return ret;
}

static void __exit lcd_drv_exit(void)
{
	if (render_thread)
		kthread_stop(render_thread);
	if (bl_timer_on)
		hrtimer_cancel(&bl_timer);
	if (stage & 1)
		input_unregister_handler(&touch_handler);
	misc_deregister(&lcd_dev);
	vfree(ufb);
	vfree(prev_snap);
	vfree(flush_snap);
	vfree(framebuffer);
	kfree(fb_pages);
	iounmap(mux_reg);
	iounmap(gpio_base);
	pr_info("%s: stopped\n", LCD_DRV_BUILD);
}

module_init(lcd_drv_init);
module_exit(lcd_drv_exit);
MODULE_VERSION(LCD_DRV_BUILD);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ILI9486 LCD and SX8650 touch relay for Securifi Almond+");
