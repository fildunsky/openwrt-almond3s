/*
 * core_infones.cpp - подключение InfoNES к платформенному слою.
 *
 * InfoNES написан так, что цикл эмуляции держит он сам и зовёт наши функции
 * обратно. Чтобы ядро укладывалось в общий вид «посчитай один кадр», в
 * InfoNES.cpp добавлен выход из цикла развёртки по флагу InfoNES_StepOut;
 * состояние там всё в глобальных переменных, поэтому следующий вызов
 * продолжает ровно с того же места.
 */

#include "almond_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "InfoNES.h"
#include "InfoNES_System.h"
#include "InfoNES_pAPU.h"

extern int InfoNES_StepOut;

static int  pad1_now, pad2_now;

/* Звук InfoNES: pAPU складывает пять каналов в байтовые буферы и раз в кадр
   зовёт InfoNES_SoundOutput. Смешиваем их в моно и кладём в кольцо, откуда
   оболочка забирает сэмплы своим темпом.
   Заодно APU_Mute: при выключенном звуке ядро всё равно считало все пять
   каналов и результат выбрасывалось - теперь эта работа просто не делается. */
extern int APU_Mute;

#define SND_RING 8192
static short snd_ring[SND_RING];
static volatile int snd_head, snd_tail;
static int snd_rate = 44100;
static int snd_live;

static int in_audio_open(void)
{
    snd_head = snd_tail = 0;
    snd_live = 1;
    APU_Mute = 0;
    return snd_rate;
}

static void in_audio_close(void)
{
    snd_live = 0;
    APU_Mute = 1;
}

static int in_audio_read(short *buf, int max)
{
    int n = 0;
    while (n < max && snd_tail != snd_head) {
        buf[n++] = snd_ring[snd_tail];
        snd_tail = (snd_tail + 1) % SND_RING;
    }
    return n;
}

/* Палитра NES в RGB555, перенесена из штатного linux-порта InfoNES
   (Apache 2.0). Ядро пишет её значения прямо в кадр. */
WORD NesPalette[64] = {
    0x39ce, 0x1071, 0x0015, 0x2013, 0x440e, 0x5402, 0x5000, 0x3c20,
    0x20a0, 0x0100, 0x0140, 0x00e2, 0x0ceb, 0x0000, 0x0000, 0x0000,
    0x5ef7, 0x01dd, 0x10fd, 0x401e, 0x5c17, 0x700b, 0x6ca0, 0x6521,
    0x45c0, 0x0240, 0x02a0, 0x0247, 0x0211, 0x0000, 0x0000, 0x0000,
    0x7fff, 0x1eff, 0x2e5f, 0x223f, 0x79ff, 0x7dd6, 0x7dcc, 0x7e67,
    0x7ae7, 0x4342, 0x2769, 0x2ff3, 0x03bb, 0x0000, 0x0000, 0x0000,
    0x7fff, 0x579f, 0x635f, 0x6b3f, 0x7f1f, 0x7f1b, 0x7ef6, 0x7f75,
    0x7f94, 0x73f4, 0x57d7, 0x5bf9, 0x4ffe, 0x0000, 0x0000, 0x0000
};

static int in_load(const char *path)
{
    /* InfoNES_Init заполняет таблицу типов строк развёртки. Раньше её вызывал
       InfoNES_Main, а мы его больше не зовём - и без неё таблица нулевая, а
       SCAN_ON_SCREEN равно единице, поэтому ни одна строка не рисовалась:
       процессор считал кадры, экран оставался чёрным. */
    InfoNES_Init();
    if (InfoNES_Load((char *)path) != 0) return -1;
    InfoNES_StepOut = 1;
    APU_Mute = 1;               /* звук включается настройкой, а не по умолчанию */
    return 0;
}

static void in_run_frame(int pad1, int pad2)
{
    pad1_now = pad1;
    pad2_now = pad2;
    InfoNES_Cycle();
}

/* InfoNES держит кадр в RGB555, панель ждёт RGB565: раздвигаем красный и
   зелёный на бит, синий совпадает. */
static void in_picture(unsigned short *dst, int stride)
{
    for (int y = 0; y < NES_H; y++) {
        WORD *s = &WorkFrame[y * NES_DISP_WIDTH];
        unsigned short *d = &dst[y * stride];
        for (int x = 0; x < NES_W; x++) {
            WORD c = s[x];
            d[x] = (unsigned short)(((c & 0x7C00) << 1) | ((c & 0x03E0) << 1) | (c & 0x001F));
        }
    }
}

