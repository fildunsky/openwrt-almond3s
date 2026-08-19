/*
 * collector — сборщик данных для экрана Almond 3S
 *
 * Background daemon: collects LTE/WiFi/VPN/Battery/System stats.
 * Pushes JSON to connected clients via unix socket /tmp/lcd_data.sock every 2s.
 * Also writes /tmp/lcd_data.json for compatibility.
 *
 * Компиляция вручную: zig cc -target mipsel-linux-musleabi -Os -static -o collector collector.c
 */

#define VERSION "V260401"
#define MODNAME "almond3s-collector"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <sys/sysinfo.h>
#include <sys/statvfs.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

#define SOCK_PATH  "/tmp/lcd_data.sock"
#define JSON_PATH  "/tmp/lcd_data.json"
#define INTERVAL   2
#define MAX_CLIENTS 4
#define JSON_BUF   8192

static volatile int running = 1;
static int clients[MAX_CLIENTS];
static int client_count = 0;

static void sig_handler(int sig) { (void)sig; running = 0; }

static int bat_table_lookup(int adc);      /* forward decl, defined below */
static int charge_table_lookup(int adc);   /* то же для таблицы заряда */

/* ======== PIC Battery ======== */
struct battery_info {
    int adc, percent, charging, valid, no_battery, full;
    unsigned char raw1, raw2;  /* buf[1], buf[2] for hex display */
};

/* Состояние между замерами: скачок напряжения от зарядного, последний
 * показанный процент и счётчик подряд идущих «нет батареи». */
static int bat_adc_before_charge = 0;
static int bat_charge_bump = 0;
static int bat_last_charging = -1;
static int bat_disp_percent = -1;
/* Сглаживание стыка разряд->заряд: запомненный разрыв таблиц в момент
 * подключения и процент старта заряда, по которому разрыв сводится к нулю. */
static int bat_charge_offset = 0;
static int bat_charge_start_pct = 0;
static int bat_nobat_count = 0;
static int bat_adc_filt = 0;   /* сглаженный АЦП, восьмикратно */
/* Плато на зарядке. Потолок 726 - свойство конкретной батареи: у другой он
 * может быть 728, у постаревшей - 720, и по одной лишь таблице такая батарея
 * заряжалась бы «вечно». Поэтому завершение определяем ещё и по факту: если
 * под кабелем значение долго не растёт и мы уже в верхней части шкалы -
 * батарея взяла всё, что может. */
#define BAT_PLATEAU_TICKS 300  /* ~10 мин без роста при опросе раз в 2 с */
#define BAT_PLATEAU_MIN   690  /* плато ниже - неисправность, а не полный заряд */
static int bat_plateau_max = 0;
static int bat_plateau_ticks = 0;
/* Защёлка «заряд завершён» по семантике BQ24133: у полной батареи STAT
 * гаснет, а короткие включения после - recharge-подкачки у порога 8.2В
 * (~709 АЦП), не новый цикл заряда. Дебаунс минутные качели не победит
 * принципиально - только защёлка. */
static int bat_full_latch = 0;
static int bat_full_low = 0;
static int bat_full_quiet = 0;  /* тики без recharge-импульсов под защёлкой */
static int bat_cycle_cd = 0;    /* тики до права на новую запись в журнал циклов */
static struct battery_info bat_last_good;
static int bat_have_good = 0;

/* Загрузка процессора считается по приращению /proc/stat между замерами:
 * мгновенного значения там нет, только счётчики от загрузки. */
/* Оверлей и LAN: статичные вещи, но именно их негде было увидеть. */
static void get_overlay(long *free_kb, long *total_kb)
{
    struct statvfs v;
    *free_kb = 0; *total_kb = 0;
    if (statvfs("/overlay", &v) == 0) {
        *free_kb  = (long)((long long)v.f_bavail * v.f_frsize / 1024);
        *total_kb = (long)((long long)v.f_blocks * v.f_frsize / 1024);
    }
}

static void get_lan(char *ip, size_t ip_sz, char *mac, size_t mac_sz)
{
    struct ifaddrs *ifa0 = NULL, *ifa;
    ip[0] = 0; mac[0] = 0;
    if (getifaddrs(&ifa0) == 0) {
        for (ifa = ifa0; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (strcmp(ifa->ifa_name, "br-lan") != 0) continue;
            inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr,
                      ip, ip_sz);
            break;
        }
        freeifaddrs(ifa0);
    }
    FILE *f = fopen("/sys/class/net/br-lan/address", "r");
    if (f) {
        if (fgets(mac, mac_sz, f)) {
            char *nl = strchr(mac, 0x0a);
            if (nl) *nl = 0;
        }
        fclose(f);
    }
}

static int cpu_busy_pct(void)
{
    static unsigned long long prev_idle, prev_total;
    unsigned long long v[8] = {0}, idle, total = 0;
    FILE *fp = fopen("/proc/stat", "r");
    if (!fp) return -1;
    if (fscanf(fp, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
               &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) < 4) {
        fclose(fp);
        return -1;
    }
    fclose(fp);
    for (int i = 0; i < 8; i++) total += v[i];
    idle = v[3] + v[4];
    int pct = -1;
    if (prev_total && total > prev_total) {
        unsigned long long dt = total - prev_total;
        unsigned long long di = idle - prev_idle;
        pct = (int)((dt - di) * 100 / dt);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
    }
    prev_idle = idle;
    prev_total = total;
    return pct;
}

static int cpu_core_busy(int *out, int max)
{
    static unsigned long long pidle[8], ptotal[8];
    FILE *fp = fopen("/proc/stat", "r");
    char line[256];
    int n = 0;
    if (!fp) return 0;
    while (n < max && fgets(line, sizeof line, fp)) {
        unsigned long long v[8] = {0}, total = 0, idle;
        int idx, pct = -1;
        if (sscanf(line, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu", &idx,
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) < 5)
            continue;
        if (idx < 0 || idx >= 8) continue;
        for (int i = 0; i < 8; i++) total += v[i];
        idle = v[3] + v[4];
        if (ptotal[idx] && total > ptotal[idx]) {
            unsigned long long dt = total - ptotal[idx];
            unsigned long long di = idle - pidle[idx];
            pct = (int)((dt - di) * 100 / dt);
            if (pct < 0) pct = 0;
            if (pct > 100) pct = 100;
        }
        pidle[idx] = idle;
        ptotal[idx] = total;
        out[n++] = pct;
    }
    fclose(fp);
    return n;
}

static int cpu_core_count(void)
{
    static int n = 0;
    if (n) return n;
    FILE *fp = fopen("/proc/cpuinfo", "r");
    char line[128];
    if (!fp) return 1;
    while (fgets(line, sizeof(line), fp))
        if (strncmp(line, "processor", 9) == 0) n++;
    fclose(fp);
    if (n < 1) n = 1;
    return n;
}

