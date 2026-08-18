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
#include <linux/leds.h>
#include <linux/kmsg_dump.h>
#include <linux/hrtimer.h>
#include <linux/mutex.h>
#include <linux/reboot.h>
#include <linux/pm.h>


#define DEVICE_NAME  "lcd"
/* Версия драйвера - дата сборки, её подставляет пакетный Makefile. */
#ifndef LCD_DRV_BUILD
#define LCD_DRV_BUILD "unknown"
#endif
#define LCD_W        320
#define LCD_H        240

#define TOUCH_SCALE_X 341
#define TOUCH_OFF_X   12
#define TOUCH_SCALE_Y 265
#define TOUCH_OFF_Y   14
#define FB_SIZE      (LCD_W * LCD_H * 2)  /* RGB565 */

#define PALMBUS_BASE 0x1E000000
#define GPIOMODE_OFF 0x060
#define GPIO_DATA_OFF 0x600
#define GPIO_DIR_OFF  0x620
/*
 * У MT7621 рядом с регистром данных лежат его атомарные близнецы: запись бита
 * в DSET поднимает соответствующую линию, в DCLR - опускает, остальные не
 * трогает. Для подсветки это единственный безопасный путь: регистр 0x620 - он
 * же шина дисплея, и полная его перезапись из таймера ШИМ вклинивалась между
 * тактами передачи пикселей, гоняя на панель мусор (цветные полосы).
 */
#define GPIO_DSET_OFF 0x630
#define GPIO_DCLR_OFF 0x640

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
static struct file *fb_writer;  /* чей write() взвёл fb_writing */
static int splash_active = 1; /* demoscene animation until userspace takes over */
static int console_phase = 0; /* 0=splash (идёт загрузка), 2=userspace взял экран */

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
/*
 * Бит подсветки живёт ОТДЕЛЬНО от shadow_dir. Иначе шина дисплея и ШИМ
 * подсветки дерутся за одну переменную: поток отрисовки читает-меняет-пишет
 * shadow_dir по 150 тысяч раз на кадр, а таймер ШИМ вклинивается между чтением
 * и записью - и либо гасит подсветку не вовремя, либо портит биты данных.
 * Теперь каждая сторона владеет своей половиной регистра.
 */
static u32 bl_bit;

static inline void gw_dir(u32 lcd_bits) {
    gw(GPIO_DIR_OFF, base_dir | (lcd_bits & LCD_PIN_MASK & ~BIT_BL) | bl_bit);
}

/*
 * ЯРКОСТЬ ПОДСВЕТКИ ПРОГРАММНЫМ ШИМ.
 *
 * У MT7621 нет аппаратного PWM на этом пине: подсветка висит на GPIO 31 и
 * умеет только «включено/выключено». Стоковая прошивка яркость и не меняла -
 * её «BackLight Settings» задаёт лишь часы, когда подсветка горит (строки
 * BackLight_settings в /almond/en.xml, ioctl 14 у almond_backlight - это
 * таймаут, а не уровень).
 *
 * Поэтому крутим пин сами: hrtimer с периодом BL_PERIOD_NS переключает его
 * между «горит» и «погас» в пропорции level/BL_MAX. На краях (0 и максимум)
 * таймер не нужен - там просто статический уровень, и это же состояние,
 * которое видит класс светодиодов.
 *
 * Частота выбрана 250 Гц: на глаз мерцания нет, а нагрузка мизерная - один
 * записанный регистр на прерывание.
 */
#define BL_MAX        255
#define BL_PERIOD_NS  4000000L   /* 4 мс = 250 Гц. Проверено глазами на
                                  * живом драйвере: на 1 кГц окно света при
                                  * 10% яркости - 100 мкс, и его рвёт любая
                                  * передача кадра; на 250 Гц окно вчетверо
                                  * длиннее и мигание уходит. */
static long bl_period_ns = BL_PERIOD_NS;  /* можно менять на ходу: ioctl 24 */

/*
 * Во время кадра ШИМ крутит сам цикл отрисовки. Прерывание таймера посреди
 * битбанга сдвигает такты шины (панель ловит мусор), а вот переключить линию
 * МЕЖДУ двумя пикселями безопасно - шина в этот момент простаивает.
 *
 * Пиксель уходит на панель за ~0.8 мкс, поэтому сверка фазы каждые 8 пикселей
 * даёт шаг около 6 мкс - этого хватает, чтобы на время передачи поднять
 * частоту до 4 кГц. Смысл: панель обновляется постепенно, и каждый проблеск
 * подсветки показывает её в новой стадии - на 1 кГц таких снимков за кадр
 * набирается десяток, и они видны как мерцание. На 4 кГц протяжка смазывается.
 * Скважность при этом та же, что и в покое, так что яркость не скачет.
 * Раньше на время кадра подсветка просто замирала, и каждая перерисовка давала
 * заметный проблеск или просадку - именно это и было видно на заставке.
 */
#define BL_SLOT_PIXELS 2        /* сверка фазы каждые ~15 мкс передачи:
                                 * при коротком окне света сетка в 60 мкс
                                 * давала дрожание яркости на каждой
                                 * перерисовке */
/* Раньше на время передачи подсветка крутилась на 4 кГц, а в покое - на
 * частоте bl_period_ns. На малой яркости короткий импульс теряется в
 * дрожании таймера, и перерисовка была видна как моргок. Теперь обе фазы
 * идут на одной частоте. */

static volatile bool bl_bus_busy;   /* идёт передача кадра на панель */
/* Замер провалов: самый долгий тёмный промежуток и число растянутых фаз.
 * Тёмная фаза обязана длиться period - on_ns; всё, что дольше этого плюс
 * 400 мкс на дрожание таймера, глаз и видит как мерцание. */
static u64 bl_off_since;
static u32 bl_max_off_us;
static u32 bl_long_off;
/* Зеркальный замер по светлой фазе: затянувшийся свет виден как ЯРКАЯ
 * вспышка, и на малой яркости она заметнее любого провала - окно света там
 * всего сотни микросекунд. */
static u64 bl_on_since;
static u32 bl_max_on_us;
static u32 bl_long_on;
static volatile bool snap_ready;    /* снимок кадра уже готов (сделан writer'ом) */
static volatile bool flush_busy;    /* снимок прямо сейчас уезжает на панель */
static struct hrtimer bl_timer;
static int  bl_level = BL_MAX;   /* текущая яркость */
static bool bl_timer_on;
static bool bl_phase_on;         /* сейчас горит */
static u32  bl_on_ns;            /* сколько наносекунд периода подсветка горит */

static inline void bl_pin(bool on)
{
    if (!on && bl_on_since) {
        u64 d = ktime_get_ns() - bl_on_since;
        u32 us;
        do_div(d, 1000);
        us = (u32)d;
        if (us > bl_max_on_us) bl_max_on_us = us;
        if (us > bl_on_ns / 1000 + 400) bl_long_on++;
        bl_on_since = 0;
    } else if (on) {
        bl_on_since = ktime_get_ns();
    }

    if (!on) {
        bl_off_since = ktime_get_ns();
    } else if (bl_off_since) {
        u64 d = ktime_get_ns() - bl_off_since;
        u32 us;
        do_div(d, 1000);       /* на 32-битном MIPS деления u64 нет */
        us = (u32)d;
        if (us > bl_max_off_us) bl_max_off_us = us;
        /* Тёмная фаза длится period - on_ns; сверять надо с ней, а не с
         * длительностью света, иначе под условие попадает каждая фаза. */
        if (us > ((u32)bl_period_ns - bl_on_ns) / 1000 + 400) bl_long_off++;
        bl_off_since = 0;
    }
    bl_bit = on ? BIT_BL : 0;
    gw(on ? GPIO_DSET_OFF : GPIO_DCLR_OFF, BIT_BL);
}

/* Фаза ШИМ по абсолютным часам. Нужна на границах передачи кадра: внутри
 * цикла вывода фазу ведёт накопитель, а в покое - таймер по часам. Раньше
 * накопитель начинался с нуля на каждом кадре, то есть перерисовка всегда
 * открывала свежее окно света независимо от того, где фаза была на самом
 * деле. На малой яркости это лишнее окно занимает заметную долю периода, и
 * заставка мигала ровно столько раз в секунду, сколько перерисовывалась. */
static u32 bl_phase_now(void)
{
    u64 now = ktime_get_ns();
    return do_div(now, (u32)bl_period_ns);
}

static void bl_resync(void)
{
    bool on;
    if (bl_level == 0 || bl_level == BL_MAX) return;
    on = bl_phase_now() < bl_on_ns;
    if (on != bl_phase_on) {
        bl_phase_on = on;
        bl_pin(on);
    }
}

static enum hrtimer_restart bl_tick(struct hrtimer *t)
{
    u64 now;
    u32 ph, on_ns, next;
    bool on;

    /* Пока идёт передача кадра - не дёргаемся: прерывание посреди битбанга
     * рвёт такты шины. Там подсветку крутит сам вывод, по тем же часам. */
    if (bl_bus_busy) {
        /* Отсрочку пробовали укоротить до 200 мкс - в расчёте, что таймер
         * подхватит короткое окно света, если его проскочит цикл вывода.
         * Замер показал обратное: на 9% яркости самый долгий провал вырос с
         * 3987 до 7785 мкс, на ночном минимуме до 7901. Причина в том, что
         * во время передачи ШИМ ведёт сам цикл, а лишние прерывания его
         * притормаживают - и он проскакивает окно, которое должен был
         * открыть. Миллисекунда здесь лучше. */
        hrtimer_forward_now(t, ns_to_ktime(1000000L));
        return HRTIMER_RESTART;
    }

    /* Фазу считаем ОТ ЧАСОВ, а не от прошлого срабатывания. Таймер на
     * загруженном процессоре опаздывает, и при отсчёте от себя опоздание
     * добавлялось к текущей фазе: попав на тёмную, она растягивалась, и
     * обновление данных на экране было видно как провал яркости. При счёте
     * от часов опоздание исправляется само на следующем же срабатывании. */
    now = ktime_get_ns();
    ph = do_div(now, (u32)bl_period_ns);
    on_ns = (u32)(bl_period_ns / BL_MAX) * bl_level;
    on = ph < on_ns;

    if (on != bl_phase_on) {
        bl_phase_on = on;
        bl_pin(on);
    }

    /* Просыпаемся ровно к следующей границе фазы. */
    next = on ? (on_ns - ph) : ((u32)bl_period_ns - ph);
    if (next < 20000) next = 20000;   /* не чаще 50 кГц, иначе задавим систему */
    hrtimer_forward_now(t, ns_to_ktime((u64)next));
    return HRTIMER_RESTART;
}

static void bl_set_level(int level)
{
    if (level < 0) level = 0;
    if (level > BL_MAX) level = BL_MAX;
    bl_level = level;

    if (level == 0 || level == BL_MAX) {
        if (bl_timer_on) {
            hrtimer_cancel(&bl_timer);
            bl_timer_on = false;
        }
        bl_pin(level == BL_MAX);
        return;
    }

    if (!bl_timer_on) {
        bl_phase_on = true;
        bl_pin(true);
        bl_timer_on = true;
        hrtimer_start(&bl_timer,
                      ns_to_ktime((long)BL_PERIOD_NS * bl_level / BL_MAX),
                      HRTIMER_MODE_REL);
    }
}

