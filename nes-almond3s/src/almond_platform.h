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

#define LCD_W 320
#define LCD_H 240
#define NES_W 256
#define NES_H 240

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