static void get_battery(struct battery_info *bi) {
    unsigned char raw[17] = {0};
    bi->adc = 0; bi->percent = 0; bi->charging = 0; bi->valid = 0; bi->no_battery = 0; bi->full = 0; bi->raw1 = 0; bi->raw2 = 0;
    int fd = open("/dev/lcd", O_RDWR);
    if (fd < 0) return;
    int ret = ioctl(fd, 2, raw);
    if (ret == 0 && raw[4] == 0x04 && (((raw[3] & 0x0F) << 8) | raw[1]) < 1023) {
        /* Как в заводском драйвере: АЦП это байт 1 плюс младший полубайт
         * байта 3, то есть 12 бит. Прежняя формула (raw[1] << 2 | raw[2] >> 6)
         * подмешивала в число байт статуса и заворачивалась при выходе за
         * окно 512..767. */
        bi->adc = ((raw[3] & 0x0F) << 8) | raw[1];
        bi->raw1 = raw[1]; bi->raw2 = raw[3];
        bi->charging = (raw[5] & 0x01) ? 1 : 0;
        bi->no_battery = ((raw[5] & 0x40) && !(raw[5] & 0x20)) ? 1 : 0;
        bi->valid = 1;

        /* Зарядное поднимает напряжение на клеммах, и процент по нему
         * мгновенно прыгает вверх. Запоминаем величину скачка в момент
         * подключения и вычитаем её, пока идёт зарядка. */
        if (bi->charging && bat_last_charging == 0 && bat_adc_before_charge > 0) {
            int bump = bi->adc - bat_adc_before_charge;
            if (bump > 0 && bump < 120) bat_charge_bump = bump;
        }
        if (!bi->charging) {
            bat_adc_before_charge = bi->adc;
            bat_charge_bump = 0;
        }
        /* Флаг зарядки от PIC иногда дребезжит (замер 14.08: минутные
         * качели 0-1 на живой зарядке). Каждая ложная смена режима
         * переключала таблицу процентов и пересеивала фильтр - на экране
         * качало 46-41-49, а в журнал циклов сыпался мусор. Смену режима
         * засчитываем после трёх одинаковых чтений подряд. */
        {
            static int chg_pending = -1, chg_streak = 0;
            if (bat_last_charging != -1 && bi->charging != bat_last_charging) {
                if (chg_pending == bi->charging) chg_streak++;
                else { chg_pending = bi->charging; chg_streak = 1; }
                if (chg_streak < 3)
                    bi->charging = bat_last_charging;
            } else {
                chg_pending = -1;
                chg_streak = 0;
            }
        }


        /* Сглаживаем сам АЦП: шкала такая, что одна единица это около
         * процента, а показания дрожат на единицу-две - отсюда скачки
         * «26 -> 25 -> 27» на ровном месте. Но через смену режима фильтр
         * НЕ тянем: скачок от зарядного - не шум, и размазывание его на
         * полминуты давало и «71% при подключении», и «97 через миг после
         * выдёргивания» (замер перехода 14.08.2026). */
        if (bat_adc_filt <= 0) bat_adc_filt = bi->adc * 8;
        if (bat_last_charging != -1 && bat_last_charging != bi->charging)
            bat_adc_filt = bi->adc * 8;
        bat_adc_filt = bat_adc_filt - bat_adc_filt / 8 + bi->adc;
        int adc_sm = bat_adc_filt / 8;

        int adc_eff = adc_sm - (bi->charging ? bat_charge_bump : 0);

        /* Отдельного бита «адаптер воткнут» у PIC нет (бит 3 оказался
         * событийным снимком - живой замер 15.08: 0x01 при воткнутом
         * кабеле), а по напряжению отдыхающая полная батарея (~709) и
         * полная под адаптером неразличимы. Поэтому:
         *  - ставим защёлку по ПЕРЕХОДУ заряд->стоп на высоком АЦП
         *    (терминация BQ24133);
         *  - каждый recharge-импульс её продлевает - под адаптером они
         *    идут с периодом в минуты;
         *  - их исчезновение на 20 минут = кабель выдернут (эти 20 минут
         *    отдохнувшая батарея и правда ~100%, ошибка ограничена);
         *  - просадка АЦП ниже 700 снимает защёлку немедленно. */
        {
            if (bat_last_charging == 1 && !bi->charging && adc_sm >= 706) {
                bat_full_latch = 1;
                bat_full_low = 0;
                bat_full_quiet = 0;
            }
            if (bat_full_latch) {
                if (bi->charging)
                    bat_full_quiet = 0;
                else if (++bat_full_quiet >= 600) {
                    bat_full_latch = 0;
                    bat_full_quiet = 0;
                }
                if (adc_sm < 700) {
                    if (++bat_full_low >= 5) {
                        bat_full_latch = 0;
                        bat_full_low = 0;
                    }
                } else {
                    bat_full_low = 0;
                }
                if (bi->no_battery)
                    bat_full_latch = 0;
            }
        }

        int plateau_full = 0;
        if (bi->charging) {
            /* Считаем тики, а не время: у роутера нет RTC, и настенные часы
             * после загрузки скачут. Рост АЦП обнуляет счётчик. */
            if (adc_sm > bat_plateau_max) {
                bat_plateau_max = adc_sm;
                bat_plateau_ticks = 0;
            } else {
                bat_plateau_ticks++;
                if (adc_sm >= BAT_PLATEAU_MIN && bat_plateau_ticks > BAT_PLATEAU_TICKS)
                    plateau_full = 1;
            }
        } else {
            bat_plateau_max = 0;
            bat_plateau_ticks = 0;
        }

        /* При зарядке считаем по таблице заряда: она снята на живой зарядке
         * (полными циклами двух банок), а таблица разряда там врёт - напряжение
         * на клеммах поднято током.
         *
         * На самом СТЫКЕ обе таблицы честны, но расходятся (зарядное приподняло
         * напряжение), и процент прыгал. Не фейк-рамп, а сведение реального
         * разрыва: в момент подключения запоминаем разницу «заряд минус то, что
         * показывали» (offset) и вычитаем её из кривой заряда, ЛИНЕЙНО сводя к
         * нулю по мере зарядки. Показания стартуют с последнего процента разряда
         * и идут ФОРМОЙ реальной кривой заряда, сходясь к 100. */
        int target;
        if (bi->charging) {
            int raw = 100 - charge_table_lookup(adc_eff) * 100 / 155;
            if (raw < 0) raw = 0;
            if (raw > 100) raw = 100;
            if (bat_last_charging == 0) {          /* первый тик зарядки */
                bat_charge_start_pct = raw;
                bat_charge_offset = (bat_disp_percent >= 0) ? (raw - bat_disp_percent) : 0;
                if (bat_charge_offset > 25) bat_charge_offset = 25;
                if (bat_charge_offset < -25) bat_charge_offset = -25;
            }
            int span = 100 - bat_charge_start_pct;
            int off = (span > 0) ? bat_charge_offset * (100 - raw) / span : 0;
            target = raw - off;
        } else {
            target = bat_table_lookup(adc_eff) * 100 / 262;
            bat_charge_offset = 0;
        }
        if (plateau_full) target = 100;
        if (target > 100) target = 100;
        if (target < 0) target = 0;

        /* Показания двигаем плавно и с направленным гистерезисом: в
         * ожидаемую сторону (вверх на зарядке, вниз на разряде) реагируем
         * сразу, в неожиданную - только при расхождении от 3%, иначе
         * дрожание АЦП на ±1 превращалось в храповик: за полчаса покоя
         * процент «стекал» 98 -> 86, ведь каждый провал засчитывался, а
         * каждый возврат блокировался прежним односторонним правилом. */
        if (bat_disp_percent < 0) {
            bat_disp_percent = target;
        } else {
            int diff = target - bat_disp_percent;
            int expected_up = bi->charging;
            if (diff > 0 && (expected_up || diff >= 3))
                bat_disp_percent += (diff > 10) ? 2 : 1;
            else if (diff < 0 && (!expected_up || diff <= -3))
                bat_disp_percent -= (diff < -10) ? 2 : 1;
        }
        bi->percent = bat_disp_percent;

        /* Начало зарядки - строка в журнал циклов: страница «Батарея»
         * показывает их счёт, а со временем по журналу посчитаем износ.
         * ЦИКЛ - это не любой подъём флага (журнал за 14.08 набрал 30
         * строк из ОДНОЙ реальной зарядки на дребезге и подкачках), а
         * старт заряда заметно разряженной батареи: АЦП ниже ~700 (≈90%),
         * не под защёлкой FULL и не раньше получаса от прошлой записи
         * (кулдаун тиками - настенным часам без RTC веры нет). */
        if (bat_cycle_cd > 0) bat_cycle_cd--;
        if (bat_last_charging == 0 && bi->charging && !bat_full_latch
            && adc_sm < 700 && bat_cycle_cd == 0) {
            FILE *cf = fopen("/etc/almond3s/charge_events", "a");
            if (cf) { fprintf(cf, "%ld\n", (long)time(NULL)); fclose(cf); }
            bat_cycle_cd = 900;
        }
        bat_last_charging = bi->charging;

        /* Публикация поверх защёлки: процент 100 намертво, подкачки
         * наружу не показываем - именно их мигание анимацией зарядки и
         * скачки процентов раздражали на почти полной батарее. Внутренняя
         * механика (bump, журнал, фильтр) выше работала с настоящим
         * флагом. */
        if (bat_full_latch) {
            bat_disp_percent = 100;
            bi->percent = 100;
            bi->charging = 0;
            bi->full = 1;
        }

        /* История для графиков страницы «Батарея»: точка в минуту в файл,
         * последние два часа. Живёт в /tmp у КОЛЛЕКТОРА, а не в памяти
         * интерфейса: рестарты UI и обновления пакета её не стирают -
         * страница показывает кривую сразу, а не копит её на глазах. */
        {
            static int hist_ticks = 0;
            hist_ticks++;
            if (hist_ticks >= 30) {
                hist_ticks = 0;
                FILE *hf = fopen("/tmp/almond3s_bat_hist", "a");
                if (hf) {
                    fprintf(hf, "%d %d %d\n", bi->adc, bi->percent,
                            bi->charging ? 1 : 0);
                    fclose(hf);
                }
                /* Подрезаем разросшийся файл до последних 120 строк. */
                hf = fopen("/tmp/almond3s_bat_hist", "r");
                if (hf) {
                    char lines[240][24];
                    int n = 0;
                    while (n < 240 && fgets(lines[n], 24, hf)) n++;
                    fclose(hf);
                    if (n >= 240) {
                        FILE *wf = fopen("/tmp/almond3s_bat_hist.new", "w");
                        if (wf) {
                            for (int i = n - 120; i < n; i++)
                                fputs(lines[i], wf);
                            fclose(wf);
                            rename("/tmp/almond3s_bat_hist.new",
                                   "/tmp/almond3s_bat_hist");
                        }
                    }
                }
            }
        }
    }

    /* «Нет батареи» верим только после пяти подряд, иначе кратковременная
     * смена статуса при подключении зарядного рисует прочерки. */
    if (bi->no_battery) {
        if (++bat_nobat_count < 5) bi->no_battery = 0;
    } else {
        bat_nobat_count = 0;
    }

    /* Сбойную выборку не показываем как пустоту - держим последнюю годную. */
    if (bi->valid) {
        bat_last_good = *bi;
        bat_have_good = 1;
    } else if (bat_have_good) {
        int keep_nobat = bi->no_battery;
        *bi = bat_last_good;
        bi->no_battery = keep_nobat;
    } else {
        /* Первые секунды после запуска: PIC ещё не опрошен, показывать нечего.
         * Ноль процентов тут выглядел бы как разряженная батарея. */
        bi->percent = -1;
    }
    close(fd);
}