static const nes_core_t CORE = { "nes", in_load, in_run_frame, in_picture, NULL,
                                in_audio_open, in_audio_close, in_audio_read };

int main(int argc, char *argv[])
{
    return platform_main(argc, argv, &CORE);
}

/* ---- обратные вызовы, которых ждёт InfoNES ---- */

void InfoNES_PadState(DWORD *pdwPad1, DWORD *pdwPad2, DWORD *pdwSystem)
{
    *pdwPad1   = (DWORD)pad1_now;
    *pdwPad2   = (DWORD)pad2_now;
    *pdwSystem = 0;                 /* выход держит платформенный слой */
}

/* Кадр забирает слой сам, здесь делать нечего: это лишь точка, где ядро
   объявляет кадр готовым. */
void InfoNES_LoadFrame(void) {}

/* ВНИМАНИЕ: InfoNES зовёт это на КАЖДОЙ строке развёртки (HSYNC), а не раз в
   кадр - строк 262 на кадр. Спать здесь нельзя: кадр собирался бы секундами.
   Темп кадров держит платформенный слой. */
void InfoNES_Wait(void) {}

int InfoNES_ReadRom(const char *pszFileName)
{
    FILE *fp = fopen(pszFileName, "rb");
    if (!fp) return -1;

    if (fread(&NesHeader, sizeof NesHeader, 1, fp) != 1 ||
        memcmp(NesHeader.byID, "NES\x1a", 4) != 0) {
        fclose(fp);
        return -1;
    }
    memset(SRAM, 0, SRAM_SIZE);
    if (NesHeader.byInfo1 & 4)                     /* тренер, если есть */
        fread(&SRAM[0x1000], 512, 1, fp);

    ROM = (BYTE *)malloc(NesHeader.byRomSize * 0x4000);
    fread(ROM, 0x4000, NesHeader.byRomSize, fp);

    if (NesHeader.byVRomSize > 0) {
        VROM = (BYTE *)malloc(NesHeader.byVRomSize * 0x2000);
        fread(VROM, 0x2000, NesHeader.byVRomSize, fp);
    }
    fclose(fp);
    return 0;
}

void InfoNES_ReleaseRom(void)
{
    if (ROM)  { free(ROM);  ROM = NULL; }
    if (VROM) { free(VROM); VROM = NULL; }
}

void *InfoNES_MemoryCopy(void *dest, const void *src, int count) { return memcpy(dest, src, count); }
void *InfoNES_MemorySet(void *dest, int c, int count)            { return memset(dest, c, count); }

void InfoNES_DebugPrint(char *pszMsg) { fprintf(stderr, "%s\n", pszMsg); }

void InfoNES_MessageBox(char *pszMsg, ...)
{
    va_list ap;
    va_start(ap, pszMsg);
    vfprintf(stderr, pszMsg, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

/* Звука нет: динамик у платы висит на PIC, а не на звуковой шине. */
void InfoNES_SoundInit(void) {}

int InfoNES_SoundOpen(int samples_per_sync, int sample_rate)
{
    (void)samples_per_sync;
    if (sample_rate > 0) snd_rate = sample_rate;
    return 1;
}

void InfoNES_SoundClose(void) {}

/* Каналы приходят беззнаковыми амплитудами от нуля, поэтому сумму сдвигаем
   к середине и растягиваем до 16 бит с запасом от перегрузки. */
void InfoNES_SoundOutput(int samples, BYTE *w1, BYTE *w2, BYTE *w3, BYTE *w4, BYTE *w5)
{
    if (!snd_live) return;
    for (int i = 0; i < samples; i++) {
        int mix = ((int)w1[i] + w2[i] + w3[i] + w4[i] + w5[i] - 320) * 48;
        if (mix >  32767) mix =  32767;
        if (mix < -32768) mix = -32768;
        int nx = (snd_head + 1) % SND_RING;
        if (nx == snd_tail) return;          /* оболочка не успевает - молчим */
        snd_ring[snd_head] = (short)mix;
        snd_head = nx;
    }
}

int InfoNES_Menu(void) { return 0; }
