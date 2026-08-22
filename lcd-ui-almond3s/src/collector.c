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

/* Сколько тактов процессора прошло между нашими замерами - нужно, чтобы
 * перевести приращение конкретного процесса в проценты от всей машины.
 * Заполняется в cpu_busy_pct, поэтому её надо звать первой. */
static unsigned long long cpu_dt_ticks;

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
    cpu_dt_ticks = 0;
    if (prev_total && total > prev_total) {
        unsigned long long dt = total - prev_total;
        unsigned long long di = idle - prev_idle;
        cpu_dt_ticks = dt;
        pct = (int)((dt - di) * 100 / dt);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
    }
    prev_idle = idle;
    prev_total = total;
    return pct;
}

/* Топ процессов по процессору. Считаем ПРИРАЩЕНИЕ utime+stime между тиками:
 * мгновенный снимок /proc показывает время с запуска процесса, и в топ вечно
 * лезли бы долгоживущие демоны, а не тот, кто ест прямо сейчас. */
struct proc_prev { int pid; unsigned long long ticks; };
#define PROC_PREV_MAX 256

static int cpu_top_json(char *out, int outsz, int want)
{
    static struct proc_prev prev[PROC_PREV_MAX];
    static int prev_n;
    struct proc_prev cur[PROC_PREV_MAX];
    struct { char name[20]; int pct; unsigned long long d; } top[12];
    int cur_n = 0, top_n = 0;
    DIR *d = opendir("/proc");
    struct dirent *e;

    out[0] = '['; out[1] = ']'; out[2] = 0;
    if (!d) return 0;
    if (want > 12) want = 12;

    while ((e = readdir(d)) != NULL && cur_n < PROC_PREV_MAX) {
        char path[64], buf[512], name[20] = "";
        int pid = atoi(e->d_name);
        FILE *f;
        if (pid <= 0) continue;
        snprintf(path, sizeof path, "/proc/%d/stat", pid);
        f = fopen(path, "r");
        if (!f) continue;
        size_t got = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        if (got == 0) continue;
        buf[got] = 0;

        /* Имя процесса в скобках может само содержать пробелы и скобки,
         * поэтому ищем ПОСЛЕДНЮЮ закрывающую, а не первую. */
        char *lp = strchr(buf, '(');
        char *rp = strrchr(buf, ')');
        if (!lp || !rp || rp <= lp + 1) continue;
        {
            int nl = (int)(rp - lp - 1);
            if (nl > (int)sizeof name - 1) nl = (int)sizeof name - 1;
            memcpy(name, lp + 1, (size_t)nl);
            name[nl] = 0;
            for (int i = 0; name[i]; i++)
                if (name[i] == '"' || name[i] == '\\' || (unsigned char)name[i] < 32)
                    name[i] = '.';
        }

        /* После ")" идут: состояние, пять целых (ppid..tpgid), пять счётчиков
         * (flags, minflt, cminflt, majflt, cmajflt) и затем utime и stime. */
        unsigned long long ut = 0, st2 = 0;
        {
            char state;
            if (sscanf(rp + 2, "%c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu",
                       &state, &ut, &st2) != 3)
                continue;
        }

        cur[cur_n].pid = pid;
        cur[cur_n].ticks = ut + st2;

        unsigned long long was = 0;
        int seen = 0;
        for (int i = 0; i < prev_n; i++)
            if (prev[i].pid == pid) { was = prev[i].ticks; seen = 1; break; }
        cur_n++;
        if (!seen || cur[cur_n - 1].ticks < was) continue;

        unsigned long long delta = cur[cur_n - 1].ticks - was;
        if (delta == 0 || cpu_dt_ticks == 0) continue;
        /* Ранжируем по СЫРОМУ приращению, а не по процентам: на спокойной
         * машине почти все едоки после округления дают ноль, и список из
         * пяти имён схлопывался в одно. Проценты остаются для показа. */
        int pct = (int)(delta * 100 / cpu_dt_ticks);
        if (pct > 100) pct = 100;

        /* Список короткий - держим его отсортированным вставкой с конца. */
        if (top_n < want) {
            snprintf(top[top_n].name, sizeof top[0].name, "%s", name);
            top[top_n].pct = pct;
            top[top_n].d = delta;
            top_n++;
        } else if (delta > top[top_n - 1].d) {
            snprintf(top[top_n - 1].name, sizeof top[0].name, "%s", name);
            top[top_n - 1].pct = pct;
            top[top_n - 1].d = delta;
        } else {
            continue;
        }
        for (int i = top_n - 1; i > 0 && top[i].d > top[i - 1].d; i--) {
            char tn[20];
            int tp = top[i].pct;
            unsigned long long td = top[i].d;
            snprintf(tn, sizeof tn, "%s", top[i].name);
            snprintf(top[i].name, sizeof top[0].name, "%s", top[i - 1].name);
            top[i].pct = top[i - 1].pct;
            top[i].d = top[i - 1].d;
            snprintf(top[i - 1].name, sizeof top[0].name, "%s", tn);
            top[i - 1].pct = tp;
            top[i - 1].d = td;
        }
    }
    closedir(d);

    memcpy(prev, cur, sizeof(struct proc_prev) * (size_t)cur_n);
    prev_n = cur_n;

    int off = 1;
    for (int i = 0; i < top_n && off < outsz - 32; i++)
        off += snprintf(out + off, (size_t)(outsz - off), i ? ",{\"n\":\"%s\",\"p\":%d}" : "{\"n\":\"%s\",\"p\":%d}",
                        top[i].name, top[i].pct);
    out[off] = ']';
    out[off + 1] = 0;
    return top_n;
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
    int cid, enbid, mcc, reg;
    char mnc[8];
    char conn_time[24], rx[16], tx[16], apn[32], fw[24], phone[24];
    /* Информация о соте - как на одноимённой странице 5gmodem. */
    char lac[24], tac[24], cid_hex[24], bandwidth[24], pathloss[16], txpower[16];
    char cqi[16], uecat[16], volte[16], mimo[16], rxdiv[16], antports[64];
    char s1band[24], s2band[24], s3band[24];
    int s1pci, s2pci, s3pci, s1earfcn, s2earfcn, s3earfcn;
    /* Состояние несущей: "activated" - работает, "deactivated" - спит (сеть
       держит про запас), "-" - модем не сообщил. По нему отличаем активную
       агрегацию от сконфигурированной, но спящей. */
    char s1state[16], s2state[16], s3state[16];
    char ca[48];           /* ярлык агрегации ТОЛЬКО из активных несущих: B1+B40 */
    char neighbors[1024];  /* готовый JSON-массив соседних сот от 5gmodem */
};