/* ======== Battery Time Estimation ======== */
#define BAT_HIST_MAX 30
#define BAT_CAL_PATH "/etc/almond3s/bat_cal"

struct bat_sample { time_t t; int adc; };

struct bat_estimator {
    struct bat_sample hist[BAT_HIST_MAX];
    int count, head;
    int remain_min;     /* -1=unknown, 0=dead, >0=minutes */
    int drain_rate;     /* ADC/min * 100 (fixed-point) */
    int was_charging;
};

static struct bat_estimator bat_est = {0};

static int bat_cal_cutoff = 512;   /* измерено: на этом значении роутер выключается */
static int bat_cal_factor = 100;    /* *100 fixed-point (100 = 1.0x) */
static int bat_cal_hist_size = 20;
static int bat_cal_interval = 30;   /* seconds between samples */

static void bat_cal_load(void) {
    FILE *fp = fopen(BAT_CAL_PATH, "r");
    if (!fp) return;
    char line[64];
    while (fgets(line, sizeof(line), fp)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        int val = atoi(eq + 1);
        if (strcmp(line, "cutoff_adc") == 0)   bat_cal_cutoff = val;
        else if (strcmp(line, "time_factor") == 0)  bat_cal_factor = val;
        else if (strcmp(line, "hist_size") == 0)    { bat_cal_hist_size = val; if (val > BAT_HIST_MAX) bat_cal_hist_size = BAT_HIST_MAX; if (bat_cal_hist_size < 1) bat_cal_hist_size = 1; }
        else if (strcmp(line, "min_interval") == 0) bat_cal_interval = val;
    }
    fclose(fp);
}

static void bat_hist_clear(struct bat_estimator *e) { e->count = 0; e->head = 0; }

static void bat_hist_push(struct bat_estimator *e, time_t t, int adc) {
    e->hist[e->head].t = t;
    e->hist[e->head].adc = adc;
    e->head = (e->head + 1) % bat_cal_hist_size;
    if (e->count < bat_cal_hist_size) e->count++;
}

/* ADC → минуты до выключения. Снято на полном разряде этого роутера
 * 13.08.2026: от 713 до 512 он прожил 263 минуты. Отсечка 512 - это
 * измеренное значение, при нём срабатывает защита элемента (~3.0 В).
 * Прежняя таблица считала нулём 612, то есть четверть времени работы
 * числилась разряженной батареей. */
static const struct { int adc; int min; } bat_table[] = {
    { 714,  262}, { 700,  242}, { 697,  229}, { 688,  210}, { 679,  196},
    { 667,  179}, { 659,  162}, { 650,  147}, { 638,  130}, { 628,  113},
    { 621,   98}, { 612,   79}, { 608,   65}, { 598,   47}, { 586,   31},
    { 573,   16}, { 512,    0},
};
#define BAT_TABLE_SIZE 17