/* Быстрая шина: данные и опускание строба уходят ОДНОЙ записью в DIR вместо
 * трёх (так делал и заводской драйвер). Меняется на живую:
 *   echo 0 > /sys/module/almond3s_lcd/parameters/fast_bus   - вернуть старый путь
 * Сравнить скорость: ioctl 18 отдаёт мкс на кадр. */
static int fast_bus = 1;
module_param(fast_bus, int, 0644);
MODULE_PARM_DESC(fast_bus, "1 = данные+строб одной записью (быстрее), 0 = старый путь");

/* Те же биты, что кладёт gpio_set_byte, но БЕЗ записи в регистр. */
static inline u32 byte_bits(u8 val)
{
    u32 d = shadow_dir & ~(BIT_D0|BIT_D1|BIT_D2|BIT_D3|BIT_D4|BIT_D5|BIT_D6|BIT_D7);
    if (val & 0x01) d |= BIT_D0;
    if (val & 0x02) d |= BIT_D1;
    if (val & 0x04) d |= BIT_D2;
    if (val & 0x08) d |= BIT_D3;
    if (val & 0x10) d |= BIT_D4;
    if (val & 0x20) d |= BIT_D5;
    if (val & 0x40) d |= BIT_D6;
    if (val & 0x80) d |= BIT_D7;
    return d;
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

/* 12-битный цвет (COLMOD 0x53): 3 байта на ДВА пикселя вместо 4 - на четверть
 * меньше тактов шины. Цветов 4096 вместо 65536. Переключается на живую:
 *   echo 1 > /sys/module/almond3s_lcd/parameters/color12 */
/* Обновление через строку: за раз уезжают только чётные либо только
 * нечётные строки, поэтому байтов по шине вдвое меньше и частота обновления
 * почти вдвое выше. Цена - гребёнка на быстром движении, поэтому по
 * умолчанию выключено:
 *   echo 1 > /sys/module/almond3s_lcd/parameters/interlace */
static int interlace;
module_param(interlace, int, 0644);
MODULE_PARM_DESC(interlace, "1 = обновлять через строку (быстрее, но гребёнка)");
static int il_field;

static int color12;
module_param(color12, int, 0644);
MODULE_PARM_DESC(color12, "1 = 12-битный цвет (быстрее на ~25%), 0 = 16-битный");
static int color12_applied = -1;

static inline void lcd_write_8d(u8 val)
{
    if (fast_bus) {
        u32 d = byte_bits(val);
        gw_dir(d & ~BIT_DCX);
        shadow_dir = d | BIT_DCX;
        gw_dir(shadow_dir);
        return;
    }
    gpio_set_byte(val);
    shadow_dir &= ~BIT_DCX; gw_dir(shadow_dir);
    shadow_dir |= BIT_DCX;  gw_dir(shadow_dir);
}

/* Два пикселя RGB565 -> три байта RGB444, как ждёт панель в режиме 0x53. */
static inline void lcd_write_pair12(u16 a, u16 b)
{
    lcd_write_8d((u8)((((a >> 12) & 0xF) << 4) | ((a >> 7) & 0xF)));
    lcd_write_8d((u8)((((a >> 1)  & 0xF) << 4) | ((b >> 12) & 0xF)));
    lcd_write_8d((u8)((((b >> 7)  & 0xF) << 4) | ((b >> 1)  & 0xF)));
}

static void lcd_write_16d(u16 val)
{
    if (fast_bus) {
        /* На байт: «данные + строб вниз» одной записью, затем фронт вверх -
         * панель защёлкивает по нему, данные к этому моменту уже стоят. */
        u32 d = byte_bits(val >> 8);
        gw_dir(d & ~BIT_DCX);
        gw_dir(d | BIT_DCX);
        d = byte_bits(val & 0xFF);
        gw_dir(d & ~BIT_DCX);
        shadow_dir = d | BIT_DCX;
        gw_dir(shadow_dir);
        return;
    }
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

static int lcd_rot;         /* 1 = экран перевёрнут на 180 */
static int lcd_rot_pending;
static int panel_reinit_pending; /* полный reset+init панели из потока отрисовки */
static int panel_init_alt;       /* 1 = таблица из заводского ядра, 0 = из загрузчика */

/*
 * Очередь сырых команд панели (ioctl 23). Раньше ioctl слал команду сразу,
 * из своего контекста - и она могла врезаться в передачу кадра потоком
 * отрисовки: контроллер панели глотал байты кадра как команды. Живой случай
 * 16.08: три экземпляра UI на старте наперегонки слали inv/гамму/CABC -
 * панель ушла в ровный белый до полного ре-инита. Теперь ioctl только
 * ставит в очередь, а исполняет её поток отрисовки между кадрами.
 * Один писатель (ioctl под fb_lock), один читатель (поток) - индексов int
 * достаточно.
 */
static u32 pcmd_q[16];
static int pcmd_head, pcmd_tail;

/*
 * У завода ДВЕ инициализации этой панели: загрузчик (на ней сток и работал -
 * ядро панель при буте не переинициализировало) и таблица за ioctl 0 в
 * заводском ядре - другая гамма, VCOM и питание. Держим обе: панели одной
 * модели различаются партиями, и вторая калибровка может оказаться честнее.
 * MADCTL в обеих шлём свой - поворот наш, а не заводской.
 */
static void lcd_init_ili9341(void)
{
    if (panel_init_alt) {
        lcd_cmd(0xCF); lcd_dat(0x00); lcd_dat(0x83); lcd_dat(0x30);
        lcd_cmd(0xED); lcd_dat(0x64); lcd_dat(0x03); lcd_dat(0x12); lcd_dat(0x81);
        lcd_cmd(0xE8); lcd_dat(0x85); lcd_dat(0x01); lcd_dat(0x79);
        lcd_cmd(0xCB); lcd_dat(0x39); lcd_dat(0x2C); lcd_dat(0x00); lcd_dat(0x34); lcd_dat(0x02);
        lcd_cmd(0xF7); lcd_dat(0x20);
        lcd_cmd(0xEA); lcd_dat(0x00); lcd_dat(0x00);
        lcd_cmd(0xC0); lcd_dat(0x26);
        lcd_cmd(0xC1); lcd_dat(0x11);
        lcd_cmd(0xC5); lcd_dat(0x35); lcd_dat(0x3E);
        lcd_cmd(0xC7); lcd_dat(0xBE);
        lcd_cmd(0x36); lcd_dat(lcd_rot ? 0x68 : 0xA8);
        lcd_cmd(0x3A); lcd_dat(0x55);
        lcd_cmd(0xB1); lcd_dat(0x00); lcd_dat(0x1B);
        lcd_cmd(0xB7); lcd_dat(0x07);
        /* Второй байт B6 несёт бит SS (направление развёртки истоков).
         * Заводское ядро слало 0x82 и компенсировало это MADCTL=0xE8; у нас
         * MADCTL свой, поэтому и здесь оставляем свой 0xA2 - иначе картинка
         * зеркалится, как будто смотришь с обратной стороны стекла. */
        lcd_cmd(0xB6); lcd_dat(0x0A); lcd_dat(0xA2); lcd_dat(0x27); lcd_dat(0x00);
        lcd_cmd(0xF2); lcd_dat(0x08);
        lcd_cmd(0x26); lcd_dat(0x01);
        lcd_cmd(0xE0);
        lcd_dat(0x1F); lcd_dat(0x1A); lcd_dat(0x18); lcd_dat(0x0A);
        lcd_dat(0x0F); lcd_dat(0x06); lcd_dat(0x45); lcd_dat(0x87);
        lcd_dat(0x32); lcd_dat(0x0A); lcd_dat(0x07); lcd_dat(0x02);
        lcd_dat(0x07); lcd_dat(0x05); lcd_dat(0x00);
        lcd_cmd(0xE1);
        lcd_dat(0x00); lcd_dat(0x25); lcd_dat(0x27); lcd_dat(0x05);
        lcd_dat(0x10); lcd_dat(0x09); lcd_dat(0x3A); lcd_dat(0x78);
        lcd_dat(0x4D); lcd_dat(0x05); lcd_dat(0x18); lcd_dat(0x0D);
        lcd_dat(0x38); lcd_dat(0x3A); lcd_dat(0x1F);
        lcd_cmd(0x11); mdelay(120);
        lcd_cmd(0x29);
        return;
    }
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
    lcd_cmd(0x36); lcd_dat(lcd_rot ? 0x68 : 0xA8);
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

/* Что уже стоит на панели: с этим сравниваем новый кадр, чтобы гнать по шине
 * только изменившиеся строки. Полный кадр - это 76 800 пикселей и ~75 мс, и
 * именно эта протяжка видна как вспышка на приглушённой подсветке. */
/*
 * ЦИФРОВОЕ ЗАТЕМНЕНИЕ - второй способ убавить яркость. Здесь мы не трогаем
 * подсветку вообще (она горит ровно, мерцать нечему), а масштабируем сами
 * пиксели при отправке на панель. Плата известна: подсветка просвечивает
 * панель насквозь, поэтому чёрный фон светлее не становится - тускнеет
 * изображение, а не свет.
 *
 * Считаем через таблицы: RGB565 это 5-6-5 бит, значит достаточно двух
 * таблиц - на 32 и на 64 значения, и пиксель пересобирается парой сдвигов.
 */
static int  dig_level = BL_MAX;      /* 255 - без затемнения */
static u8   digR[32], digG[64], digB[32];
/* Тёплый фильтр 0..100: вечернее наложение. Красный не трогаем совсем,
 * зелёный убавляем слегка, синий заметно - получается тёплый свет, а не
 * жёлтая муть. Идёт по тому же пути, что цифровое затемнение, поэтому
 * они честно перемножаются и работают вместе. */
static int  warm_level;
static int  dig_plain = 1;   /* ни затемнения, ни фильтра - быстрый путь */


static void bl_calc(void)
{
    bl_on_ns = (u32)((u32)bl_period_ns / BL_MAX * bl_level);
}

static void dig_build(void)
{
    int i;
    int gk = 255 - warm_level * 55 / 100;    /* зелёный  до -22% */
    int bk = 255 - warm_level * 135 / 100;   /* синий    до -53% */

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
           ((u16)digG[(p >> 5)  & 0x3F] << 5)  |
            (u16)digB[p & 0x1F];
}

static u16 *prev_snap;
static bool prev_valid;
static int  stat_rows;      /* строк в последнем кадре */
static int  stat_us;        /* сколько он занял, мкс */
static int  stat_frames;    /* кадров всего */

/* Одна пачка строк [r0..r1] целиком: окно по вертикали + запись памяти. */
static void lcd_send_rows(int r0, int r1, int c0, int c1)
{
    const int w = c1 - c0 + 1;
    int i, n = (r1 - r0 + 1) * w;
    int dim = (bl_level > 0 && bl_level < BL_MAX);
    static int slot_pos;
    static int since_yield;
    const u16 *src = flush_snap + r0 * LCD_W + c0;
    int col = 0;

    /* Таймер ШИМ замирает ровно на время передачи: прерывание посреди битбанга
     * рвёт такты шины. Всё остальное время кадра (сравнение строк, установка
     * окна) он обязан работать - иначе подсветка залипает в тёмной фазе на
     * несколько миллисекунд, и это видно как вспышка даже когда на панель не
     * ушло ни одной строки. */
    bl_bus_busy = true;

    lcd_cmd(0x2B);
    lcd_dat(r0 >> 8); lcd_dat(r0 & 0xFF);
    lcd_dat(r1 >> 8); lcd_dat(r1 & 0xFF);
    lcd_write_mem();

    /* Глобалы читаем ОДИН раз: в цикле их 76800 итераций на полный экран, и
     * каждое обращение к памяти там заметно. */
    {
        const int plain = dig_plain;
        const int c12   = (color12_applied == 1);
        u64 last_ns = dim ? ktime_get_ns() : 0;
        u32 phase;

        bl_calc();
        phase = dim ? bl_phase_now() : 0;   /* одно деление на кадр, не 38 тысяч */

        for (i = 0; i < n; i++) {
            if (c12) {
                if ((col & 1) == 0) {
                    u16 a = plain ? src[col]     : dig_pixel(src[col]);
                    u16 b = plain ? src[col + 1] : dig_pixel(src[col + 1]);
                    lcd_write_pair12(a, b);
                }
            } else {
                lcd_write_16d(plain ? src[col] : dig_pixel(src[col]));
            }
            if (++col == w) { col = 0; src += LCD_W; }

            if ((++slot_pos & (BL_SLOT_PIXELS - 1)) != 0)
                continue;

            /* Фазу ведём накопителем: раньше здесь было do_div, то есть 64-битное
             * деление каждые два пикселя (~38 тысяч делений на кадр) - на 32-битном
             * MIPS это дорого. Теперь вычитание, и порог посчитан заранее. */
            if (dim) {
                u64 now = ktime_get_ns();
                bool on;
                phase += (u32)(now - last_ns);
                last_ns = now;
                while (phase >= (u32)bl_period_ns)
                    phase -= (u32)bl_period_ns;
                on = phase < bl_on_ns;
                if (on != bl_phase_on) {
                    bl_phase_on = on;
                    bl_pin(on);
                }
            }

            /* Уступаем процессор реже: 64 пикселя давали 1200 вызовов на кадр.
               И только в ТЁМНОЙ фазе. Раньше было наоборот - уступали, пока
               подсветка горит, - и планировщик забирал процессор ровно на
               открытом окне света. На малой яркости окно длится 392 мкс, а
               пауза бывает миллисекунды: замер на «Матрице» при 10% показал
               свет до 8394 мкс вместо 392 и 97 таких вспышек за полминуты -
               это и было видно как яркое мерцание. В темноте запас 3.6 мс,
               и затянувшаяся пауза даёт лишь чуть позднее следующее окно.
               Но и в темноте уступаем только в её НАЧАЛЕ: если до следующего
               окна света осталось меньше полутора миллисекунд, пауза съест
               его целиком, и вместо вспышки получится провал на несколько
               периодов подряд. */
            if (++since_yield >= 256 &&
                (!dim || (!bl_phase_on &&
                          (u32)bl_period_ns - phase > 1500000u))) {
                since_yield = 0;
                /* На время паузы отдаём подсветку таймеру. Пока цикл стоит в
                   планировщике, шину никто не гонит, а ШИМ иначе замирает: с
                   паузой в десяток миллисекунд подряд пропадало по три окна
                   света. Флаг снимаем ровно на точке уступки, где никакая
                   передача не начата. */
                bl_bus_busy = false;
                cond_resched();
                bl_bus_busy = true;
                if (dim) {
                    last_ns = ktime_get_ns();
                    phase = bl_phase_now();   /* таймер мог сдвинуть фазу */
                    bl_phase_on = phase < bl_on_ns;
                }
            }
        }
    }
#if 0
    for (i = 0; i < n; i++) {
        if (color12_applied == 1) {
            /* Пиксели идут парами; n всегда кратно ширине строки, так что
               пара никогда не разрывается между вызовами. */
            if ((i & 1) == 0) {
                u16 a = dig_plain ? src[i]     : dig_pixel(src[i]);
                u16 b = dig_plain ? src[i + 1] : dig_pixel(src[i + 1]);
                lcd_write_pair12(a, b);
            }
        } else {
            lcd_write_16d(dig_plain ? src[i] : dig_pixel(src[i]));
        }
        if ((++slot_pos & (BL_SLOT_PIXELS - 1)) != 0)
            continue;

        /* Фазу берём ОТ ЧАСОВ, а не от счётчика пикселей: цикл то и дело
         * уступает процессор, и счётчик после этого врёт - подсветка застывала
         * в тёмной фазе на всю паузу, что и оставалось видно как редкий
         * проблеск при переходах по меню. do_div вместо обычного деления - на
         * 32-битном MIPS деления u64 в ядре нет. Сверяем каждые 2 пикселя:
         * реже (bl_fast) давало ползущие волны/мигание на дим - убрано. */
        if (dim) {
            u64 now = ktime_get_ns();
            u32 ph = do_div(now, (u32)bl_period_ns);
            bool on = ph < (u32)bl_period_ns / BL_MAX * bl_level;
            if (on != bl_phase_on) {
                bl_phase_on = on;
                bl_pin(on);
            }
        }

        /* Процессор уступаем ТОЛЬКО в светлой фазе. Пауза планировщика может
         * затянуться на миллисекунды, и если поймать её тёмными - будет
         * провал яркости. Раньше я вместо этого зажигал подсветку перед
         * паузой принудительно, но это давало обратное: лишние вспышки на
         * каждую паузу. Пропущенная возможность уступить не страшна -
         * следующая придёт через 60 микросекунд. */
        if (++since_yield >= 64 && (!dim || !bl_phase_on)) {
            since_yield = 0;
            cond_resched();
        }
    }
#endif
    lcd_cs_deselect();
    bl_bus_busy = false;
    bl_resync();   /* таймер после передачи просыпается с задержкой до 1 мс */
}

static int win_c0, win_c1;   /* окно колонок текущего кадра */

static void lcd_flush_fb(void)
{
    int r, r0;

    /* Снимок берёт тот, кто объявил кадр готовым - конец записи в /dev/lcd.
     * Раньше копия снималась ЗДЕСЬ, и если userspace уже успел очистить
     * фреймбуфер под следующий кадр, на панель уезжал пустой экран: картинка
     * «пропадала и появлялась снова». Свои внутренние кадры (заставка, сцены)
     * драйвер рисует прямо в framebuffer, поэтому для них снимок делаем тут. */
    if (!snap_ready) {
        mutex_lock(&fb_lock);
        memcpy(flush_snap, framebuffer, FB_SIZE);
        mutex_unlock(&fb_lock);
    }
    snap_ready = false;

    /* Refresh non-LCD DIR bits in case other drivers changed them */
    base_dir = gr(GPIO_DIR_OFF) & ~LCD_PIN_MASK;

    flush_busy = true;

    /* Формат пикселя сменили на живую - сообщаем панели и перерисовываем всё:
       прошлый снимок закодирован иначе, построчное сравнение тут не годится. */
    if (color12_applied != color12) {
        lcd_cmd(0x3A);
        lcd_dat(color12 ? 0x53 : 0x55);
        color12_applied = color12;
        prev_valid = false;
    }

    /* Раньше на панель всегда уезжала вся ширина 320px, даже если менялась
     * узкая полоса. Считаем реальные границы изменений по колонкам и сужаем
     * окно: у эмулятора игровое поле 256px в центре, а чёрные полосы с
     * кнопками не меняются вовсе - это сразу минус пятая часть шины. */
    bool snap_partial = false;
    {
        int r, c, lo = LCD_W, hi = -1;
        if (!prev_valid || !prev_snap) {
            lo = 0; hi = LCD_W - 1;
        } else {
            for (r = 0; r < LCD_H; r++) {
                const u16 *a = flush_snap + r * LCD_W;
                const u16 *b = prev_snap  + r * LCD_W;
                if (!memcmp(a, b, LCD_W * sizeof(u16))) continue;
                for (c = 0; c < lo; c++)
                    if (a[c] != b[c]) { if (c < lo) lo = c; break; }
                for (c = LCD_W - 1; c > hi; c--)
                    if (a[c] != b[c]) { if (c > hi) hi = c; break; }
            }
        }
        if (hi < lo) { lo = 0; hi = LCD_W - 1; }   /* изменений нет - не сузить */
        lo &= ~1; hi |= 1;                          /* ширина чётная: 12-битный
                                                       режим шлёт пиксели парами */
        win_c0 = lo; win_c1 = hi;
    }
    lcd_cmd(0x2A);
    lcd_dat(win_c0 >> 8); lcd_dat(win_c0 & 0xFF);
    lcd_dat(win_c1 >> 8); lcd_dat(win_c1 & 0xFF);

    {
        ktime_t t0 = ktime_get();
        stat_rows = 0;

    if (!prev_valid || !prev_snap) {
        lcd_send_rows(0, LCD_H - 1, win_c0, win_c1);
        stat_rows = LCD_H;
    } else if (interlace) {
        /* Строку, которую в этот проход не отправили, НЕ отмечаем в prev_snap:
         * иначе её изменения считались бы доставленными и пропали бы совсем.
         * Поэтому снимок здесь обновляем построчно, а не целиком в конце. */
        for (r = il_field; r < LCD_H; r += 2) {
            if (!memcmp(flush_snap + r * LCD_W, prev_snap + r * LCD_W,
                        LCD_W * sizeof(u16)))
                continue;
            lcd_send_rows(r, r, win_c0, win_c1);
            memcpy(prev_snap + r * LCD_W, flush_snap + r * LCD_W,
                   LCD_W * sizeof(u16));
            stat_rows++;
        }
        il_field ^= 1;
        snap_partial = true;
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
    /* Фазу подсветки в конце кадра НЕ трогаем. Раньше здесь стояло
     * принудительное «зажечь», чтобы панель не осталась тёмной, - и это давало
     * лишний импульс света на каждую перерисовку, тот самый мерцающий проблеск.
     * Ничего страшного не произойдёт: таймер ШИМ всё это время крутится вхолостую
     * и подхватит фазу в ближайшую миллисекунду. */

    if (prev_snap && !snap_partial) {
        memcpy(prev_snap, flush_snap, FB_SIZE);
        prev_valid = true;
    }
    flush_busy = false;
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

/* Пока userspace толкает строку статуса (ioctl 32, живой logread), не
 * перетираем её из kmsg. ttl тикает каждый кадр матрицы (~10/с). */
static int matrix_ext_ttl;

/* Шрифт «матрицы» знает только ASCII (95 знаков), а наши сообщения в логе
 * написаны по-русски: каждая буква кириллицы - два байта вне таблицы, и оба
 * превращались в пробел. Строка выглядела как «5gmodem: » и дальше чернота.
 * Поэтому переводим кириллицу в латиницу, а прочие не-ASCII байты выбрасываем. */
static void translit(const char *src, char *dst, int dstsz)
{
    static const char *TAB[32] = {
        "A","B","V","G","D","E","Zh","Z","I","Y","K","L","M","N","O","P",
        "R","S","T","U","F","H","Ts","Ch","Sh","Sch","","Y","","E","Yu","Ya"
    };
    int o = 0;
    while (*src && o < dstsz - 4) {
        unsigned char c = (unsigned char)*src;
        unsigned cp = 0;
        if (c < 0x80) {                     /* обычный ASCII */
            dst[o++] = (c >= 32) ? (char)c : ' ';
            src++;
            continue;
        }
        if ((c & 0xE0) == 0xC0 && (src[1] & 0xC0) == 0x80) {
            cp = ((c & 0x1F) << 6) | (src[1] & 0x3F);
            src += 2;
        } else {                            /* не UTF-8 - просто пропускаем */
            src++;
            continue;
        }
        if (cp == 0x401) cp = 0x415;        /* Ё как Е */
        if (cp == 0x451) cp = 0x435;        /* ё как е */
        if (cp >= 0x410 && cp <= 0x42F) {
            const char *t = TAB[cp - 0x410];
            while (*t && o < dstsz - 1) dst[o++] = *t++;
        } else if (cp >= 0x430 && cp <= 0x44F) {
            const char *t = TAB[cp - 0x430];
            int first = 1;
            while (*t && o < dstsz - 1) {   /* строчные - в нижнем регистре */
                char ch = *t++;
                dst[o++] = first ? (char)(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch) : ch;
                first = 0;
            }
        }
    }
    dst[o] = 0;
}

/* Время сцен считаем в миллисекундах, а не в кадрах: темп отрисовки менялся
 * уже трижды, и каждый раз анимации, привязанные к кадрам, разъезжались -
 * курсор начинал частить, живой лог мелькать. */
static unsigned long scene_ms(void)
{
    return jiffies_to_msecs(jiffies);
}

static void matrix_update_dmesg(void)
{
    struct kmsg_dump_iter iter;
    char buf[256];
    size_t len;
    if (matrix_ext_ttl > 0) { matrix_ext_ttl--; return; }
    kmsg_dump_rewind(&iter);
    while (kmsg_dump_get_line(&iter, false, buf, sizeof(buf) - 1, &len)) {
        char *msg;
        if (!len) continue;
        buf[len] = 0;
        while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
            buf[--len] = 0;
        msg = buf;
        /* Снимаем префиксы <приоритет> (syslog) и [   12.345678] (метка
         * времени ядра) - на экране нужен только текст события. */
        if (msg[0] == '<') { char *p = strchr(msg, '>'); if (p) msg = p + 1; }
        if (msg[0] == '[') {
            char *p = strchr(msg, ']');
            if (p) { msg = p + 1; if (*msg == ' ') msg++; }
        }
        /* Матрица-скринсейвер показывает ЖИВОЙ системный лог: собственные
         * отладочные строки драйвера (almond3s-lcd: ШИМ/панель/PIC...)
         * пропускаем, чтобы внизу бежали события ядра, а не наш дебаг.
         * Бут-лого свой лог берёт отдельно (banner_update_log) и не фильтрует. */
        if (strncmp(msg, "almond3s-lcd", 12) == 0) continue;
        if (*msg)
            translit(msg, matrix_dmesg_line, sizeof(matrix_dmesg_line));
    }
}
#define RAB_W 20
#define RAB_H 22
#define RAB_X0 ((MATRIX_COLS - RAB_W) / 2)   /* 16 */
#define RAB_Y0 3                              /* upper half so text fits below */

static int   matrix_init;
static unsigned long matrix_t0;   /* начало сцены: тайминги текста в реальном
                                     времени, а не в кадрах */
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
    int accumulating, ms;

    if (!matrix_init) {
        for (i = 0; i < MATRIX_COLS; i++) {
            m_drop_y[i]    = sin_lut[(i * 7) & 0xFF] % MATRIX_ROWS;
            m_drop_sp[i]   = 1 + (sin_lut[(i * 13) & 0xFF] & 0x03);
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
        matrix_t0 = jiffies;
    }

    /* Затухание следа. Чёрные пиксели пропускаем: результат для них тот же
     * ноль, а их на экране подавляющее большинство - перебор всех 76800
     * с чтением и записью стоил дороже, чем сама передача кадра на панель,
     * и держал заставку на 20 кадрах вместо 40. */
    for (i = 0; i < LCD_W * LCD_H; i++) {
        u16 pxv = fb[i];
        u8 g;
        if (!pxv)
            continue;
        g = (pxv >> 5) & 0x3F;
        fb[i] = (u16)((g * 13) >> 4) << 5;
    }

    /* Accumulation window: drops entering rabbit cells imprint permanently.
     * Before — pure rain. After — rabbit stays fully lit. */
    /* Тайминги ниже - в миллисекундах от начала сцены. Раньше они считались
     * в кадрах, и любое изменение темпа сдвигало всю заставку: при ускорении
     * надписи промелькивали бы вдвое быстрее, чем их можно прочесть. */
    ms = (int)jiffies_to_msecs(jiffies - matrix_t0);

    accumulating = (ms >= 1400 && ms < 5750);

    /* Advance columns and draw rain */
    for (i = 0; i < MATRIX_COLS; i++) {
        m_drop_tick[i]++;
        if (m_drop_tick[i] >= m_drop_sp[i]) {
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
    if      (ms >=  500 && ms < 2000) msg = "Wake up, Neo...";
    else if (ms >= 3000 && ms < 4600) msg = "The Matrix has you...";
    else if (ms >= 5600 && ms < 7500) msg = "Follow the white rabbit.";

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
    /* Полный проход по кольцевому буферу ядра дороже, чем передача кадра на
     * панель: строк там тысячи, а нужна одна последняя. Двух раз в секунду
     * глазу достаточно, и это ровно та частота, что была при 20 кадрах. */
    static unsigned long dmesg_at;
    if (scene_ms() - dmesg_at >= 500 || matrix_dmesg_line[0] == 0) {
        dmesg_at = scene_ms();
        matrix_update_dmesg();
    }
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
/* === Scene 8: загрузочный баннер ALMOND3S SECOND LIFE ===
 * Рисуем ASCII-арт как есть (моноширинный шрифт драйвера), блоком по центру:
 * центрируем по самой широкой строке, внутреннее выравнивание арта сохраняем.
 * Статичный - каждый кадр один и тот же, а сравнение строк во flush гонит на
 * панель только первый. Матрица (сцена 6) остаётся в коде и доступна. */
static const char *banner_lines[] = {
    "  _______ __                          __ _____",
    " |   _   |  |.--------.-----.-----.--|  |__   |",
    " |       |  ||        |  _  |     |  _  |__   |",
    " |___|___|  ||__|__|__|_____|__|__|_____|_____|",
    "         |____| S E C O N D   L I F E",
};
#define BANNER_NLINES ((int)(sizeof(banner_lines) / sizeof(banner_lines[0])))
#define BANNER_GREEN  0x1C6A   /* #1f8f53 - цвет бут-лога (терминал) */
#define BANNER_LOGO   0x258C   /* #21b365 - цвет самого лого (ярче) */

#define BANNER_LINE_H 10   /* единый шаг строк: терминальный воздух между всеми
                              строками (шрифт 7px + ~3px зазор). Вертикальные
                              палки фиглета при этом слегка сегментируются -
                              как в настоящем терминале и выглядит. */
#define BANNER_TOP    14   /* отступ лого сверху на буте (когда под ним лог) */

/* Бут-лог под лого: последние строки ядра. Ширину режем по краям лого (от
 * левой | до правой |), высоту - сколько влезет под лого до низа экрана. */
#define BLOG_LINES 18
#define BLOG_W     46      /* от | (кол.1) до | (кол.46) = ~45 символов + \0 */
static char blog_ring[BLOG_LINES][BLOG_W];
static int  blog_head;             /* следующий слот записи */
static int  blog_total;            /* всего строк (для порядка вывода) */

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
        if (!len) continue;
        buf[len] = 0;
        while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
            buf[--len] = 0;
        msg = buf;
        /* Срезаем префиксы: <приоритет> (syslog) и [   12.345678] (метка
         * времени ядра) - на экране нужен только текст события. */
        if (msg[0] == '<') { char *p = strchr(msg, '>'); if (p) msg = p + 1; }
        if (msg[0] == '[') {
            char *p = strchr(msg, ']');
            if (p) { msg = p + 1; if (*msg == ' ') msg++; }
        }
        if (!*msg) continue;
        strncpy(blog_ring[blog_head], msg, BLOG_W - 1);
        blog_ring[blog_head][BLOG_W - 1] = 0;
        blog_head = (blog_head + 1) % BLOG_LINES;
        blog_total++;
    }
}

static void scene_banner(int t)
{
    u16 *fb = (u16 *)framebuffer;
    int i, j, maxlen = 0, left, top, total_h, cy;
    int boot = (console_phase == 0);   /* идёт загрузка -> лог под лого */
    for (i = 0; i < LCD_W * LCD_H; i++) fb[i] = 0x0000;
    for (i = 0; i < BANNER_NLINES; i++) {
        int l = (int)strlen(banner_lines[i]);
        if (l > maxlen) maxlen = l;
    }
    left = (LCD_W - maxlen * 6) / 2; if (left < 0) left = 0;
    total_h = (BANNER_NLINES - 1) * BANNER_LINE_H + 7;
    /* На буте лого сверху (под ним лог), как хранитель - по центру. */
    top = boot ? BANNER_TOP : (LCD_H - total_h) / 2;
    if (top < 0) top = 0;
    cy = top + (BANNER_NLINES - 1) * BANNER_LINE_H;
    for (i = 0; i < BANNER_NLINES; i++) {
        const char *s = banner_lines[i];
        int x = left, y = top + i * BANNER_LINE_H;
        for (j = 0; s[j]; j++) { fb_putchar(fb, x, y, s[j], BANNER_LOGO, 0x0000); x += 6; }
    }
    /* Терминальный курсор: зелёный прямоугольник через пробел после "L I F E".
     * Полсекунды горит, полсекунды нет - как в настоящем терминале. */
    if ((scene_ms() / 500) % 2 == 0) {
        int cx = left + ((int)strlen(banner_lines[BANNER_NLINES - 1]) + 1) * 6;
        int rr, cc;
        for (rr = 0; rr < 7; rr++)
            for (cc = 0; cc < 5; cc++)
                if ((unsigned)(cx + cc) < LCD_W && (unsigned)(cy + rr) < LCD_H)
                    fb[(cy + rr) * LCD_W + cx + cc] = BANNER_LOGO;
    }
    /* Бут-лог под лого. Обновляем захват раз в 3 кадра (kmsg перечитываем не
     * каждый кадр), рисуем от левой | лого, шириной до правой |. */
    if (boot) {
        int logx = left + 6;                          /* левая | лого */
        int logy = top + total_h + 8;
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
            if (yy + 7 > LCD_H) break;
            for (j = 0; ls[j]; j++) { fb_putchar(fb, x, yy, ls[j], BANNER_GREEN, 0x0000); x += 6; }
        }
    }
}

#define NUM_SCENES 2
static int current_scene = 1;   /* 0 = матрица, 1 = баннер (boot splash) */

static void render_scene(int scene, int t)
{
    switch (scene) {
    case 0: scene_matrix(t); break;
    case 1: scene_banner(t); break;
    default: scene_banner(t); break;   /* дефолт - баннер (boot splash) */
    }
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
        /* Разворот делаем регистром панели (MADCTL), а не переворотом
         * пикселей: даром и не мешает построчной отправке. Команду шлём
         * из этого же потока - шина у него одна. */
        if (lcd_rot_pending) {
            lcd_rot_pending = 0;
            lcd_cmd(0x36);
            lcd_dat(lcd_rot ? 0x68 : 0xA8);
            prev_valid = false;
            fb_dirty = 1;
        }
        /* Полный reset+init панели - лечилка на случай слетевшего контроллера
         * и рычаг для смены таблицы инициализации. Делается здесь же, потому
         * что шина у потока отрисовки одна; таймер ШИМ на это время замирает,
         * иначе его прерывание порвёт такты reset-последовательности. */
        if (panel_reinit_pending) {
            panel_reinit_pending = 0;
            bl_bus_busy = true;
            lcd_hw_reset();
            lcd_init_ili9341();
            bl_bus_busy = false;
            bl_resync();
            prev_valid = false;
            fb_dirty = 1;
        }
        while (pcmd_tail != pcmd_head) {
            u32 pc = pcmd_q[pcmd_tail];
            u8 c = (pc >> 16) & 0xFF, dt = (pc >> 8) & 0xFF, n = pc & 0xFF;
            bl_bus_busy = true;
            lcd_cmd(c);
            if (n) lcd_dat(dt);
            lcd_cs_deselect();
            bl_bus_busy = false;
            bl_resync();
            pcmd_tail = (pcmd_tail + 1) & 15;
        }
        if (splash_active) {
            /* Splash runs until userspace writes to /dev/lcd. Live kmsg tail
             * is overlaid inside the matrix scene itself, so no separate
             * full-screen dmesg phase. */
            render_scene(current_scene, frame++);
            lcd_flush_fb();
            /* Пауза была 100мс, потом 25мс. Кадр заставки стоит панели ~24мс
             * и упирается в шину, а не в паузу: «матрица» перекрашивает весь
             * экран каждый кадр (затухание следа), поэтому дифф строк здесь не
             * помогает. Оставляем символическую паузу - только чтобы поток
             * уступал процессор и быстро останавливался. */
            msleep_interruptible(2);
            if (kthread_should_stop()) break;
        } else if (fb_dirty && !fb_writing) {
            console_phase = 2; /* userspace took over */
            lcd_flush_fb();
            fb_dirty = 0;
        } else {
            /* Страховка от застрявших строк панели: гонки снимка изредка
             * оставляют на стекле полосу прошлого кадра, которую дифф
             * строк никогда не перерисует (ловили чёрную полосу 15.08 и
             * зелёную 16.08). Раз в ~10 минут просим полный кадр - при
             * работающем ШИМе одна полная протяжка глазу не видна. */
            static int repaint_tick;
            if (++repaint_tick >= 12000) {
                repaint_tick = 0;
                prev_valid = false;
                fb_dirty = 1;
            }
            msleep_interruptible(50);
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

    if (pos == 0) {
        fb_writing = 1;  /* block render thread from flushing */
        fb_writer = f;
    }

    /* Ждём мьютекс ПРЕРЫВАЕМО. С обычным mutex_lock процесс, которому в этот
     * момент прилетел SIGTERM (procd при перезапуске службы), уходил в
     * непрерываемое ожидание: снять его не мог даже SIGKILL, задача навсегда
     * оставалась в состоянии D и держала ссылку на модуль - rmmod после этого
     * не проходил. */
    if (mutex_lock_interruptible(&fb_lock)) {
        /* Прерванная запись не должна оставлять флаг взведённым: поток
         * отрисовки ждёт его снятия и без этого больше не выводит НИЧЕГО -
         * экран замирает до перезагрузки модуля. */
        fb_writing = 0;
        fb_writer = NULL;
        return -ERESTARTSYS;
    }
    if (copy_from_user(framebuffer + pos, buf, cnt)) {
        mutex_unlock(&fb_lock);
        fb_writing = 0;
        fb_writer = NULL;
        return -EFAULT;
    }
    mutex_unlock(&fb_lock);

    *p = pos + cnt;

    /* Полный кадр записан - снимаем копию ПРЯМО СЕЙЧАС и только потом просим
     * вывод. Так на панель уезжает именно этот кадр целиком: что userspace
     * нарисует дальше (а начинает он с заливки фоном), попадёт уже в
     * следующий. Раньше копия снималась в момент вывода, и панель ловила
     * наполовину очищенный экран - картинка мигала, будто пропадает. */
    if (pos + cnt >= FB_SIZE) {
        int wait = 0;

        /* ДОЖИДАЕМСЯ, ПОКА ПРЕДЫДУЩИЙ КАДР УЕДЕТ. Снимок один на всех: если
         * переписать его во время вывода, поток отрисовки досылает на панель уже
         * НОВЫЕ пиксели, а помечает отправленным ВЕСЬ новый кадр. Строки, которые
         * он успел сравнить и пропустить как «не изменившиеся», на панели
         * остаются от старого кадра - и больше никогда не перерисовываются:
         * заставка накрывала экран лишь частично, а под ней жила прошлая
         * страница. */
        while (flush_busy && wait++ < 200)
            msleep_interruptible(2);

        if (mutex_lock_interruptible(&fb_lock)) {
            /* Кадр дописан, но снимок не снят. Флаг обязан упасть и здесь,
             * иначе поток отрисовки ждёт его снятия вечно и экран замирает -
             * та же ловушка, что и у первой точки ожидания выше. */
            fb_writing = 0;
            fb_writer = NULL;
            return -ERESTARTSYS;
        }
        memcpy(flush_snap, framebuffer, FB_SIZE);
        mutex_unlock(&fb_lock);
        /* Ожидание выше могло НЕ дождаться: msleep_interruptible при висящем
         * сигнале возвращается мгновенно, и цикл пролетает за микросекунды.
         * Тогда снимок переписан ПОД уходящим кадром: поток отрисовки дошлёт
         * панели уже новые пиксели, а пропущенные как «не изменившиеся»
         * строки останутся на ней от старого кадра - навсегда, потому что в
         * prev_snap они помечены свежими. Раньше это самолечилось побочным
         * эффектом бага с fb_writing (лишние пересылки), теперь честно
         * просим полный кадр. */
        if (flush_busy)
            prev_valid = false;
        snap_ready = 1;
        fb_writing = 0;
        fb_writer = NULL;
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
static int touch_ok_cnt, touch_drop_cnt, touch_bad_ch;
static struct task_struct *touch_thread;
static struct i2c_adapter *touch_i2c_adap;

/* === PIC16 Battery via Linux I2C === */
#define PIC_ADDR  0x2A
#define PIC_BATTERY_LEN  17

static u8 pic_battery_raw[PIC_BATTERY_LEN];
static int pic_battery_valid;
static int pic_beep_request;  /* set from ioctl, executed in touch thread */
static int pic_led_cmd;       /* однобайтовая команда диода в очереди */
static u8  pic_raw_buf[160];
static int pic_raw_len;       /* >0 - в очереди посылка в PIC */
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

/*
 * По даташиту SX8650 (V2.19) наша унаследованная инициализация была ручным
 * режимом с двумя странностями: регистра 0x03 у чипа нет (наследие SX8651),
 * а «PenTrg» на деле был SELECT(X)+CONVERT(X). Настоящий PENTRG - команда
 * 0xE0: чип сам ждёт перо, сам меряет каналы из маски и отдаёт их пачкой
 * за одну транзакцию. Плюс POWDLY: 0.5 мкс на устоявание канала для панели
 * с LCD прямо под тачем - это ничто, отсюда потерянные короткие тапы.
 * touch_mode: 1 = PENTRG (экспериментальный), 0 = ручной (рабочий дефолт).
 * РАЗГАДКА (ночь 15-16.08, архив iSublimity/TOUCH.md): на этом кремнии
 * CONVERT-команды возвращают 0xFF - работают ТОЛЬКО SELECT(X)/SELECT(Y).
 * А «0x91» легаси-цикла - не команда, а read-адрес чипа (0x48<<1|1).
 * То есть заводской цикл - единственно правильный протокол; PENTRG(0xE0)
 * дал поток одного канала Y, CONVERT(SEQ,0x97) - вечное 0xFF, оба тупика
 * аппаратные. Экспериментальная ветка оставлена как памятник с дампером.
 */
static int touch_mode = 0;
static int touch_mode_req = -1;  /* смена режима: применяет тач-поток, шина его */
static int sx_reg_req = -1;      /* адрес регистра на чтение (0x40|RA внутри) */
static int sx_reg_val = -2;      /* результат: >=0 байт, -2 не готов */

static void sx8650_config(int pentrg)
{
    u32 saved_ctl1 = gr(SM0_CTL1);

    gw(SM0_CTL1, 0x90644042);
    gw(0x928, 1);

    i2c_raw_start(); i2c_raw_write(0x1F); i2c_raw_write(0xDE); i2c_raw_stop();
    mdelay(50);

    /* Ctrl0: RATE=0 (по запросу), POWDLY - в эксперименте даём устояться */
    i2c_raw_start(); i2c_raw_write(0x00); i2c_raw_write(pentrg ? 0x06 : 0x00); i2c_raw_stop(); udelay(150);
    /* Ctrl1: CONDIRQ=1, RPDNT=200к, фильтр 7 выборок (заводское, оптимум) */
    i2c_raw_start(); i2c_raw_write(0x01); i2c_raw_write(0x27); i2c_raw_stop(); udelay(150);
    i2c_raw_start(); i2c_raw_write(0x02); i2c_raw_write(0x00); i2c_raw_stop(); udelay(150);
    /* 0x03=0x2D: у SX8650 такого регистра по даташиту нет, но заводская
     * прошивка его писала, и на плате может стоять пин-совместимый SX8651,
     * у которого 0x03 существует. Пишем как завод - хуже не будет. */
    i2c_raw_start(); i2c_raw_write(0x03); i2c_raw_write(0x2D); i2c_raw_stop(); udelay(150);
    /* ChanMsk: в эксперименте меряем X,Y,Z1,Z2 - давление отсеивает помехи */
    i2c_raw_start(); i2c_raw_write(0x04); i2c_raw_write(pentrg ? 0xF0 : 0xC0); i2c_raw_stop(); udelay(150);

    if (pentrg) {
        /* Никакой команды режима: остаёмся в ручном (RATE=0). Живой тест
         * PENTRG (0xE0) на этом кремнии дал поток из ОДНОГО канала Y -
         * маску он не уважает. Вместо этого каждый опрос шлёт
         * CONVERT(SEQ)=0x97: одна команда конвертирует все каналы маски,
         * и пакет приходит в гарантированном порядке X,Y,Z1,Z2. */
        ;
    } else {
        i2c_raw_start();
        gw(SM0_DATAOUT, 0x80); gw(SM0_STATUS, 2); udelay(150);
        gw(SM0_START, 0); udelay(150);
        i2c_raw_start();
        gw(SM0_DATAOUT, 0x90); gw(SM0_STATUS, 2); udelay(150);
    }

    gw(SM0_CFG, 0xFA);
    gw(SM0_CTL1, saved_ctl1); udelay(10);
}

static void sx8650_hw_init(void)
{
    /* Get I2C adapter for PIC battery (Linux I2C) */
    touch_i2c_adap = i2c_get_adapter(0);
    if (!touch_i2c_adap)
        pr_warn("cannot get I2C adapter 0 (PIC battery won't work)\n");

    sx8650_config(touch_mode);
    pr_info("SX8650 init done (%s, palmbus + SM0 save/restore)\n",
            touch_mode ? "PENTRG" : "manual");
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
        else touch_bad_ch++;
    }

    /* Пальца нет - второй канал не читаем. Экран почти всё время свободен,
     * а каждое чтение это около 800 мкс активного ожидания на шине; так
     * опрос в простое обходится вдвое дешевле, и задержки это не добавляет:
     * выборка всё равно была бы отброшена. */
    if (raw_x <= 0) {
        gw(SM0_CTL1, saved_ctl1); udelay(10);
        touch_drop_cnt++;
        return 0;
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
        if (ch == 1) raw_y = val;
        else touch_bad_ch++;
    }

    if (raw_x > 0 && raw_y > 0) {
        int px = (4096 - raw_y) * TOUCH_SCALE_X / 4096 - TOUCH_OFF_X;
        int py = raw_x * TOUCH_SCALE_Y / 4096 - TOUCH_OFF_Y;
        *rx = px < 0 ? 0 : (px > LCD_W - 1 ? LCD_W - 1 : px);
        *ry = py < 0 ? 0 : (py > LCD_H - 1 ? LCD_H - 1 : py);
        if (lcd_rot) {
            *rx = LCD_W - 1 - *rx;
            *ry = LCD_H - 1 - *ry;
        }
        touch_ok_cnt++;
        return 1;
    }
    touch_drop_cnt++;
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
    msleep(10);  /* stock: 10ms delay after 0x39 */

    /* WRITE cmd 0x36 (ADC read) */
    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_CFG, 0xFA);
    gw(SM0_DATA, PIC_ADDR);
    gw(SM0_START, 1);
    gw(SM0_DATAOUT, 0x36);
    gw(SM0_STATUS, 0);
    { int w; for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); } }

    pr_debug("PIC[v14] W: PS=%02x CTL0=%08x\n", gr(0x918), gr(SM0_CTL1));

    usleep_range(5000, 6000);

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
    pr_debug("PIC bat: %02x %02x %02x %02x %02x %02x\n",
            resp[0], resp[1], resp[2], resp[3], resp[4], resp[5]);

    /* Parse: stock format byte0=ADC_lo, byte1=ADC_hi, byte2=status */
    {
        /* Разбор как в заводском драйвере: 12 бит из байта 1 и младшего
         * полубайта байта 3. Прежняя проверка resp[3]==0x02 отбрасывала
         * все выборки вне окна 512..767, и показания замирали. */
        int adc = ((resp[3] & 0x0F) << 8) | resp[1];
        /* Статус-байт по заводскому разбору: bit0 - зарядка, bit5+bit6 -
         * батареи нет, bit6 без bit5 - tamper. Какой-то из оставшихся бит
         * должен отражать кнопку питания (сток по ней запускал handshake
         * выключения 0x38) - логируем каждую перемену, чтобы поймать его
         * живым нажатием. */
        {
            static u8 last_stat = 0xFF;
            if (resp[4] == 0x04 && resp[5] != last_stat) {
                pr_info("PIC статус 0x%02x -> 0x%02x (adc=%d)\n",
                        last_stat, resp[5], adc);
                last_stat = resp[5];
            }
        }
        if (resp[4] == 0x04 && adc < 1023) {
            pic_battery_raw[0] = resp[0];
            pic_battery_raw[1] = resp[1];
            pic_battery_raw[2] = resp[2];
            pic_battery_raw[3] = resp[3];
            pic_battery_raw[4] = resp[4];
            pic_battery_raw[5] = resp[5];
            pic_battery_valid = 1;
            pr_debug("PIC ADC=%d status=%02x\n", adc, resp[2]);
        }
    }
}

/*
 * PENTRG-чтение: чип сам сконвертировал X,Y,Z1,Z2 по касанию - забираем
 * пачку одной транзакцией (порядок каналов фиксирован, от старшего бита
 * маски). Нет пера - чип отдаёт 0xFFFF («Invalid Qualified Data»), это
 * штатный маркер, а не ошибка шины. Пары Z1/Z2 - готовый критерий помехи
 * из даташита: Z1<10 при Z2>4070 = мусор от ESD/наводки.
 */
static int sx8650_read_pentrg(int *rx, int *ry)
{
    u8 b[8];
    int i, p, ch, got = 0, val[4] = {0, 0, 0, 0};
    u32 saved_ctl1 = gr(SM0_CTL1);

    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_CFG, 0xFA);

    /* CONVERT(SEQ): один запрос - все каналы маски (X,Y,Z1,Z2). */
    gw(SM0_DATA, SX8650_ADDR);
    gw(SM0_START, 1);
    gw(SM0_DATAOUT, 0x97);
    gw(SM0_STATUS, 0);
    for (p = 0; p < 500; p++) { if (gr(0x918) & 0x01) break; udelay(10); }

    /* Tconv для 4 каналов с POWDLY~36мкс и фильтром 7 выборок - сотни
     * микросекунд; ждём с запасом, потом забираем пакет. */
    usleep_range(800, 1000);

    gw(SM0_DATA, SX8650_ADDR);
    gw(SM0_START, 7);
    gw(SM0_STATUS, 1);
    for (i = 0; i < 8; i++) {
        for (p = 0; p < 1500; p++) {
            if (gr(0x918) & 0x04) break;
            udelay(2);
        }
        if (p >= 1500) {
            gw(SM0_CTL1, saved_ctl1); udelay(10);
            return 0;          /* нет данных - не ошибка */
        }
        udelay(5);
        b[i] = gr(SM0_DATAIN) & 0xFF;
    }
    gw(SM0_CTL1, saved_ctl1); udelay(10);

    if (b[0] == 0xFF)
        return 0;              /* 0xFFFF = пера нет, штатный маркер */

    /* Мы сами запросили конверсию - порядок пакета детерминирован:
     * X, Y, Z1, Z2, каждый с тегом канала в старшем полубайте. */
    for (i = 0; i < 4; i++) {
        u8 hi = b[i * 2];
        if (hi == 0xFF)
            break;             /* хвост не сконвертирован - X/Y уже есть */
        ch = (hi >> 4) & 7;
        if (ch > 3 || (hi & 0x80)) {
            static int dump_left = 12;
            if (dump_left > 0) {
                dump_left--;
                pr_info("SEQ raw: %02x %02x %02x %02x %02x %02x %02x %02x\n",
                        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]);
            }
            touch_bad_ch++;
            return 0;
        }
        val[ch] = ((hi & 0x0F) << 8) | b[i * 2 + 1];
        got |= 1 << ch;
    }
    if ((got & 3) != 3) {
        /* Кадр с данными, но без полной пары X+Y - показать, что пришло. */
        static int pdump_left = 20;
        if (pdump_left > 0) {
            pdump_left--;
            pr_info("SEQ part(got=%x): %02x %02x %02x %02x %02x %02x %02x %02x\n",
                    got, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]);
        }
        touch_drop_cnt++;
        return 0;
    }

    /* Отбраковку по давлению ВЫКЛЮЧИЛИ: пороги из даташита (Z1<10 &&
     * Z2>4070) на живом стекле резали 92% настоящих касаний. Сначала
     * калибруем по дампам реальные диапазоны, потом вернём порог. */
    {
        static int zdump_left = 20;
        if ((got & 0x0C) == 0x0C && zdump_left > 0) {
            zdump_left--;
            pr_info("SEQ z: x=%d y=%d z1=%d z2=%d\n",
                    val[0], val[1], val[2], val[3]);
        }
    }

    {
        int px = (4096 - val[1]) * TOUCH_SCALE_X / 4096 - TOUCH_OFF_X;
        int py = val[0] * TOUCH_SCALE_Y / 4096 - TOUCH_OFF_Y;
        *rx = px < 0 ? 0 : (px > LCD_W - 1 ? LCD_W - 1 : px);
        *ry = py < 0 ? 0 : (py > LCD_H - 1 ? LCD_H - 1 : py);
        if (lcd_rot) {
            *rx = LCD_W - 1 - *rx;
            *ry = LCD_H - 1 - *ry;
        }
    }
    touch_ok_cnt++;
    return 1;
}

/*
 * Чтение конфигурационного регистра SX865x: та же рабочая SM0-
 * последовательность, что и чтение координаты, только первым байтом идёт
 * команда «прочитай регистр» (0x40|RA) вместо SELECT. Нужно для
 * идентификации чипа: у SX8651 существует регистр 0x03 (CTRL3, заводское
 * значение 0x2D), у SX8650 его нет.
 */
/*
 * Регистры чипа НЕ ЧИТАЮТСЯ никаким из трёх способов (старый движок со
 * стопом и без - FF; NEW-движок и ядерный i2c - NACK на адресе: чип
 * отвечает только старому движку под CTL0=0x90644042). Идентификацию
 * делаем ПОВЕДЕНЧЕСКИ: SELECT произвольного канала + чтение проверенным
 * координатным циклом. У SX8651 есть каналы RX(5)/RY(6) - SX8650 их не
 * имеет. arg = байт SELECT (0x80|канал); возврат = сырые (h<<8)|l.
 */
static int sx8650_select_read(int selbyte)
{
    u8 h, l;
    u32 saved_ctl1 = gr(SM0_CTL1);

    gw(SM0_CTL1, 0x90644042); udelay(10);
    gw(SM0_DATA, SX8650_ADDR);
    gw(SM0_START, 0); udelay(10);
    gw(SM0_DATAOUT, selbyte & 0xFF);
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
    gw(SM0_CTL1, saved_ctl1); udelay(10);
    return ((int)h << 8) | l;
}

/* Одиночная запись регистра чипа проверенным путём (как init). */
static void sx8650_write_reg(int reg, int val)
{
    u32 saved_ctl1 = gr(SM0_CTL1);

    gw(SM0_CTL1, 0x90644042);
    i2c_raw_start();
    i2c_raw_write(reg & 0x1F);
    i2c_raw_write(val & 0xFF);
    i2c_raw_stop();
    gw(SM0_CFG, 0xFA);
    gw(SM0_CTL1, saved_ctl1); udelay(10);
}

static int touch_fn(void *data)
{
    int x, y, was_pressed = 0;
    int no_touch_count = 0;
    int battery_counter = 0;
    int cfg_counter = 0;

    while (!kthread_should_stop()) {
        /* Touch read (palmbus direct, SM0_CTL1 saved/restored) */
        if (touch_mode ? sx8650_read_pentrg(&x, &y)
                       : sx8650_read_xy(&x, &y)) {
            touch_x = x;
            touch_y = y;
            touch_pressed = 1;
            no_touch_count = 0;
            if (!was_pressed)
                pr_debug("touch DOWN x=%d y=%d (raw data logged)\n", x, y);
            was_pressed = 1;
        } else {
            no_touch_count++;
            if (no_touch_count > 4 && was_pressed) {
                touch_pressed = 0;
                was_pressed = 0;
                pr_debug("touch UP\n");
            }
        }

        if (touch_mode_req >= 0) {
            touch_mode = touch_mode_req;
            touch_mode_req = -1;
            sx8650_config(touch_mode);
            pr_info("тач: режим %s\n", touch_mode ? "PENTRG" : "ручной");
        }

        if (sx_reg_req >= 0) {
            if (sx_reg_req & 0x10000)
                sx8650_write_reg((sx_reg_req >> 8) & 0x1F,
                                 sx_reg_req & 0xFF), sx_reg_val = 0;
            else
                sx_reg_val = sx8650_select_read(sx_reg_req & 0xFF);
            sx_reg_req = -1;
        }

        /* ESD может молча ресетнуть SX8650 - регистры волатильные и
         * вернутся в дефолт (даташит, разд. 7.6). Раз в минуту, в паузе
         * между касаниями, перезаписываем конфигурацию заново - дешёвая
         * страховка вместо сверки регистров. */
        if (++cfg_counter >= 2000) {
            cfg_counter = 0;
            if (!touch_pressed && no_touch_count > 150)
                sx8650_config(touch_mode);
        }

        /* Battery read every ~10 sec (200 * 50ms) */
        battery_counter++;
        if (battery_counter >= 333) {
            battery_counter = 0;
            pic_read_battery_palmbus();
        }

        /* Диод: команда ставится в очередь классом светодиодов ядра и
         * уходит отсюда - шина у нас одна на всех. */
        if (pic_led_cmd) {
            u32 s_ctl1 = gr(SM0_CTL1);
            int w, cmd_b = pic_led_cmd;
            pic_led_cmd = 0;

            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 1);
            gw(SM0_DATAOUT, cmd_b);
            gw(SM0_STATUS, 0);
            for (w = 0; w < 500; w++) {
                if (gr(0x918) & 0x01) break;
                udelay(10);
            }
            gw(SM0_CTL1, s_ctl1); udelay(10);
        }

        /* Посылка произвольной длины: мелодия грузится одним пакетом
         * {0x2D, hi, lo, hi, lo, ...} - так это делает заводской драйвер,
         * старшим байтом вперёд. */
        if (pic_raw_len > 0) {
            u32 s_ctl1 = gr(SM0_CTL1);
            int i, w;

            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, pic_raw_len);
            gw(SM0_DATAOUT, PIC_ADDR);
            gw(SM0_STATUS, 0);
            for (i = 0; i < pic_raw_len; i++) {
                for (w = 0; w < 20000; w++) {
                    if (gr(0x918) & 0x02) break;
                    cpu_relax();
                }
                usleep_range(15000, 16000);
                gw(SM0_DATAOUT, pic_raw_buf[i]);
            }
            gw(SM0_CTL1, s_ctl1); udelay(10);
            pr_debug("PIC пакет %d байт, первый 0x%02x\n", pic_raw_len, pic_raw_buf[0]);
            pic_raw_len = 0;
        }

        /* PIC command from ioctl (beep or raw cmd) */
        if (pic_beep_request) {
            u32 s_ctl1 = gr(SM0_CTL1);
            int bw;
            int pic_mode = pic_beep_request;
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

            if (pic_mode == 2) {
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
                    pr_debug("PIC cmd {%02x,00,%02x} 3-byte\n", raw_cmd, raw_data);
                } else {
                    /* 1-byte write */
                    gw(SM0_CTL1, 0x90644042); udelay(10);
                    gw(SM0_CFG, 0xFA);
                    gw(SM0_DATA, PIC_ADDR);
                    gw(SM0_START, 1);
                    gw(SM0_DATAOUT, raw_cmd);
                    gw(SM0_STATUS, 0);
                    for(bw=0;bw<500;bw++){if(gr(0x918)&0x01)break;udelay(10);}
                    pr_debug("PIC cmd 0x%02x 1-byte\n", raw_cmd);
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

        msleep_interruptible(30);
    }
    return 0;
}

/*
 * Выключение по-заводски: PIC по команде 0x38 опускает PORTE.5 и физически
 * рубит питание платы (с воткнутым зарядником чип команду игнорирует - тогда
 * плата остаётся стоять в halt). Слать надо в самом конце штатного
 * выключения, когда всё уже размонтировано, - это pm_power_off. Тач-поток к
 * тому моменту останавливаем через reboot_notifier: он ходит по той же шине
 * SM0, и столкнуться с ним посреди транзакции - подвесить PIC вместо
 * выключения.
 */
static int pic_reboot_prep(struct notifier_block *nb, unsigned long action,
                           void *v)
{
    if (touch_thread) {
        kthread_stop(touch_thread);
        touch_thread = NULL;
    }
    return NOTIFY_DONE;
}
static struct notifier_block pic_reboot_nb = {
    .notifier_call = pic_reboot_prep,
};

static void (*old_pm_power_off)(void);

static void pic_power_off(void)
{
    int try, w;

    /* Как и везде при общении с PIC: сначала 0x39 - его I2C-движок после
     * чужого трафика на шине стоит клином и молча глотает первый пакет.
     * Именно так потерялся 0x38 при первой живой проверке выключения.
     * Несколько попыток: если питание упало - до следующей просто не
     * доживём, а если PIC опять не услышал - добьём повтором. */
    for (try = 0; try < 3; try++) {
        gw(SM0_CTL1, 0x90644042); udelay(10);
        gw(SM0_CFG, 0xFA);
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, 1);
        gw(SM0_DATAOUT, 0x39);
        gw(SM0_STATUS, 0);
        for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); }
        mdelay(10);

        gw(SM0_CTL1, 0x90644042); udelay(10);
        gw(SM0_CFG, 0xFA);
        gw(SM0_DATA, PIC_ADDR);
        gw(SM0_START, 1);
        gw(SM0_DATAOUT, 0x38);
        gw(SM0_STATUS, 0);
        for (w = 0; w < 500; w++) { if (gr(0x918) & 0x01) break; udelay(10); }
        pr_info("PIC 0x38: просим отключить питание (попытка %d)\n", try + 1);
        mdelay(300);
    }
    if (old_pm_power_off)
        old_pm_power_off();
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
    if (cmd == 32) {
        /* Строка статуса матрицы-заставки от userspace (живой logread).
         * Пока её толкают, kmsg не перетирает (matrix_ext_ttl). */
        char buf[128];
        if (copy_from_user(buf, (void __user *)arg, sizeof(buf)))
            return -EFAULT;
        buf[sizeof(buf) - 1] = 0;
        strncpy(matrix_dmesg_line, buf, sizeof(matrix_dmesg_line) - 1);
        matrix_dmesg_line[sizeof(matrix_dmesg_line) - 1] = 0;
        matrix_ext_ttl = 40;
        return 0;
    }
    if (cmd == 30) {
        /* Бенчмарк перерисовки: arg полных кадров с меняющимся содержимым,
         * возврат - суммарные микросекунды (среднее делит userspace). Экран
         * на это время замусорится, потом ui перерисует нормально. */
        int iters = (int)arg, k, p, total_us;
        u16 *fb = (u16 *)framebuffer;
        ktime_t t0;
        if (iters < 1) iters = 1;
        if (iters > 200) iters = 200;
        fb_writing = 1;
        t0 = ktime_get();
        for (k = 0; k < iters; k++) {
            mutex_lock(&fb_lock);
            for (p = 0; p < LCD_W * LCD_H; p++)
                fb[p] = (u16)(p + k * 7);
            mutex_unlock(&fb_lock);
            snap_ready = false;
            prev_valid = false;
            lcd_flush_fb();
        }
        total_us = (int)ktime_to_us(ktime_sub(ktime_get(), t0));
        fb_writing = 0;
        fb_dirty = 1;
        return total_us;
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
            fb_dirty = 1;
            return 0;
        }
        /* Backlight control: arg=0 off, arg=1 on */
        bl_set_level(arg ? BL_MAX : 0);
        return 0;
    }
    if (cmd == 16) {
        /* Яркость 0..255 программным ШИМ (см. bl_set_level). */
        bl_set_level((int)arg);
        return 0;
    }
    if (cmd == 27) {
        /* Тёплый фильтр 0..100. Как и затемнение, меняет цвета на панели, а
         * сравнение строк идёт по исходному кадру - значит нужен полный
         * перезалив. */
        int w = (int)arg;
        if (w < 0) w = 0;
        if (w > 100) w = 100;
        warm_level = w;
        dig_build();
        prev_valid = false;
        fb_dirty = 1;
        return 0;
    }
    if (cmd == 19) {
        /* Цифровое затемнение 0..255. Меняем - весь экран надо переслать:
         * сравнение строк работает по исходному кадру, а на панели теперь
         * другие цвета. */
        int lvl = (int)arg;
        if (lvl < 0) lvl = 0;
        if (lvl > BL_MAX) lvl = BL_MAX;
        dig_level = lvl;
        dig_build();
        prev_valid = false;
        fb_dirty = 1;
        return 0;
    }
    if (cmd == 18) {
        /* Диагностика вывода: строк в последнем кадре, его длительность и
         * счётчик кадров - чтобы видеть, сколько шины съедает перерисовка. */
        int d[3] = { stat_rows, stat_us, stat_frames };
        if (copy_to_user((void __user *)arg, d, sizeof(d)))
            return -EFAULT;
        return 0;
    }
    if (cmd == 25) {
        int d[4] = { (int)bl_max_off_us, (int)bl_long_off,
                     (int)bl_max_on_us, (int)bl_long_on };
        if (copy_to_user((void __user *)arg, d, sizeof(d)))
            return -EFAULT;
        bl_max_off_us = 0;
        bl_long_off = 0;
        bl_max_on_us = 0;
        bl_long_on = 0;
        return 0;
    }
    if (cmd == 24) {
        /* Период ШИМ подсветки в микросекундах. У источника тока подсветки
         * своя область устойчивости, и на низкой яркости мерцание зависит
         * от частоты - подбирается только опытом. */
        long us = (long)arg;
        if (us < 50) us = 50;
        if (us > 20000) us = 20000;
        bl_period_ns = us * 1000L;
        pr_info("ШИМ подсветки: период %ld мкс (%ld Гц)\n", us, 1000000L / us);
        return 0;
    }
    if (cmd == 23) {
        /* Сырая команда панели: arg = 0xCCDDNN, где CC - команда,
         * DD - байт данных, NN - сколько байт данных (0 или 1).
         * В очередь потока отрисовки: немедленная отправка из ioctl
         * врезалась в передачу кадра и портила состояние контроллера
         * (белый экран 16.08). fb_lock сериализует писателей. */
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
    }
    if (cmd == 22) {
        lcd_rot = arg ? 1 : 0;
        lcd_rot_pending = 1;
        return 0;
    }
    if (cmd == 31) {
        /* Тач-чип: SELECT-чтение (arg = байт SELECT, возврат (h<<8)|l)
         * или запись регистра (arg = 0x10000|(reg<<8)|val, возврат 0).
         * Выполняет тач-поток (шина его), ждём до ~700 мс. */
        int t;
        sx_reg_val = -2;
        sx_reg_req = (int)(arg & 0x1FFFF);
        for (t = 0; t < 70; t++) {
            if (sx_reg_req < 0 && sx_reg_val != -2)
                return sx_reg_val;
            msleep(10);
        }
        return -EIO;
    }
    if (cmd == 29) {
        /* Режим тача: 1 = PENTRG (по даташиту), 0 = ручной (легаси).
         * Страховка на случай, если PENTRG на живом стекле поведёт себя
         * не так, как обещает документация. */
        touch_mode_req = arg ? 1 : 0;
        return 0;
    }
    if (cmd == 28) {
        /* Сырые DATA-регистры трёх GPIO-банков - искать, на каком пине
         * живёт кнопка питания (devmem в этом ядре выключен). ВАЖНО: в
         * MT7621 0x600 - это НАПРАВЛЕНИЯ (наши макросы названы наоборот,
         * битбангу всё равно), настоящие данные - 0x620/0x624/0x628.
         * Первая версия читала 0x600 и входов не видела в принципе. */
        u32 d[3] = { gr(0x620), gr(0x624), gr(0x628) };
        if (copy_to_user((void __user *)arg, d, sizeof(d)))
            return -EFAULT;
        return 0;
    }
    if (cmd == 26) {
        /* Переинициализация панели: 0 - текущей таблицей, 1 - таблицей из
         * заводского ядра, 2 - таблицей загрузчика (наш дефолт). */
        if (arg == 1) panel_init_alt = 1;
        else if (arg == 2) panel_init_alt = 0;
        panel_reinit_pending = 1;
        pr_info("панель: переинициализация, таблица %s\n",
                panel_init_alt ? "заводского ядра" : "загрузчика");
        return 0;
    }
    if (cmd == 21) {
        struct { int len; u8 data[152]; } r;
        if (copy_from_user(&r, (void __user *)arg, sizeof(r)))
            return -EFAULT;
        if (r.len < 1 || r.len > (int)sizeof(r.data))
            return -EINVAL;
        if (pic_raw_len > 0)
            return -EBUSY;
        memcpy(pic_raw_buf, r.data, r.len);
        pic_raw_len = r.len;
        return 0;
    }
    if (cmd == 20) {
        int d[3] = { touch_ok_cnt, touch_drop_cnt, touch_bad_ch };
        if (copy_to_user((void __user *)arg, d, sizeof(d)))
            return -EFAULT;
        return 0;
    }
    if (cmd == 17) {
        /* Оба уровня разом: подсветка (ШИМ) и цифровое затемнение картинки. */
        int lvl[2] = { bl_level, dig_level };
        if (copy_to_user((void __user *)arg, lvl, sizeof(lvl)))
            return -EFAULT;
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
    if (cmd == 7) {
        /* Version info: copy "v1.0 Mar 22 2026 18:00:00" to userspace */
        char ver[64];
        int len;
        len = snprintf(ver, sizeof(ver), "%s", LCD_DRV_BUILD);
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

/* Процесс мог умереть посреди кадра - тогда флаг записи остался бы
 * взведённым, и вывод на панель встал бы навсегда. Но снимать его можно
 * только закрытием ТОГО файла, чей write() его взвёл: /dev/lcd открывают
 * и короткоживущие клиенты (collector за батареей каждые пару секунд),
 * и их close посреди чужого кадра отпускал поток отрисовки раньше
 * времени - на панель уезжал наполовину записанный кадр. */
static int lcd_release(struct inode *inode, struct file *f)
{
    if (f == fb_writer) {
        fb_writing = 0;
        fb_writer = NULL;
    }
    return 0;
}

static const struct file_operations lcd_fops = {
    .owner          = THIS_MODULE,
    .write          = lcd_fb_write,
    .llseek         = default_llseek,
    .unlocked_ioctl = lcd_ioctl,
    .release        = lcd_release,
    .mmap           = lcd_mmap,
};

static struct miscdevice lcd_dev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = DEVICE_NAME,
    .fops  = &lcd_fops,
    .mode  = 0666,
};

/* === Module init/exit === */

/* Диод над экраном висит на PIC, а не на GPIO, поэтому в дереве устройств
 * его не описать. Зато классу светодиодов ядра всё равно, чем мы моргаем:
 * достаточно уметь зажечь и погасить. Так он появляется в /sys/class/leds,
 * получает все штатные триггеры и настраивается через uci, как любой другой.
 * Полярность обратна той, что указана в разборе прошивки PIC: 0x32 зажигает. */
static void almond_led_set(struct led_classdev *cdev, enum led_brightness b)
{
    pic_led_cmd = b ? 0x32 : 0x31;
}

/* Мигание умеет сам PIC, поэтому берём его на себя: ядру не нужно будить
 * систему таймером ради лампочки. Свой интервал чип не принимает, так что
 * сообщаем ядру фактический - около двух вспышек в секунду. */
static int almond_led_blink(struct led_classdev *cdev,
                            unsigned long *delay_on, unsigned long *delay_off)
{
    if (*delay_on == 0 && *delay_off == 0) {
        *delay_on = 250;
        *delay_off = 250;
    } else if (*delay_on != 250 || *delay_off != 250) {
        return -EINVAL;   /* мигаем не так - пусть ядро делает это само */
    }
    pic_led_cmd = 0x30;
    return 0;
}

static struct led_classdev almond_led = {
    .name             = "white:status",
    .max_brightness   = 1,
    .brightness_set   = almond_led_set,
    .blink_set        = almond_led_blink,
    .default_trigger  = "none",
};

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

    /* Копия того, что уже на панели. Не вышло - не беда: без неё просто
     * гоняем кадр целиком, как раньше. */
    prev_snap = vzalloc(FB_SIZE);
    prev_valid = false;

    for (i = 0; i < fb_npages; i++)
        fb_pages[i] = vmalloc_to_page(framebuffer + i * PAGE_SIZE);

    /* Таймер ШИМ подсветки: заводим до первого использования, стартует он
     * только когда яркость между краями. */
    dig_build();
    hrtimer_init(&bl_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
    bl_timer.function = bl_tick;

    /* Register device */
    if (led_classdev_register(NULL, &almond_led))
        pr_warn("almond3s-lcd: диод не зарегистрирован\n");

    ret = misc_register(&lcd_dev);
    if (ret) { kfree(framebuffer); kfree(fb_pages); iounmap(gpio_base); return ret; }

    /* Init LCD hardware */
    lcd_gpio_init();
    lcd_hw_reset();
    lcd_init_ili9341();
    bl_set_level(BL_MAX);   /* подсветку зажигаем через тот же путь, что и ШИМ */

    /* First scene frame + logo — render thread continues animation.
     * Сцена 1 = баннер ALMOND3S SECOND LIFE как boot splash; сцена 0 - матрица
     * «Wake up, Neo», доступна как заставка через scene 0. */
    current_scene = 1;
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

        /* Ничего больше в чип не грузим. Здесь раньше отправлялись 400
         * байт «калибровки батареи» командами 0x03 и 0x2E - но 0x2E это
         * таблица длительностей нот, а данные были линейной пилой, о чём
         * прямо говорил заголовок pic_calib.h. Каждая загрузка модуля
         * заливала в PIC мусорную мелодию, и он её проигрывал. Вместо
         * этого просто останавливаем воспроизведение. */
        {
            int p;
            gw(SM0_CTL1, 0x90644042); udelay(10);
            gw(SM0_CFG, 0xFA);
            gw(SM0_DATA, PIC_ADDR);
            gw(SM0_START, 3);
            gw(SM0_DATAOUT, PIC_ADDR);
            gw(SM0_STATUS, 0);
            for (p = 0; p < 100000; p++) if (gr(0x918) & 0x02) break;
            mdelay(15); gw(SM0_DATAOUT, 0x2F);
            for (p = 0; p < 100000; p++) if (gr(0x918) & 0x02) break;
            mdelay(15); gw(SM0_DATAOUT, 0x00);
            for (p = 0; p < 100000; p++) if (gr(0x918) & 0x02) break;
            mdelay(15); gw(SM0_DATAOUT, 0x02);
            mdelay(15);
            pr_info("PIC init done, воспроизведение остановлено\n");
        }

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

    register_reboot_notifier(&pic_reboot_nb);
    old_pm_power_off = pm_power_off;
    pm_power_off = pic_power_off;

    pr_info("%s by a43 — START (fb=%dx%d, %d bytes)\n",
            LCD_DRV_BUILD, LCD_W, LCD_H, FB_SIZE);
    return 0;
}

static void __exit lcd_drv_exit(void)
{
    pm_power_off = old_pm_power_off;
    unregister_reboot_notifier(&pic_reboot_nb);
    /* Сначала гасим потоки: они читают prev_snap и framebuffer, освобождать
     * память раньше них - use-after-free в момент rmmod. Таймер отменяем
     * безусловно: на неактивном hrtimer_cancel безвреден, а проверка
     * bl_timer_on могла разминуться с bl_set_level. */
    if (touch_thread) kthread_stop(touch_thread);
    if (render_thread) kthread_stop(render_thread);
    hrtimer_cancel(&bl_timer);
    misc_deregister(&lcd_dev);
    led_classdev_unregister(&almond_led);
    if (touch_i2c_adap) i2c_put_adapter(touch_i2c_adap);
    if (prev_snap) { vfree(prev_snap); prev_snap = NULL; }
    vfree(framebuffer);
    kfree(fb_pages);
    if (gpio_base) iounmap(gpio_base);
    pr_info("%s by a43 — STOP\n", LCD_DRV_BUILD);
}

module_init(lcd_drv_init);
module_exit(lcd_drv_exit);
MODULE_VERSION(LCD_DRV_BUILD);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ILI9341 LCD + SX8650 Touch + PIC16 Battery for Almond 3S");
MODULE_AUTHOR("a43");