/* ======== LTE via luci-app-5gmodem ======== */
#define M5G_PERIOD  10
/* 8.8.8.8 в России часто недоступен, и каждый цикл упирался в полный таймаут
   -W2. Яндексовский резолвер отвечает всегда, проверка связности от этого не
   хуже. Внешний IP меняется редко - незачем ходить за ним каждый круг. */
#define PING_HOST   "77.88.8.8"
#define EXTIP_PERIOD 60

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
    /* Значение уедет в НАШ JSON. Обратный слэш в конце строки экранировал бы
     * закрывающую кавычку, а управляющий байт делает файл невалидным целиком -
     * и тогда слепнет весь интерфейс, а не одно поле. Кавычка сюда не дойдёт:
     * разбор останавливается на первой. */
    for (int i = 0; out[i]; i++)
        if (out[i] == '\\' || (unsigned char)out[i] < 0x20) out[i] = '.';
    if (strcmp(out, "-") == 0) out[0] = 0;
    return out[0] ? 1 : 0;
}



#define TELE_FILE   "/tmp/5gmodem_tele.json"
#define TELE_CELL   "/tmp/5gmodem_tele_cell.json"
#define TELE_STALE  90

static int tele_state;
static int tele_modem;

static int tele_num(const char *json, const char *key, int *ok) {
    char pat[48];
    const char *p;
    if (ok) *ok = 0;
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    p = strstr(json, pat);
    if (!p) return 0;
    p += strlen(pat);
    while (*p == ' ') p++;
    if (*p == '"') return 0;
    if (ok) *ok = 1;
    return atoi(p);
}