static int bat_table_lookup(int adc) {
    if (adc >= 714) return 262;
    if (adc <= 512) return 0;
    for (int i = 0; i < BAT_TABLE_SIZE - 1; i++) {
        if (adc >= bat_table[i + 1].adc) {
            int da = bat_table[i].adc - bat_table[i + 1].adc;
            int dm = bat_table[i].min - bat_table[i + 1].min;
            return bat_table[i + 1].min + (adc - bat_table[i + 1].adc) * dm / da;
        }
    }
    return 0;
}

static void bat_calc_slope(struct bat_estimator *e, int *slope_x1000) {
    int n = e->count;
    int oldest = (e->head - n + bat_cal_hist_size) % bat_cal_hist_size;
    long long t0 = (long long)e->hist[oldest].t;
    long long sum_t = 0, sum_a = 0, sum_tt = 0, sum_ta = 0;
    for (int i = 0; i < n; i++) {
        int idx = (oldest + i) % bat_cal_hist_size;
        long long t = (long long)e->hist[idx].t - t0;
        long long a = (long long)e->hist[idx].adc;
        sum_t += t; sum_a += a; sum_tt += t * t; sum_ta += t * a;
    }
    long long denom = (long long)n * sum_tt - sum_t * sum_t;
    if (denom == 0) { *slope_x1000 = 0; return; }
    long long numer = (long long)n * sum_ta - sum_t * sum_a;
    *slope_x1000 = (int)(numer * 1000 / denom);
}

/* Discharge: table-only (no correction — see ALGO 5.3) */
static void bat_estimate(struct bat_estimator *e, int cur_adc) {
    int tab_min = bat_table_lookup(cur_adc);

    if (e->count >= 3) {
        int slope_x1000;
        bat_calc_slope(e, &slope_x1000);
        if (slope_x1000 >= 0) {
            e->remain_min = -1;  /* not discharging */
            e->drain_rate = 0;
            return;
        }
        e->drain_rate = (int)(-(long long)slope_x1000 * 60 / 10);
    } else {
        e->drain_rate = 0;
    }

    /* Если история набралась, считаем по измеренной скорости разряда, а не
     * по таблице: расход зависит от нагрузки (с погашенным экраном роутер
     * живёт заметно дольше), и статическая кривая тут врёт в разы.
     * drain_rate - это сотые доли АЦП в минуту. */
    if (e->count >= 5 && e->drain_rate > 0) {
        int left = cur_adc - bat_cal_cutoff;
        if (left <= 0) {
            e->remain_min = 0;
        } else {
            long long m = (long long)left * 100 / e->drain_rate;
            if (m > 24 * 60) m = 24 * 60;
            e->remain_min = (int)m;
        }
        return;
    }

    e->remain_min = (int)((long long)tab_min * bat_cal_factor / 100);
    if (e->remain_min < 0) e->remain_min = 0;
}

/* ADC → минуты до полного заряда. Кривая ИЗМЕРЕНА 14.08.2026 двумя
 * полными циклами на двух банках (совпали с точностью до пары минут):
 * низ 573-720 - банка 1 от отсечки, верх 626-726 - банка 2 до плато.
 * Первые минуты заряд летит (573-612 за десять минут), потом плавно
 * замедляется. Итого ~155 минут от отсечки. */
static const struct { int adc; int min; } charge_table[] = {
    { 512, 155}, { 573, 150}, { 612, 140}, { 621, 130}, { 630, 120},
    { 636, 110}, { 641, 100}, { 647,  90}, { 654,  80}, { 661,  70},
    { 671,  60}, { 681,  50}, { 690,  40}, { 699,  30}, { 709,  20},
    { 720,  10}, { 726,   0},
};
#define CHARGE_TABLE_SIZE 17

static int charge_table_lookup(int adc) {
    if (adc <= 512) return 155;
    if (adc >= 726) return 0;
    for (int i = 0; i < CHARGE_TABLE_SIZE - 1; i++) {
        if (adc < charge_table[i + 1].adc) {
            int da = charge_table[i + 1].adc - charge_table[i].adc;
            int dm = charge_table[i].min - charge_table[i + 1].min;
            return charge_table[i + 1].min + (charge_table[i + 1].adc - adc) * dm / da;
        }
    }
    return 0;
}

/* Charge: table + linreg for rate */
static void bat_charge_estimate(struct bat_estimator *e, int cur_adc) {
    int tab_min = charge_table_lookup(cur_adc);

    if (e->count >= 3) {
        int slope_x1000;
        bat_calc_slope(e, &slope_x1000);
        if (slope_x1000 <= 0) {
            e->remain_min = -1;
            e->drain_rate = 0;
            return;
        }
        e->drain_rate = (int)((long long)slope_x1000 * 60 / 10);
    } else {
        e->drain_rate = 0;
    }

    if (cur_adc <= 512) { e->remain_min = -1; return; }  /* CC phase, unpredictable */
    if (cur_adc >= 724) { e->remain_min = 0; return; }   /* almost full */

    e->remain_min = tab_min * bat_cal_factor / 100;
}

static void bat_update(struct bat_estimator *e, struct battery_info *bi) {
    if (!bi->valid) { e->remain_min = -1; return; }

    /* Полная под адаптером: ни «до полного», ни «разрядится за» не имеют
     * смысла - и копить псевдоразрядную историю по подкачкам не надо. */
    if (bi->full) { e->remain_min = 0; return; }

    if (bi->charging) {
        /* Charging: collect points and estimate time to full */
        if (!e->was_charging) {
            bat_hist_clear(e);
            e->was_charging = 1;
        }
        time_t now = time(NULL);
        if (e->count > 0) {
            int last = (e->head - 1 + bat_cal_hist_size) % bat_cal_hist_size;
            if ((now - e->hist[last].t) < bat_cal_interval)
                goto calc_charge;
        }
        bat_hist_push(e, now, bi->adc);
    calc_charge:
        bat_charge_estimate(e, bi->adc);
        return;
    }

    /* Discharging */
    if (e->was_charging) {
        bat_hist_clear(e);
        e->was_charging = 0;
    }

    if (bi->adc < 515) { e->remain_min = 0; return; }

    time_t now = time(NULL);
    if (e->count > 0) {
        int last = (e->head - 1 + bat_cal_hist_size) % bat_cal_hist_size;
        if ((now - e->hist[last].t) < bat_cal_interval)
            goto calc_discharge;
    }
    bat_hist_push(e, now, bi->adc);
calc_discharge:
    bat_estimate(e, bi->adc);
}

/* ======== Shell helpers ======== */
static int run_cmd(const char *cmd, char *buf, int bufsz) {
    FILE *fp = popen(cmd, "r");
    if (!fp) { buf[0] = 0; return -1; }
    if (!fgets(buf, bufsz, fp)) buf[0] = 0;
    pclose(fp);
    char *nl = strchr(buf, '\n');
    if (nl) *nl = 0;
    return 0;
}

static int run_cmd_all(const char *cmd, char *buf, int bufsz) {
    FILE *fp = popen(cmd, "r");
    if (!fp) { buf[0] = 0; return -1; }
    int total = 0;
    while (total < bufsz - 1) {
        int n = fread(buf + total, 1, bufsz - 1 - total, fp);
        if (n <= 0) break;
        total += n;
    }
    buf[total] = 0;
    pclose(fp);
    return total;
}

