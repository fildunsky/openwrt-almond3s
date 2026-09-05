/*
 * almond_platform.h - оболочка игр для Almond 3S, общая для всех ядер.
 *
 * Всё, что не относится к эмуляции NES, живёт в платформенном слое: вывод на
 * панель, экранные кнопки, тачскрин, клавиатура, сетевой джойстик, настройки
 * из /etc/almond3s и темп кадров. Ядро подключается тремя функциями и о
 * железе не знает ничего.
 */

#ifndef ALMOND_PLATFORM_H
#define ALMOND_PLATFORM_H

/* Размер панели можно задать сборкой (-DLCD_W/-DLCD_H): Almond 3S = 320x240,
   Almond+ = нативные 480x320. Эмулятор пишет кадр целиком в /dev/lcd, поэтому
   размер ДОЛЖЕН совпадать с нативным, иначе драйвер не выводит кадр. */
#ifndef LCD_W
#define LCD_W 320
#endif
#ifndef LCD_H
#define LCD_H 240
#endif
#define NES_W 256
#define NES_H 240
/* Игровое окно вписываем по ВЫСОТЕ панели (сохраняя пропорции 256:240), картинку
   масштабируем ближайшим соседом и ставим по центру. На 3S GAME_H=240=NES_H -
   масштаб 1:1, поведение прежнее. На Almond+ (320) окно 341x320, поля под кнопки. */
#define GAME_H LCD_H
#define GAME_W (NES_W * GAME_H / NES_H)
#define GX_OFF ((LCD_W - GAME_W) / 2)
#define GY_OFF ((LCD_H - GAME_H) / 2)
/* Совместимость со старым кодом (1:1 путь на 3S). */
#define Y_OFF GY_OFF

/* Биты джойстика NES в порядке, принятом в оболочке. */
#define P_A      0x01
#define P_B      0x02
#define P_SELECT 0x04
#define P_START  0x08
#define P_UP     0x10
#define P_DOWN   0x20
#define P_LEFT   0x40
#define P_RIGHT  0x80

typedef struct {
    const char *name;

    /* Загрузить картридж. 0 - получилось. */
    int (*load)(const char *path);

    /* Посчитать один кадр с этим состоянием джойстиков. */
    void (*run_frame)(int pad1, int pad2);

    /* Отдать картинку: NES_W x NES_H в RGB565 по адресу dst, между строками
       stride пикселей. Формат кадра у ядер разный (индексы палитры, RGB555),
       поэтому перевод делает само ядро - слою всё равно, чем оно внутри. */
    void (*picture)(unsigned short *dst, int stride);

    /* Ошибки опкодов для строки статистики; может быть NULL. */
    unsigned long (*errors)(void);

    /* Звук. Всё три поля могут быть NULL - тогда ядро молчит и оболочка
       выключатель просто не показывает в деле. audio_open возвращает
       частоту, на которой ядро готово отдавать моно-сэмплы, или 0. */
    int  (*audio_open)(void);
    void (*audio_close)(void);
    int  (*audio_read)(short *buf, int max);
} nes_core_t;

int platform_main(int argc, char **argv, const nes_core_t *core);

#endif