static void tele_apply(struct lte_info *li) {
    static char buf[2048];
    struct stat sb;
    FILE *f;
    size_t got;
    int ok;

    tele_state = 0;
    tele_modem = 0;
    if (stat(TELE_FILE, &sb) != 0) return;
    if (time(NULL) - sb.st_mtime > TELE_STALE) { tele_state = -1; return; }
    f = fopen(TELE_FILE, "r");
    if (!f) return;
    got = fread(buf, 1, sizeof(buf) - 1, f);
    buf[got] = 0;
    fclose(f);
    tele_state = 1;

    li->signal_pct = tele_num(buf, "sig", &ok);
    if (ok) tele_modem = 1;
    if (strstr(buf, "\"rsrp\":") || strstr(buf, "\"oper\":")) tele_modem = 1;
    li->rsrp = tele_num(buf, "rsrp", &ok);
    li->rsrq = tele_num(buf, "rsrq", &ok);
    li->sinr = tele_num(buf, "sinr", &ok);
    li->temp = tele_num(buf, "temp", &ok);

    m5g_str(buf, "oper", li->oper, sizeof(li->oper));
    m5g_str(buf, "mode", li->mode, sizeof(li->mode));
    /* band - основная несущая, ca - ярлык АКТИВНОЙ агрегации (только рабочие
       несущие). Раньше ca писался в band как фолбэк, и они путались. Ключа ca
       у модема может не быть - тогда активной агрегации нет, ниже соберём её из
       слотов по state. */
    m5g_str(buf, "band", li->band, sizeof(li->band));
    m5g_str(buf, "ca", li->ca, sizeof(li->ca));
}

static void tele_clear(struct lte_info *li) {
    li->signal_pct = 0;
    li->csq = li->rssi = li->nca = 0;
    li->rsrp = li->rsrq = li->sinr = li->temp = 0;
    li->oper[0] = 0;
    li->mode[0] = 0;
    li->band[0] = 0;
    li->ca[0] = 0;
    li->s1band[0] = li->s2band[0] = li->s3band[0] = 0;
    li->s1state[0] = li->s2state[0] = li->s3state[0] = 0;
}

/* Короткое имя диапазона: 5gmodem пишет «B40 (2300 MHz)», а в плитку и в
   строку несущих влезает только «B40». */
static void band_short(const char *src, char *dst, size_t n) {
    size_t i = 0;
    while (src[i] && src[i] != ' ' && src[i] != '(' && i + 1 < n) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = 0;
}