/* ======== LTE ======== */
struct lte_info {
    int csq, ber, rsrp, rsrq, sinr, rssi, pci, earfcn;
    char oper[32], band[32], mode[16];
    char modem[40], ip[48];
    int temp;
    int signal_pct, therm, simslot, roaming, nca;
    int cid, enbid, mcc, mnc, reg;
    char conn_time[24], rx[16], tx[16], apn[32], fw[24], phone[24];
    /* Информация о соте - как на одноимённой странице 5gmodem. */
    char lac[24], tac[24], cid_hex[24], bandwidth[24], pathloss[16], txpower[16];
    char cqi[16], uecat[16], volte[16], mimo[16], rxdiv[16], antports[64];
    char s1band[24], s2band[24], s3band[24];
    int s1pci, s2pci, s3pci, s1earfcn, s2earfcn, s3earfcn;
    char neighbors[1024];  /* готовый JSON-массив соседних сот от 5gmodem */
};

/* ======== LTE via luci-app-5gmodem ======== */
#define M5G_SH      "/usr/share/5gmodem/5gmodem.sh"
#define M5G_PERIOD  10
/* 8.8.8.8 в России часто недоступен, и каждый цикл упирался в полный таймаут
   -W2. Яндексовский резолвер отвечает всегда, проверка связности от этого не
   хуже. Внешний IP меняется редко - незачем ходить за ним каждый круг. */
#define PING_HOST   "77.88.8.8"
#define EXTIP_PERIOD 60
#define M5G_BUF     8192

static int m5g_str(const char *json, const char *key, char *out, int outlen) {
    char pat[64];
    const char *p, *q;
    int n;

    out[0] = 0;
    snprintf(pat, sizeof(pat), "\"%s\":\"", key);
    p = strstr(json, pat);
    if (!p) return 0;
    p += strlen(pat);
    q = strchr(p, '"');
    if (!q) return 0;
    n = q - p;
    if (n >= outlen) n = outlen - 1;
    memcpy(out, p, n);
    out[n] = 0;
    if (strcmp(out, "-") == 0) out[0] = 0;
    return out[0] ? 1 : 0;
}

static int m5g_int(const char *json, const char *key) {
    char buf[32];
    if (!m5g_str(json, key, buf, sizeof(buf))) return 0;
    return atoi(buf);
}

static void m5g_bands(const char *mode, char *out, int outlen) {
    const char *p = strstr(mode, " | ");
    int o = 0;

    out[0] = 0;
    if (!p) return;
    p += 3;
    while (*p && o < outlen - 1) {
        if (*p == 'B' && p[1] >= '0' && p[1] <= '9') {
            if (o) out[o++] = '+';
            while (*p && *p != ' ' && o < outlen - 1) out[o++] = *p++;
            continue;
        }
        p++;
    }
    out[o] = 0;
}

static int get_lte_from_5gmodem(struct lte_info *li) {
    static char buf[M5G_BUF];
    char mode[128], tmp[64];
    const char *nb;
    char *sep;

    memset(li, 0, sizeof(*li));

    if (run_cmd_all(M5G_SH " cached 10 2>/dev/null", buf, sizeof(buf)) <= 0)
        return 0;
    if (!strstr(buf, "\"csq\""))
        return 0;

    m5g_str(buf, "operator_name", li->oper, sizeof(li->oper));
    m5g_str(buf, "modem", li->modem, sizeof(li->modem));
    m5g_str(buf, "ipaddr", li->ip, sizeof(li->ip));

    li->csq  = m5g_int(buf, "csq");
    li->rsrp = m5g_int(buf, "rsrp");
    li->rsrq = m5g_int(buf, "rsrq");
    li->sinr = m5g_int(buf, "sinr");

    if (m5g_str(buf, "mtemp", tmp, sizeof(tmp)))
        li->temp = atoi(tmp);

    li->signal_pct = m5g_int(buf, "signal");
    li->cid        = m5g_int(buf, "cid_dec");
    li->enbid      = m5g_int(buf, "enbid");
    li->mcc        = m5g_int(buf, "operator_mcc");
    li->mnc        = m5g_int(buf, "operator_mnc");
    li->reg        = m5g_int(buf, "registration");
    li->therm      = m5g_int(buf, "mtherm");
    li->simslot    = m5g_int(buf, "simslot");
    li->roaming    = m5g_int(buf, "roaming");

    m5g_str(buf, "conn_time", li->conn_time, sizeof(li->conn_time));
    m5g_str(buf, "rx", li->rx, sizeof(li->rx));
    m5g_str(buf, "tx", li->tx, sizeof(li->tx));
    m5g_str(buf, "iface_apn", li->apn, sizeof(li->apn));
    m5g_str(buf, "firmware", li->fw, sizeof(li->fw));
    m5g_str(buf, "phone", li->phone, sizeof(li->phone));

    m5g_str(buf, "lac_dec",   li->lac,       sizeof(li->lac));
    m5g_str(buf, "tac_dec",   li->tac,       sizeof(li->tac));
    m5g_str(buf, "cid_hex",   li->cid_hex,   sizeof(li->cid_hex));
    m5g_str(buf, "bandwidth", li->bandwidth, sizeof(li->bandwidth));
    m5g_str(buf, "pathloss",  li->pathloss,  sizeof(li->pathloss));
    m5g_str(buf, "txpower",   li->txpower,   sizeof(li->txpower));
    m5g_str(buf, "cqi",       li->cqi,       sizeof(li->cqi));
    m5g_str(buf, "uecat",     li->uecat,     sizeof(li->uecat));
    m5g_str(buf, "volte",     li->volte,     sizeof(li->volte));
    m5g_str(buf, "pmimo",     li->mimo,      sizeof(li->mimo));
    m5g_str(buf, "rxdiv",     li->rxdiv,     sizeof(li->rxdiv));
    m5g_str(buf, "antports",  li->antports,  sizeof(li->antports));
    m5g_str(buf, "s1band",    li->s1band,    sizeof(li->s1band));
    m5g_str(buf, "s2band",    li->s2band,    sizeof(li->s2band));
    m5g_str(buf, "s3band",    li->s3band,    sizeof(li->s3band));
    li->s1pci    = m5g_int(buf, "s1pci");
    li->s2pci    = m5g_int(buf, "s2pci");
    li->s3pci    = m5g_int(buf, "s3pci");
    li->s1earfcn = m5g_int(buf, "s1earfcn");
    li->s2earfcn = m5g_int(buf, "s2earfcn");
    li->s3earfcn = m5g_int(buf, "s3earfcn");

    if (m5g_str(buf, "mode", mode, sizeof(mode))) {
        const char *b;
        m5g_bands(mode, li->band, sizeof(li->band));
        for (b = li->band; *b; b++)
            if (*b == '+') li->nca++;
        if (li->band[0]) li->nca++;
        /* 5gmodem отдаёт режим как "LTE | B7 (FDD 2600 MHz)", а на простом LTE
         * без агрегации - как "LTE |": хвост пустой, но палка остаётся. Режем
         * по первой палке и подчищаем пробелы, иначе она уезжала на экран. */
        sep = strchr(mode, '|');
        if (sep) *sep = 0;
        {
            size_t n = strlen(mode);
            while (n > 0 && (mode[n - 1] == ' ' || mode[n - 1] == '\t'))
                mode[--n] = 0;
        }
        snprintf(li->mode, sizeof(li->mode), "%s", mode);
    }

    /* Массив соседей отдаём на экран как есть: там уже band/pci/rsrp/rsrq. */
    {
        const char *ns = strstr(buf, "\"neighbors\":");
        const char *o = ns ? strchr(ns, '[') : NULL;
        const char *c = o ? strchr(o, ']') : NULL;
        if (o && c) {
            size_t len = (size_t)(c - o) + 1;
            if (len < sizeof(li->neighbors)) {
                memcpy(li->neighbors, o, len);
                li->neighbors[len] = 0;
            } else {
                /* Массив длиннее буфера: берём сколько влезло и обрезаем по
                 * последней целой записи, иначе экран получит битый JSON.
                 * Рисуем всё равно только шесть первых сот. */
                size_t max = sizeof(li->neighbors) - 2;
                memcpy(li->neighbors, o, max);
                li->neighbors[max] = 0;
                char *last = strrchr(li->neighbors, '}');
                if (last) { last[1] = ']'; last[2] = 0; }
                else strcpy(li->neighbors, "[]");
            }
        }
        if (!li->neighbors[0]) strcpy(li->neighbors, "[]");
    }

    li->pci    = m5g_int(buf, "pci");
    li->rssi   = m5g_int(buf, "rssi");
    li->earfcn = m5g_int(buf, "earfcn");

    nb = strstr(buf, "\"neighbors\":");
    if (nb) {
        if (!li->pci)    li->pci    = m5g_int(nb, "pci");
        if (!li->rssi)   li->rssi   = m5g_int(nb, "rssi");
        if (!li->earfcn) li->earfcn = m5g_int(nb, "earfcn");
    }

    return 1;
}

