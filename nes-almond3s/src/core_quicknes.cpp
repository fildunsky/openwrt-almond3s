/*
 * core_quicknes.cpp - подключение QuickNES к платформенному слою.
 *
 * Единственное ядро в главной ветке. Выбрано за игры с маппером MMC3 (Super
 * Mario Bros 3 и подобные): InfoNES при каждом переключении банка графики
 * перепаковывал данные в буфер размером ровно в кэш процессора и вымывал его
 * целиком, а QuickNES держит распакованными все тайлы картриджа сразу -
 * переключение банка у него это смена смещения.
 *
 * Слой рассчитан на несколько ядер и подключает их тремя функциями, так что
 * второе добавляется одним файлом; работа по InfoNES лежит в ветке InfoNES.
 */

#include "almond_platform.h"

#include "nes_emu/Nes_Emu.h"
#include "nes_emu/abstract_file.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Nes_Emu* emu;
static unsigned char vbuf[Nes_Emu::buffer_width * 242];
static unsigned short rgb_of_nes[Nes_Emu::color_table_size];  /* 512 цветов NES */
static unsigned short clut[256];                              /* палитра кадра */
static short last_pal[Nes_Emu::max_palette_size];

static int qn_load(const char *path)
{
    FILE* fp = fopen(path, "rb");
    if (!fp) { perror(path); return -1; }
    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    char* rom = (char*)malloc(len);
    if (fread(rom, 1, len, fp) != (size_t)len) { fclose(fp); return -1; }
    fclose(fp);

    emu = new Nes_Emu;
    /* Звука на плате нет, поэтому частоту не задаём вовсе - это ещё и экономит
       буферы ресемплера. */
    emu->set_palette_range(0);
    emu->set_pixels(vbuf, Nes_Emu::buffer_width);

    Mem_File_Reader rdr(rom, (int)len);
    const char* err = emu->load_ines(rdr);
    if (err) { fprintf(stderr, "quicknes: %s\n", err); return -1; }

    for (int i = 0; i < Nes_Emu::color_table_size; i++) {
        Nes_Emu::rgb_t c = Nes_Emu::nes_colors[i];
        rgb_of_nes[i] = (unsigned short)(((c.red & 0xF8) << 8) |
                                         ((c.green & 0xFC) << 3) | (c.blue >> 3));
    }
    return 0;
}

static void qn_run_frame(int pad1, int pad2)
{
    emu->emulate_frame(pad1, pad2);
}

static void qn_picture(unsigned short *dst, int stride)
{
    const Nes_Emu::frame_t& f = emu->frame();
    /* Палитра меняется по ходу кадра, но обычно стоит на месте - пересобираем
       таблицу цветов только когда она реально другая. */
    if (memcmp(last_pal, f.palette, sizeof last_pal)) {
        memcpy(last_pal, f.palette, sizeof last_pal);
        for (int i = 0; i < 256; i++)
            clut[i] = rgb_of_nes[f.palette[i] & (Nes_Emu::color_table_size - 1)];
    }
    for (int y = 0; y < NES_H; y++) {
        const unsigned char* s = f.pixels + (long)y * f.pitch;
        unsigned short* d = &dst[y * stride];
        for (int x = 0; x < NES_W; x++) d[x] = clut[s[x]];
    }
}

/* Ресемплер QuickNES отдаёт готовое моно, поэтому вся работа - задать частоту.
   22 кГц для NES на маленьком динамике более чем достаточно, а буферов
   ресемплера при этом вдвое меньше, чем на 44. */
#define QN_RATE 22050

/* Частоту ставим один раз за сеанс. Выключателя у ядра нет вовсе, а ноль сюда
   передавать нельзя: в Blip_Buffer::set_sample_rate стоит деление на неё, и
   ядро падает по SIGFPE ровно в тот момент, когда слушатель отключился. */
static int qn_rate_set;

static int qn_audio_open(void)
{
    if (!qn_rate_set) {
        const char *err = emu->set_sample_rate(QN_RATE);
        if (err) { fprintf(stderr, "quicknes: звук: %s\n", err); return 0; }
        qn_rate_set = 1;
    }
    return QN_RATE;
}

/* Буфер оставляем включённым, но платформа продолжает его вычитывать вхолостую:
   если перестать читать совсем, сэмплы копятся, и end_frame пишет за край. */
static void qn_audio_close(void)
{
}

static int qn_audio_read(short *buf, int max)
{
    return (int)emu->read_samples(buf, max);
}

static unsigned long qn_errors(void)
{
    return emu->error_count();
}

static const nes_core_t CORE = { "quicknes", qn_load, qn_run_frame, qn_picture, qn_errors,
                                qn_audio_open, qn_audio_close, qn_audio_read };

int main(int argc, char** argv)
{
    return platform_main(argc, argv, &CORE);
}