static void tele_cell(struct lte_info *li) {
    static char buf[4096];
    struct stat sb;
    FILE *f;
    size_t got;
    int ok, v;
    char sv[80];

    if (stat(TELE_CELL, &sb) != 0) return;
    if (time(NULL) - sb.st_mtime > TELE_STALE) return;
    f = fopen(TELE_CELL, "r");
    if (!f) return;
    got = fread(buf, 1, sizeof(buf) - 1, f);
    buf[got] = 0;
    fclose(f);

    v = tele_num(buf, "pci", &ok);     if (ok) li->pci = v;
    v = tele_num(buf, "earfcn", &ok);  if (ok) li->earfcn = v;
    v = tele_num(buf, "enb", &ok);     if (ok) li->enbid = v;
    v = tele_num(buf, "cid", &ok);     if (ok) li->cid = v;
    v = tele_num(buf, "mcc", &ok);     if (ok) li->mcc = v;
    v = tele_num(buf, "csq", &ok);     if (ok) li->csq = v;
    v = tele_num(buf, "rssi", &ok);    if (ok) li->rssi = v;
    v = tele_num(buf, "nca", &ok);     if (ok) li->nca = v;
    v = tele_num(buf, "roaming", &ok); if (ok) li->roaming = v;
    v = tele_num(buf, "simslot", &ok); if (ok) li->simslot = v;
    v = tele_num(buf, "therm", &ok);   if (ok) li->therm = v;
    v = tele_num(buf, "tac", &ok);     if (ok) snprintf(li->tac, sizeof(li->tac), "%d", v);
    v = tele_num(buf, "lac", &ok);     if (ok) snprintf(li->lac, sizeof(li->lac), "%d", v);
    v = tele_num(buf, "pathloss", &ok);
    if (ok) snprintf(li->pathloss, sizeof(li->pathloss), "%d", v);
    v = tele_num(buf, "cqi", &ok);
    if (ok) snprintf(li->cqi, sizeof(li->cqi), "%d", v);

    v = tele_num(buf, "conn_time", &ok);
    if (ok)
        snprintf(li->conn_time, sizeof(li->conn_time), "%dd, %02d:%02d:%02d",
                 v / 86400, (v % 86400) / 3600, (v % 3600) / 60, v % 60);

    if (m5g_str(buf, "mnc", sv, sizeof(sv)))
        snprintf(li->mnc, sizeof(li->mnc), "%s", sv);
    if (m5g_str(buf, "apn", sv, sizeof(sv)))
        snprintf(li->apn, sizeof(li->apn), "%s", sv);
    if (m5g_str(buf, "wan_ip", sv, sizeof(sv)))
        snprintf(li->ip, sizeof(li->ip), "%s", sv);
    if (m5g_str(buf, "modem", sv, sizeof(sv)))
        snprintf(li->modem, sizeof(li->modem), "%s", sv);
    if (m5g_str(buf, "cid_hex", sv, sizeof(sv)))
        snprintf(li->cid_hex, sizeof(li->cid_hex), "%s", sv);
    if (m5g_str(buf, "fw", sv, sizeof(sv)))
        snprintf(li->fw, sizeof(li->fw), "%s", sv);
    if (m5g_str(buf, "phone", sv, sizeof(sv)))
        snprintf(li->phone, sizeof(li->phone), "%s", sv);
    if (m5g_str(buf, "bandwidth", sv, sizeof(sv)))
        snprintf(li->bandwidth, sizeof(li->bandwidth), "%s", sv);
    if (m5g_str(buf, "txpower", sv, sizeof(sv)))
        snprintf(li->txpower, sizeof(li->txpower), "%s", sv);
    if (m5g_str(buf, "mimo", sv, sizeof(sv)))
        snprintf(li->mimo, sizeof(li->mimo), "%s", sv);
    if (m5g_str(buf, "rxdiv", sv, sizeof(sv)))
        snprintf(li->rxdiv, sizeof(li->rxdiv), "%s", sv);
    if (m5g_str(buf, "antports", sv, sizeof(sv)))
        snprintf(li->antports, sizeof(li->antports), "%s", sv);
    if (m5g_str(buf, "uecat", sv, sizeof(sv)))
        snprintf(li->uecat, sizeof(li->uecat), "%s", sv);
    if (m5g_str(buf, "volte", sv, sizeof(sv)))
        snprintf(li->volte, sizeof(li->volte), "%s", sv);

    {
        /* Несущие 5gmodem отдаёт ПЛОСКИМИ ключами: "s1band", "s1pci", "s1earfcn".
           Раньше мы искали вложенные объекты "s1":{...} - их в файле нет, и все
           дополнительные несущие терялись: страница «Сота» показывала пустой
           список, а виджет агрегации - один основной диапазон. Вложенный вид
           оставлен запасным путём на случай другой версии 5gmodem. */
        const char *nest[3] = { "\"s1\":{", "\"s2\":{", "\"s3\":{" };
        const char *fb[3] = { "s1band", "s2band", "s3band" };
        const char *fp[3] = { "s1pci",  "s2pci",  "s3pci"  };
        const char *fe[3] = { "s1earfcn", "s2earfcn", "s3earfcn" };
        const char *fst[3] = { "s1state", "s2state", "s3state" };
        char *bands[3] = { li->s1band, li->s2band, li->s3band };
        char *stts[3] = { li->s1state, li->s2state, li->s3state };
        int sizes[3] = { (int)sizeof(li->s1band), (int)sizeof(li->s2band), (int)sizeof(li->s3band) };
        int ssz[3] = { (int)sizeof(li->s1state), (int)sizeof(li->s2state), (int)sizeof(li->s3state) };
        int *pcis[3] = { &li->s1pci, &li->s2pci, &li->s3pci };
        int *earf[3] = { &li->s1earfcn, &li->s2earfcn, &li->s3earfcn };
        /* li - неинициализированная переменная цикла: зануляем слоты явно,
           иначе пропущенный ключ оставил бы мусор со стека. */
        for (int i = 0; i < 3; i++) { bands[i][0] = 0; stts[i][0] = 0; *pcis[i] = 0; *earf[i] = 0; }
        for (int i = 0; i < 3; i++) {
            /* state читаем безусловно: m5g_str сам обнулит поле, если ключа нет,
               и мусор не задержится. */
            m5g_str(buf, fst[i], stts[i], (size_t)ssz[i]);
            if (m5g_str(buf, fb[i], sv, sizeof(sv))) band_short(sv, bands[i], (size_t)sizes[i]);
            v = tele_num(buf, fp[i], &ok);    if (ok) *pcis[i] = v;
            v = tele_num(buf, fe[i], &ok);    if (ok) *earf[i] = v;
            if (bands[i][0]) continue;
            {
                const char *o = strstr(buf, nest[i]);
                if (!o) continue;
                o = strchr(o, '{');
                if (!o) continue;
                if (m5g_str(o, "band", sv, sizeof(sv))) band_short(sv, bands[i], (size_t)sizes[i]);
                v = tele_num(o, "pci", &ok);    if (ok) *pcis[i] = v;
                v = tele_num(o, "earfcn", &ok); if (ok) *earf[i] = v;
                m5g_str(o, "state", stts[i], (size_t)ssz[i]);
            }
        }

        /* Ярлык агрегации - ТОЛЬКО из активных несущих. Слоты s1..s4 описывают
           ВСЮ сконфигурированную агрегацию, включая спящие: сеть собирает SCC
           заранее и держит выключенными до трафика. Спящую несущую в ярлык не
           берём (иначе покой выглядит как работающая агрегация) - признак один,
           state=="activated". У спящей RSRP/SINR есть, но данные она не несёт,
           так что наличие уровней активностью не считаем.
           Если модем уже дал готовый ca в основном файле (он тоже только из
           активных) - он приоритетнее, наш подсчёт лишь запасной. */
        if (!li->ca[0]) {
            char *sec[3] = { li->s1band, li->s2band, li->s3band };
            char *stt[3] = { li->s1state, li->s2state, li->s3state };
            int n = 0;
            if (li->band[0] && li->band[0] != '-') {
                band_short(li->band, li->ca, sizeof(li->ca));
                n = 1;
            }
            for (int i = 0; i < 3; i++) {
                if (!sec[i][0] || sec[i][0] == '-') continue;
                if (strcmp(stt[i], "activated") != 0) continue;   /* спящую пропускаем */
                if (li->ca[0])
                    snprintf(li->ca + strlen(li->ca), sizeof(li->ca) - strlen(li->ca),
                             "+%s", sec[i]);
                else
                    snprintf(li->ca, sizeof(li->ca), "%s", sec[i]);
                n++;
            }
            /* Один PCC без активных SCC - не агрегация: ярлык очищаем, экран
               покажет обычный бенд неподсвеченным. */
            if (n < 2) li->ca[0] = 0;
        }
        /* nca НЕ пересчитываем: 5gmodem отдаёт число активных вторичных
           несущих, nca:0 при заполненных слотах - норма (собрано, но спит). */
    }

    {
        const char *nb = strstr(buf, "\"nbrs\":");
        const char *o = nb ? strchr(nb, '[') : NULL;
        const char *e = o ? strchr(o, ']') : NULL;
        if (o && e && (size_t)(e - o + 1) < sizeof(li->neighbors)) {
            memcpy(li->neighbors, o, (size_t)(e - o + 1));
            li->neighbors[e - o + 1] = 0;
        }
    }

    /* «+» в режиме (4G+) значит РАБОТАЮЩУЮ агрегацию, а не способность к ней.
       Некоторые модемы (Telit) пишут 4G+, даже когда все SCC спят. Приводим
       4G-семейство к факту: собран активный ca -> 4G+, иначе 4G. Остальные
       режимы (5G/3G) не трогаем. */
    if (!strcmp(li->mode, "4G") || !strcmp(li->mode, "4G+") || !strcmp(li->mode, "LTE"))
        snprintf(li->mode, sizeof(li->mode), "%s", li->ca[0] ? "4G+" : "4G");
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
    time_t now = time(NULL);
    int have_5g = (access(TELE_FILE, R_OK) == 0);

    if (last && now - last < M5G_PERIOD) {
        *li = cache;
        return;
    }

    if (!have_5g)
        get_lte_info_ext(li);

    {
        static struct lte_info good;
        static int have_good = 0;
        static int miss = 0;

        tele_apply(li);
        if (tele_state == 1 && tele_modem) {
            tele_cell(li);
            good = *li;
            have_good = 1;
            miss = 0;
        } else if (have_good && ++miss < 3) {
            *li = good;
        } else {
            tele_clear(li);
            have_good = 0;
        }
    }

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
        /* Порядок важен: cpu_busy_pct заполняет длину интервала в тактах,
         * без неё топ процессов не в чем измерять. */
        int cpu_b = cpu_busy_pct();
        /* Десять имён - столько влезает в правую половину большой карточки
         * виджета; на каждое уходит около 27 байт JSON. */
        char top_json[448];
        cpu_top_json(top_json, sizeof top_json, 10);
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
            "\"tele\":{\"src\":%d,\"modem\":%d},"
            "\"lte\":{\"csq\":%d,\"ber\":%d,\"rsrp\":%d,\"rsrq\":%d,"
            "\"sinr\":%d,\"rssi\":%d,\"pci\":%d,"
            "\"band\":\"%s\",\"ca\":\"%s\",\"mode\":\"%s\",\"operator\":\"%s\",\"ip\":\"%s\","
            "\"modem\":\"%s\",\"temp\":%d,\"signal\":%d,\"nca\":%d,"
            "\"conn_time\":\"%s\",\"rx\":\"%s\",\"tx\":\"%s\",\"apn\":\"%s\","
            "\"fw\":\"%s\",\"therm\":%d,\"simslot\":%d,\"roaming\":%d,"
            "\"cid\":%d,\"enbid\":%d,\"mcc\":%d,\"mnc\":\"%s\",\"earfcn\":%d,"
            "\"reg\":%d,"
            "\"phone\":\"%s\","
            "\"cell\":{\"lac\":\"%s\",\"tac\":\"%s\",\"cid_hex\":\"%s\","
            "\"bandwidth\":\"%s\",\"pathloss\":\"%s\",\"txpower\":\"%s\","
            "\"cqi\":\"%s\",\"uecat\":\"%s\",\"volte\":\"%s\",\"mimo\":\"%s\","
            "\"rxdiv\":\"%s\",\"antports\":\"%s\","
            "\"s1band\":\"%s\",\"s1pci\":%d,\"s1earfcn\":%d,\"s1state\":\"%s\","
            "\"s2band\":\"%s\",\"s2pci\":%d,\"s2earfcn\":%d,\"s2state\":\"%s\","
            "\"s3band\":\"%s\",\"s3pci\":%d,\"s3earfcn\":%d,\"s3state\":\"%s\","
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
            "\"cpu_core_busy\":%s,\"cpu_top\":%s}\n",
            (long)time(NULL),
            tele_state, tele_modem,
            li.csq,li.ber,li.rsrp,li.rsrq,li.sinr,li.rssi,li.pci,
            li.band,li.ca,li.mode,li.oper,li.ip,li.modem,li.temp,li.signal_pct,li.nca,
            li.conn_time,li.rx,li.tx,li.apn,li.fw,li.therm,li.simslot,li.roaming,
            li.cid,li.enbid,li.mcc,li.mnc,li.earfcn,li.reg,li.phone,
            li.lac,li.tac,li.cid_hex,li.bandwidth,li.pathloss,li.txpower,
            li.cqi,li.uecat,li.volte,li.mimo,li.rxdiv,li.antports,
            li.s1band,li.s1pci,li.s1earfcn,li.s1state,
            li.s2band,li.s2pci,li.s2earfcn,li.s2state,
            li.s3band,li.s3pci,li.s3earfcn,li.s3state,
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
            cpu_b, cpu_core_count(), core_json, top_json);

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