static void get_lte_info_ext(struct lte_info *li) {
    int fd;
    char buf[2048];
    int total;
    char *line;
    char *ports[] = {"/dev/ttyACM2", "/dev/ttyACM1", "/dev/ttyACM0", NULL};
    int pi;

    memset(li, 0, sizeof(*li));
    fd = -1;
    for (pi = 0; ports[pi]; pi++) {
        fd = open(ports[pi], O_RDWR | O_NOCTTY | O_NONBLOCK);
        if (fd >= 0) break;
    }
    if (fd < 0) return;

    while (read(fd, buf, sizeof(buf)) > 0);
    write(fd, "AT+CSQ\r", 7); usleep(800000);
    write(fd, "AT+COPS?\r", 9); usleep(800000);
    write(fd, "AT+CESQ\r", 8); usleep(800000);
    write(fd, "AT+XCCINFO?\r", 12); usleep(800000);
    write(fd, "AT+XLEC?\r", 9); usleep(1000000);

    total = 0;
    { int retry;
      for (retry = 0; retry < 10 && total < (int)sizeof(buf) - 1; retry++) {
        int n = read(fd, buf + total, sizeof(buf) - 1 - total);
        if (n > 0) { total += n; retry = 0; } else usleep(100000);
    }}
    buf[total] = 0;
    close(fd);
    if (total == 0) return;

    line = strtok(buf, "\r\n");
    while (line) {
        if (strncmp(line, "+CSQ:", 5) == 0)
            sscanf(line, "+CSQ: %d,%d", &li->csq, &li->ber);
        if (strncmp(line, "+COPS:", 6) == 0) {
            char *q1 = strchr(line, '"');
            if (q1) { char *q2 = strchr(q1+1, '"');
                if (q2) { int len = q2-q1-1; if (len>31) len=31;
                    strncpy(li->oper, q1+1, len); li->oper[len]=0; }}
            char *comma = strrchr(line, ',');
            if (comma) { int act = atoi(comma+1);
                if (act==7) strcpy(li->mode,"LTE");
                else if (act==2) strcpy(li->mode,"3G");
                else strcpy(li->mode,"2G"); }
        }
        if (strncmp(line, "+CESQ:", 6) == 0) {
            int rxlev,ber2,rscp,ecno,rsrq_idx,rsrp_idx;
            if (sscanf(line, "+CESQ: %d,%d,%d,%d,%d,%d",
                       &rxlev,&ber2,&rscp,&ecno,&rsrq_idx,&rsrp_idx) >= 6) {
                if (rsrp_idx < 255) li->rsrp = -140 + rsrp_idx;
                if (rsrq_idx < 255) li->rsrq = -20 + rsrq_idx / 2;
            }
        }
        if (strncmp(line, "+XCCINFO:", 9) == 0) {
            int v[10]={0}; int n=0; char *p=line+9;
            while (*p && n < 10) {
                while (*p==' '||*p==',') p++;
                if (*p=='"') { while(*p&&*p!=',')p++; continue; }
                if (*p>='0'&&*p<='9') { v[n++]=atoi(p); while(*p&&*p!=',')p++; }
                else { while(*p&&*p!=',')p++; }
            }
            if (n >= 5) { snprintf(li->band,sizeof(li->band),"B%d",v[3]); li->pci=v[4]; }
        }
        line = strtok(NULL, "\r\n");
    }
    if (li->csq > 0 && li->csq < 32) li->rssi = 2 * li->csq - 113;
    if (li->rsrp == 0 && li->csq > 0) li->rsrp = li->rssi - 3;
    run_cmd("ip -4 addr show wwan0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1",
            li->ip, sizeof(li->ip));
}

static void lte_poll(struct lte_info *li) {
    static struct lte_info cache;
    static time_t last = 0;
    static int have_5g = -1;
    time_t now = time(NULL);

    if (have_5g < 0)
        have_5g = (access(M5G_SH, X_OK) == 0);

    if (last && now - last < M5G_PERIOD) {
        *li = cache;
        return;
    }

    if (!have_5g || !get_lte_from_5gmodem(li))
        get_lte_info_ext(li);

    cache = *li;
    last = now;
}

/* ======== WiFi ======== */
/* Экранирование строки для JSON: имя хоста задаёт само LAN-устройство,
 * и кавычка или бэкслеш в нём иначе рвут весь снапшот - интерфейс
 * остаётся вообще без данных. Заодно режем управляющие символы. */
static void json_escape(const char *in, char *out, int outsz) {
    int o = 0;
    for (int i = 0; in[i] && o < outsz - 2; i++) {
        unsigned char c = in[i];
        if (c == '"' || c == '\\') {
            if (o >= outsz - 3) break;
            out[o++] = '\\'; out[o++] = c;
        } else if (c < 0x20) {
            continue;
        } else {
            out[o++] = c;
        }
    }
    out[o] = 0;
}

static int get_wifi_clients(char *json_array, int bufsz) {
    char buf[4096];
    int n = 0, first = 1;
    /* Копим JSON вручную: snprintf возвращает «сколько БЫ записал», и если
     * трактовать это как «записано», при усечении n уезжает за буфер, а
     * следующий bufsz-n на musl превращается в огромный size_t -> запись за
     * пределами стека (порча). Поэтому каждый объект строим во временный буфер
     * и добавляем целиком, только если помещается (запятая+объект+"]"+NUL). */
    if (bufsz < 3) { if (bufsz > 0) json_array[0] = 0; return 0; }
    json_array[n++] = '[';
    for (int phy = 0; phy <= 1; phy++) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
            "iw dev phy%d-ap0 station dump 2>/dev/null | "
            "awk '/Station/{if(mac)print mac,sig,rx,tx;"
            "mac=$2;sig=0;rx=0;tx=0} /signal:/{sig=$2} "
            "/rx bytes:/{rx=$3} /tx bytes:/{tx=$3} "
            "END{if(mac)print mac,sig,rx,tx}'", phy);
        if (run_cmd_all(cmd, buf, sizeof(buf)) > 0) {
            char *line = strtok(buf, "\n");
            while (line) {
                char mac[20]={0}; int sig=0; long long rx=0,tx=0;
                if (sscanf(line, "%19s %d %lld %lld", mac, &sig, &rx, &tx) >= 2) {
                    char name[64]="unknown", ip[20]="", lcmd[128];
                    snprintf(lcmd,sizeof(lcmd),"grep -i '%s' /tmp/dhcp.leases | awk '{print $4}'",mac);
                    run_cmd(lcmd,name,sizeof(name));
                    if (name[0]==0||name[0]=='*') strcpy(name,"unknown");
                    snprintf(lcmd,sizeof(lcmd),"grep -i '%s' /tmp/dhcp.leases | awk '{print $3}'",mac);
                    run_cmd(lcmd,ip,sizeof(ip));
                    char nesc[128]; json_escape(name, nesc, sizeof(nesc));
                    char *band = (phy==0) ? "5G" : "2G";
                    char obj[320];
                    int ol = snprintf(obj, sizeof(obj),
                        "{\"mac\":\"%s\",\"name\":\"%s\",\"ip\":\"%s\","
                        "\"band\":\"%s\",\"signal\":%d,\"rx_bytes\":%lld,\"tx_bytes\":%lld}",
                        mac,nesc,ip,band,sig,rx,tx);
                    if (ol < 0) ol = 0;
                    if (ol >= (int)sizeof(obj)) ol = (int)sizeof(obj) - 1;
                    /* нужно: [запятая] + объект + "]" + NUL */
                    if (n + (first ? 0 : 1) + ol + 2 > bufsz) { line = NULL; break; }
                    if (!first) json_array[n++] = ',';
                    memcpy(json_array + n, obj, ol); n += ol;
                    first = 0;
                }
                line = strtok(NULL, "\n");
            }
        }
    }
    json_array[n++] = ']';
    json_array[n] = 0;
    return n;
}

/* ======== VPN ======== */
static void get_vpn_info(int *active, int *ping_ms, char *ext_ip, int ip_sz,
                         char *vpn_type, int type_sz) {
    char buf[128];
    *active=0; *ping_ms=0; ext_ip[0]=0; vpn_type[0]=0;
    if (run_cmd("wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}'",
                buf,sizeof(buf))==0 && buf[0]) {
        if (time(NULL) - atol(buf) < 180) { *active=1; strncpy(vpn_type,"WG",type_sz-1); }
    }
    if (!*active && run_cmd("ip link show tun0 2>/dev/null | grep -c UP",buf,sizeof(buf))==0 && buf[0]=='1') {
        *active=1; strncpy(vpn_type,"OVPN",type_sz-1);
    }
    if (!*active && run_cmd("ip link show l2tp-l2tp_tina 2>/dev/null | grep -c UP",buf,sizeof(buf))==0 && buf[0]=='1') {
        *active=1; strncpy(vpn_type,"L2TP",type_sz-1);
    }
    {
        static char ext_cache[64];
        static time_t ext_at;
        time_t now = time(NULL);
        if (ext_at == 0 || now - ext_at >= EXTIP_PERIOD) {
            run_cmd("wget -qO- --timeout=3 http://ifconfig.me/ip 2>/dev/null || "
                    "curl -s --max-time 3 ifconfig.me/ip 2>/dev/null",
                    ext_cache, sizeof(ext_cache));
            ext_at = now;
        }
        snprintf(ext_ip, ip_sz, "%s", ext_cache);
    }
    if (*active) {
        char ping_cmd[128];
        const char *dev = strcmp(vpn_type,"WG")==0?"wg0":strcmp(vpn_type,"OVPN")==0?"tun0":"l2tp-l2tp_tina";
        snprintf(ping_cmd,sizeof(ping_cmd),"ping -c1 -W2 -I %s " PING_HOST " 2>/dev/null | grep 'time=' | sed 's/.*time=//;s/ .*//'",dev);
        if (run_cmd(ping_cmd,buf,sizeof(buf))==0 && buf[0] && atof(buf)>0) *ping_ms=(int)atof(buf);
        else *ping_ms=-1;
    }
}

/* ======== Socket: push to clients ======== */
static void push_to_clients(const char *json, int len) {
    for (int i = 0; i < client_count; i++) {
        if (write(clients[i], json, len) < 0) {
            close(clients[i]);
            clients[i] = clients[--client_count];
            i--;
        }
    }
}

static void accept_clients(int srv) {
    /* Non-blocking accept */
    while (client_count < MAX_CLIENTS) {
        int cfd = accept(srv, NULL, NULL);
        if (cfd < 0) break;
        fcntl(cfd, F_SETFL, O_NONBLOCK);
        clients[client_count++] = cfd;
    }
}

/* ======== Main ======== */
int main(void) {
    fprintf(stderr, MODNAME " " VERSION " by a43 — START\n");

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGPIPE, SIG_IGN);

    /* PID file: kill old instance */
    {
        FILE *pf = fopen("/tmp/almond3s_collector.pid", "r");
        if (pf) { int old=0; fscanf(pf,"%d",&old); fclose(pf);
            if (old>0 && kill(old,0)==0) { kill(old,9); usleep(500000); } }
        pf = fopen("/tmp/almond3s_collector.pid", "w");
        if (pf) { fprintf(pf,"%d\n",getpid()); fclose(pf); }
    }

    /* Create socket server */
    unlink(SOCK_PATH);
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    bind(srv, (struct sockaddr *)&addr, sizeof(addr));
    listen(srv, MAX_CLIENTS);
    chmod(SOCK_PATH, 0666);
    fcntl(srv, F_SETFL, O_NONBLOCK);

    fprintf(stderr, MODNAME ": socket %s ready\n", SOCK_PATH);

    bat_cal_load();

    while (running) {
        struct lte_info li;
        int vpn_active=0, vpn_ping=0;
        char ext_ip[32]="", vpn_type[8]="", wifi_json[2048]="[]";
        long ovl_free, ovl_total;
        char lan_ip[46], lan_mac[20];
        get_overlay(&ovl_free, &ovl_total);
        get_lan(lan_ip, sizeof(lan_ip), lan_mac, sizeof(lan_mac));
        struct sysinfo si;
        struct battery_info bat;
        char ping_buf[32]="";
        int google_ping;
        char json[JSON_BUF];
        int len;

        /* Collect */
        lte_poll(&li);
        get_vpn_info(&vpn_active, &vpn_ping, ext_ip, sizeof(ext_ip), vpn_type, sizeof(vpn_type));
        get_wifi_clients(wifi_json, sizeof(wifi_json));
        sysinfo(&si);
        get_battery(&bat);
        bat_update(&bat_est, &bat);
        /* Время работы от батареи: засекаем момент, когда сняли зарядку, и
         * отдаём прошедшие секунды. Живёт в памяти демона (сброс на его
         * перезапуск - это редко и не критично). */
        static time_t bat_unplug_ts = 0;
        if (bat.no_battery || bat.charging) bat_unplug_ts = 0;
        else if (bat_unplug_ts == 0)       bat_unplug_ts = time(NULL);
        int on_bat_sec = bat_unplug_ts ? (int)(time(NULL) - bat_unplug_ts) : 0;
        run_cmd("ping -c1 -W2 " PING_HOST " 2>/dev/null | grep 'time=' | sed 's/.*time=//;s/ .*//'", ping_buf, sizeof(ping_buf));
        google_ping = (ping_buf[0] && atof(ping_buf)>0) ? (int)atof(ping_buf) : -1;

        /* Format JSON */
        char core_json[96];
        {
            int cb[8], cn = cpu_core_busy(cb, 8), off = 1;
            core_json[0] = '[';
            for (int i = 0; i < cn && off < (int)sizeof(core_json) - 8; i++)
                off += snprintf(core_json + off, sizeof(core_json) - off,
                                i ? ",%d" : "%d", cb[i]);
            core_json[off] = ']';
            core_json[off + 1] = 0;
        }

        len = snprintf(json, sizeof(json),
            "{\"ts\":%ld,"
            "\"lte\":{\"csq\":%d,\"ber\":%d,\"rsrp\":%d,\"rsrq\":%d,"
            "\"sinr\":%d,\"rssi\":%d,\"pci\":%d,"
            "\"band\":\"%s\",\"mode\":\"%s\",\"operator\":\"%s\",\"ip\":\"%s\","
            "\"modem\":\"%s\",\"temp\":%d,\"signal\":%d,\"nca\":%d,"
            "\"conn_time\":\"%s\",\"rx\":\"%s\",\"tx\":\"%s\",\"apn\":\"%s\","
            "\"fw\":\"%s\",\"therm\":%d,\"simslot\":%d,\"roaming\":%d,"
            "\"cid\":%d,\"enbid\":%d,\"mcc\":%d,\"mnc\":%d,\"earfcn\":%d,"
            "\"reg\":%d,"
            "\"phone\":\"%s\","
            "\"cell\":{\"lac\":\"%s\",\"tac\":\"%s\",\"cid_hex\":\"%s\","
            "\"bandwidth\":\"%s\",\"pathloss\":\"%s\",\"txpower\":\"%s\","
            "\"cqi\":\"%s\",\"uecat\":\"%s\",\"volte\":\"%s\",\"mimo\":\"%s\","
            "\"rxdiv\":\"%s\",\"antports\":\"%s\","
            "\"s1band\":\"%s\",\"s1pci\":%d,\"s1earfcn\":%d,"
            "\"s2band\":\"%s\",\"s2pci\":%d,\"s2earfcn\":%d,"
            "\"s3band\":\"%s\",\"s3pci\":%d,\"s3earfcn\":%d,"
            "\"neighbors\":%s}},"
            "\"vpn\":{\"active\":%s,\"type\":\"%s\",\"ping_ms\":%d,\"external_ip\":\"%s\"},"
            "\"wifi\":{\"clients\":%s},"
            "\"ping\":{\"google_ms\":%d},"
            "\"battery\":{\"adc\":%d,\"percent\":%d,\"charging\":%s,\"full\":%s,\"valid\":%s,"
            "\"no_battery\":%s,\"remain_min\":%d,\"drain_rate\":%d.%d,\"cutoff\":%d,"
            "\"on_bat_sec\":%d,\"raw_hex\":\"%02x %02x\"},"
            "\"storage\":{\"free_kb\":%ld,\"total_kb\":%ld},"
            "\"lan\":{\"ip\":\"%s\",\"mac\":\"%s\"},"
            "\"uptime\":%ld,\"mem_free_mb\":%ld,\"mem_total_mb\":%ld,"
            "\"cpu_load\":%.2f,\"cpu_busy\":%d,\"cpu_cores\":%d,"
            "\"cpu_core_busy\":%s}\n",
            (long)time(NULL),
            li.csq,li.ber,li.rsrp,li.rsrq,li.sinr,li.rssi,li.pci,
            li.band,li.mode,li.oper,li.ip,li.modem,li.temp,li.signal_pct,li.nca,
            li.conn_time,li.rx,li.tx,li.apn,li.fw,li.therm,li.simslot,li.roaming,
            li.cid,li.enbid,li.mcc,li.mnc,li.earfcn,li.reg,li.phone,
            li.lac,li.tac,li.cid_hex,li.bandwidth,li.pathloss,li.txpower,
            li.cqi,li.uecat,li.volte,li.mimo,li.rxdiv,li.antports,
            li.s1band,li.s1pci,li.s1earfcn,
            li.s2band,li.s2pci,li.s2earfcn,
            li.s3band,li.s3pci,li.s3earfcn,
            li.neighbors[0] ? li.neighbors : "[]",
            vpn_active?"true":"false",vpn_type,vpn_ping,ext_ip,
            wifi_json, google_ping,
            bat.adc,bat.percent,bat.charging?"true":"false",bat.full?"true":"false",bat.valid?"true":"false",
            bat.no_battery?"true":"false",
            bat_est.remain_min, bat_est.drain_rate/100, abs(bat_est.drain_rate)%100,
            bat_cal_cutoff,
            on_bat_sec,
            bat.raw1, bat.raw2,
            ovl_free, ovl_total, lan_ip, lan_mac,
            si.uptime, (si.freeram + si.bufferram)/1024/1024,
            si.totalram/1024/1024, si.loads[0]/65536.0,
            cpu_busy_pct(), cpu_core_count(), core_json);

        /* snprintf возвращает «сколько БЫ записал»: если JSON перерастёт буфер,
         * len окажется больше реального содержимого, и write()/fwrite() ниже
         * прочитают за пределами json[] (утечка соседней памяти клиентам и в
         * файл). Клампим к фактическому размеру. */
        if (len < 0) len = 0;
        if (len >= (int)sizeof(json)) len = (int)sizeof(json) - 1;

        /* Push to socket clients */
        accept_clients(srv);
        push_to_clients(json, len);

        /* Also write file for compatibility */
        FILE *fp = fopen(JSON_PATH ".tmp", "w");
        if (fp) { fwrite(json, 1, len, fp); fclose(fp); rename(JSON_PATH ".tmp", JSON_PATH); }

        sleep(INTERVAL);
    }

    close(srv);
    unlink(SOCK_PATH);
    unlink("/tmp/almond3s_collector.pid");
    fprintf(stderr, MODNAME " " VERSION " — STOP\n");
    return 0;
}
