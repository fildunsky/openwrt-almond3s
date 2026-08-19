/*
 * almond3s-zig - разговор с Zigbee-чипом EM357 на /dev/ttyS2 (57600 8N1).
 *
 * Чип отвечает по ASH v2 и EZSP v4 (EmberZNet 5.1.0) - это слишком старая
 * версия для zigbee2mqtt и ZHA, поэтому говорим с ним сами. Умеет:
 *   info   - версия протокола и стека
 *   escan  - энергоскан каналов 11..26 (RSSI по каждому)
 *   ascan  - активный скан: какие сети Zigbee слышно вокруг
 *   form   - поднять свою сеть (PAN, канал, мощность из аргументов)
 *   leave  - выйти из сети
 * Вывод - JSON в stdout, его разбирает интерфейс.
 *
 * Кадры приходят с мусором в начале (0x00 от брейка, XON), поэтому тело
 * ищем перебором смещения по сходящемуся CRC. Порт открываем неблокирующим:
 * иначе open() ждёт несущую, которой на этом UART нет.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <sys/select.h>
#include <time.h>
#include <sys/file.h>
#include <signal.h>

static int fd;
static unsigned char rx_ack, tx_num;

static unsigned short crc16(const unsigned char *d, int n)
{
    unsigned short c = 0xFFFF;
    for (int i = 0; i < n; i++) {
        c ^= (unsigned short)d[i] << 8;
        for (int b = 0; b < 8; b++)
            c = (c & 0x8000) ? (unsigned short)((c << 1) ^ 0x1021) : (unsigned short)(c << 1);
    }
    return c;
}

static void put_stuffed(unsigned char *out, int *n, unsigned char b)
{
    if (b == 0x7E || b == 0x7D || b == 0x11 || b == 0x13 || b == 0x18 || b == 0x1A) {
        out[(*n)++] = 0x7D;
        out[(*n)++] = b ^ 0x20;
    } else {
        out[(*n)++] = b;
    }
}

static void send_frame(const unsigned char *body, int len)
{
    unsigned char out[512];
    int n = 0;
    unsigned short c = crc16(body, len);
    for (int i = 0; i < len; i++) put_stuffed(out, &n, body[i]);
    put_stuffed(out, &n, (unsigned char)(c >> 8));
    put_stuffed(out, &n, (unsigned char)(c & 0xFF));
    out[n++] = 0x7E;
    if (write(fd, out, n) < 0) perror("write");
}

static void ash_ack(void)
{
    unsigned char body[1] = { (unsigned char)(0x80 | (rx_ack & 7)) };
    send_frame(body, 1);
}

static void mask_data(unsigned char *d, int n)
{
    unsigned char r = 0x42;
    for (int i = 0; i < n; i++) {
        d[i] ^= r;
        r = (r & 1) ? (unsigned char)((r >> 1) ^ 0xB8) : (unsigned char)(r >> 1);
    }
}

static void ezsp_cmd(unsigned char frame_id, const unsigned char *par, int parlen)
{
    if (parlen < 0) parlen = 0;
    if (parlen > 160) parlen = 160;
    static unsigned char seq;
    unsigned char body[192];
    int n = 0;
    body[n++] = (unsigned char)(((tx_num & 7) << 4) | (rx_ack & 7));
    unsigned char pl[176];
    int pn = 0;
    pl[pn++] = seq++;
    pl[pn++] = 0x00;
    pl[pn++] = frame_id;
    memcpy(pl + pn, par, parlen);
    pn += parlen;
    mask_data(pl, pn);
    memcpy(body + n, pl, pn);
    n += pn;
    send_frame(body, n);
    tx_num = (unsigned char)((tx_num + 1) & 7);
}

/* Читает один кадр до флага 0x7E. 0 - таймаут. */
static int read_frame(unsigned char *out, int max, int ms)
{
    int n = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        fd_set r;
        FD_ZERO(&r);
        FD_SET(fd, &r);
        struct timeval tv = { 0, 50000 };
        if (select(fd + 1, &r, NULL, NULL, &tv) > 0) {
            unsigned char b;
            if (read(fd, &b, 1) == 1) {
                if (b == 0x7E) { if (n) return n; }
                else if (n < max) out[n++] = b;
            }
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long el = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
        if (el > ms) return 0;
    }
}

static int unstuff(const unsigned char *in, int n, unsigned char *out)
{
    int m = 0, esc = 0;
    for (int i = 0; i < n; i++) {
        if (esc) { out[m++] = in[i] ^ 0x20; esc = 0; }
        else if (in[i] == 0x7D) esc = 1;
        else if (in[i] == 0x1A || in[i] == 0x11 || in[i] == 0x13) continue;
        else out[m++] = in[i];
    }
    return m;
}

/* Кадр может прийти с мусором в начале (0x00 от брейка, XON/XOFF).
   Ищем смещение, на котором сходится CRC. Возвращает длину тела без CRC. */
static int frame_body(const unsigned char *f, int m, const unsigned char **body)
{
    for (int off = 0; off < 4 && off + 3 <= m; off++) {
        int len = m - off - 2;
        if (len < 1) break;
        unsigned short c = crc16(f + off, len);
        if (((c >> 8) & 0xFF) == f[off + len] && (c & 0xFF) == f[off + len + 1]) {
            *body = f + off;
            return len;
        }
    }
    return 0;
}

/* --- Телеметрия в эфир ---------------------------------------------------
 * Кладём поля записями [id, длина, значение] - компактно, но с однозначным
 * соответствием ZCL: у каждого id в контракте прописан свой кластер и атрибут
 * (батарея - 0x0001/0x0021, температура - 0x0402/0x0000, остальное в
 * производительском 0xFC00). Если чип однажды заговорит по стандарту, отчёты
 * соберутся из тех же записей без смены формата.
 */
#define T_SIG 0x01
#define T_RSRP 0x02
#define T_BATT 0x03
#define T_CHG 0x04
#define T_CPU 0x05
#define T_MEM 0x06
#define T_DISK 0x07
#define T_UP 0x08
#define T_WIFI 0x09
#define T_PING 0x0A
#define T_SMS 0x0B
#define T_RX 0x0C
#define T_TX 0x0D
#define T_TEMP 0x0E
#define T_VPN 0x0F

static const struct { unsigned char id; const char *key; int width; } TELE[] = {
    { T_SIG, "sig", 1 }, { T_RSRP, "rsrp", 1 }, { T_BATT, "batt", 1 },
    { T_CHG, "chg", 1 }, { T_CPU, "cpu", 1 }, { T_MEM, "mem", 1 },
    { T_DISK, "disk", 1 }, { T_UP, "up", 2 }, { T_WIFI, "wifi", 1 },
    { T_PING, "ping", 2 }, { T_SMS, "sms", 1 }, { T_RX, "rx", 4 },
    { T_TX, "tx", 4 }, { T_TEMP, "temp", 1 }, { T_VPN, "vpn", 1 },
};

static long jnum(const char *buf, const char *key, long dflt)
{
    char pat[48];
    snprintf(pat, sizeof pat, "\"%s\":", key);
    const char *p = strstr(buf, pat);
    if (!p) return dflt;
    p += strlen(pat);
    while (*p == ' ' || *p == '"') p++;
    return strtol(p, NULL, 10);
}

static int tele_pack(unsigned char *out, int max)
{
    char buf[1024];
    const char *path = getenv("ZIG_TELE") ? getenv("ZIG_TELE") : "/tmp/lcd_zig_tele.json";
    FILE *f = fopen(path, "r");
    int n = 0;
    if (!f) return 0;
    size_t got = fread(buf, 1, sizeof buf - 1, f);
    buf[got] = 0;
    fclose(f);
    for (unsigned i = 0; i < sizeof TELE / sizeof TELE[0]; i++) {
        long v = jnum(buf, TELE[i].key, 0x7FFFFFFF);
        if (v == 0x7FFFFFFF) continue;
        if (n + 2 + TELE[i].width > max) break;
        out[n++] = TELE[i].id;
        out[n++] = (unsigned char)TELE[i].width;
        for (int b = 0; b < TELE[i].width; b++)
            out[n++] = (unsigned char)((v >> (8 * b)) & 0xFF);
    }
    return n;
}

/* Разбор принятой телеметрии в JSON для интерфейса. */
static void tele_unpack(const unsigned char *in, int n, char *out, int max)
{
    int off = 0, first = 1;
    out[0] = 0;
    for (int i = 0; i + 2 <= n; ) {
        int id = in[i], w = in[i + 1];
        if (w < 1 || w > 4 || i + 2 + w > n) break;
        long v = 0;
        for (int b = 0; b < w; b++) v |= (long)in[i + 2 + b] << (8 * b);
        if (w == 1 && (id == T_RSRP || id == T_TEMP)) v = (signed char)v;
        if (w == 2 && v > 32767) v -= 65536;
        const char *key = NULL;
        for (unsigned k = 0; k < sizeof TELE / sizeof TELE[0]; k++)
            if (TELE[k].id == id) key = TELE[k].key;
        if (key)
            off += snprintf(out + off, max - off, "%s\"%s\":%ld", first ? "" : ",", key, v),
            first = 0;
        i += 2 + w;
        if (off > max - 24) break;
    }
}

static volatile int stop_flag;

static void on_term(int sig)
{
    (void)sig;
    stop_flag = 1;
}

static int port_open(const char *dev)
{
    struct termios t;
    fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, 0);
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    cfsetispeed(&t, B57600);
    cfsetospeed(&t, B57600);
    t.c_cflag |= CLOCAL | CREAD;
    t.c_cflag &= ~CRTSCTS;
    t.c_iflag &= ~(IXON | IXOFF | IXANY);
    tcsetattr(fd, TCSANOW, &t);
    tcflush(fd, TCIOFLUSH);
    return 0;
}

/* Ждём кадр с данными и отдаём распакованную полезную нагрузку EZSP.
   Возвращает её длину или 0 по таймауту. */
static int ezsp_read(unsigned char *pl, int max, int ms)
{
    unsigned char raw[512], f[512];
    const unsigned char *b;
    int n = read_frame(raw, sizeof raw, ms);
    if (!n) return 0;
    int m = unstuff(raw, n, f);
    int bl = frame_body(f, m, &b);
    if (bl < 4 || (b[0] & 0x80)) return 0;
    int pn = bl - 1;
    if (pn > max) pn = max;
    memcpy(pl, b + 1, pn);
    mask_data(pl, pn);
    rx_ack = (unsigned char)((((b[0] >> 4) & 7) + 1) & 7);
    ash_ack();
    return pn;
}

static int ash_reset(int *ver, int *reason)
{
    unsigned char raw[512], f[512];
    const unsigned char *b;
    unsigned char rst[5] = { 0x1A, 0xC0, 0x38, 0xBC, 0x7E };
    if (write(fd, rst, 5) < 0) return 0;
    for (int i = 0; i < 8; i++) {
        int n = read_frame(raw, sizeof raw, 700);
        if (!n) continue;
        int m = unstuff(raw, n, f);
        int bl = frame_body(f, m, &b);
        if (bl >= 3 && b[0] == 0xC1) {
            *ver = b[1];
            *reason = b[2];
            tx_num = 0;
            rx_ack = 0;
            return 1;
        }
    }
    return 0;
}

static int ezsp_version(int *proto, int *stack_type, int *stack_ver)
{
    unsigned char par[1] = { 4 }, pl[64];
    ezsp_cmd(0x00, par, 1);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 800);
        if (pn >= 7 && pl[2] == 0x00) {
            *proto = pl[3];
            *stack_type = pl[4];
            *stack_ver = (pl[6] << 8) | pl[5];
            return 1;
        }
    }
    return 0;
}

/* После сброса NCP стек не помнит, что он в сети: параметры лежат в NV, но
   поднять их надо явно. Иначе networkState всегда отвечает «нет сети». */
static int network_init(void)
{
    unsigned char pl[64];
    ezsp_cmd(0x17, NULL, 0);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x17) return pl[3];
    }
    return -1;
}

/* Настройки стека живут только до сброса чипа, а сбрасываем мы его каждым
   запуском - значит выставляем заново. Профиль по умолчанию 0, и с ним стек
   не умеет ZigBee PRO: запрос маяка не уходит в эфир. */
static int set_cfg(int id, int val)
{
    unsigned char pl[64], d[3];
    d[0] = (unsigned char)id;
    d[1] = (unsigned char)(val & 0xFF);
    d[2] = (unsigned char)((val >> 8) & 0xFF);
    ezsp_cmd(0x53, d, 3);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 600);
        if (pn >= 4 && pl[2] == 0x53) return pl[3];
    }
    return -1;
}

static void die(const char *msg)
{
    printf("{\"ok\":0,\"error\":\"%s\"}\n", msg);
    exit(1);
}

static int scan(int active, int duration, unsigned int mask)
{
    unsigned char par[6], pl[64];
    par[0] = (unsigned char)(active ? 1 : 0);
    par[1] = (unsigned char)(mask & 0xFF);
    par[2] = (unsigned char)((mask >> 8) & 0xFF);
    par[3] = (unsigned char)((mask >> 16) & 0xFF);
    par[4] = (unsigned char)((mask >> 24) & 0xFF);
    par[5] = (unsigned char)duration;
    ezsp_cmd(0x1A, par, 6);

    int first = 1, done = 0, items = 0;
    printf("{\"ok\":1,\"%s\":[", active ? "networks" : "channels");
    int dbg = getenv("ZIG_DEBUG") != NULL;
    for (int i = 0; i < 160 && !done; i++) {
        int pn = ezsp_read(pl, sizeof pl, 500);
        if (!pn) continue;
        if (dbg) {
            fprintf(stderr, "кадр id=0x%02X len=%d:", pl[2], pn);
            for (int k = 0; k < pn && k < 24; k++) fprintf(stderr, " %02X", pl[k]);
            fprintf(stderr, "\n");
        }
        if (!active && pn >= 5 && pl[2] == 0x48) {
            printf("%s{\"ch\":%d,\"rssi\":%d}", first ? "" : ",", pl[3], (signed char)pl[4]);
            first = 0;
            items++;
        } else if (active && pn >= 17 && pl[2] == 0x1B) {
            printf("%s{\"ch\":%d,\"pan\":%d,\"join\":%d,\"lqi\":%d,\"rssi\":%d,"
                   "\"epan\":\"%02X%02X%02X%02X%02X%02X%02X%02X\"}",
                   first ? "" : ",", pl[3], pl[4] | (pl[5] << 8), pl[14],
                   pl[pn - 2], (signed char)pl[pn - 1],
                   pl[13], pl[12], pl[11], pl[10], pl[9], pl[8], pl[7], pl[6]);
            first = 0;
            items++;
        } else if (pn >= 4 && pl[2] == 0x1C) {
            done = 1;
        }
    }
    printf("],\"count\":%d,\"done\":%d}\n", items, done);
    return items;
}

/* Свою сеть поднимаем в два шага: сперва ключи (setInitialSecurityState),
   затем formNetwork с параметрами. Ключ сети берём из аргумента - на обоих
   аппаратах он должен совпадать, иначе они друг друга не пустят. */
static int form(int pan, int channel, int power, const unsigned char *key)
{
    unsigned char par[64], pl[64];
    int n = 0;

    par[n++] = 0x00; par[n++] = 0x02; par[n++] = 0x00; par[n++] = 0x00;  /* bitmask: HAVE_NETWORK_KEY */
    memcpy(par + n, key, 16); n += 16;                                    /* preconfigured key */
    memcpy(par + n, key, 16); n += 16;                                    /* network key */
    par[n++] = 0x00;                                                      /* sequence number */
    memset(par + n, 0, 8); n += 8;                                        /* trust center EUI64 */
    ezsp_cmd(0x68, par, n);
    int st = -1;
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 800);
        if (pn >= 4 && pl[2] == 0x68) { st = pl[3]; break; }
    }

    n = 0;
    for (int i = 0; i < 8; i++) par[n++] = (unsigned char)(0xA5 - i);      /* extended PAN */
    par[n++] = (unsigned char)(pan & 0xFF);
    par[n++] = (unsigned char)((pan >> 8) & 0xFF);
    par[n++] = (unsigned char)power;
    par[n++] = (unsigned char)channel;
    par[n++] = 0x00;                                                      /* joinMethod */
    par[n++] = 0x00; par[n++] = 0x00;                                     /* nwkManagerId */
    par[n++] = 0x00;                                                      /* nwkUpdateId */
    unsigned int chmask = 1u << channel;
    par[n++] = (unsigned char)(chmask & 0xFF);
    par[n++] = (unsigned char)((chmask >> 8) & 0xFF);
    par[n++] = (unsigned char)((chmask >> 16) & 0xFF);
    par[n++] = (unsigned char)((chmask >> 24) & 0xFF);
    ezsp_cmd(0x1E, par, n);

    int fst = -1;
    for (int i = 0; i < 20; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x1E) { fst = pl[3]; }
        if (pn >= 4 && pl[2] == 0x19) { fst = 0; break; }                 /* stackStatusHandler */
    }
    int pj = -1;
    if (fst == 0) {
        unsigned char d1[1] = { 0xFF };
        ezsp_cmd(0x22, d1, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 700);
            if (pn >= 4 && pl[2] == 0x22) { pj = pl[3]; break; }
        }
    }
    printf("{\"ok\":%d,\"security\":%d,\"form\":%d,\"permit\":%d,\"pan\":%d,\"ch\":%d}\n",
           fst == 0 ? 1 : 0, st, fst, pj, pan, channel);
    return fst == 0;
}

/* networkState (0x18) + getNetworkParameters (0x28): в какой сети чип сейчас. */
static void state(void)
{
    unsigned char pl[64];
    int ns = -1, ntype = -1, pan = -1, ch = -1, pw = 0;
    ezsp_cmd(0x18, NULL, 0);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x18) { ns = pl[3]; break; }
    }
    ezsp_cmd(0x28, NULL, 0);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 25 && pl[2] == 0x28) {
            ntype = pl[4];
            pan = pl[13] | (pl[14] << 8);
            pw = (signed char)pl[15];
            ch = pl[16];
            break;
        }
    }
    printf("{\"ok\":1,\"state\":%d,\"node\":%d,\"pan\":%d,\"ch\":%d,\"power\":%d}\n",
           ns, ntype, pan, ch, pw);
}

static void leave(void)
{
    unsigned char pl[64];
    ezsp_cmd(0x20, NULL, 0);
    int st = -1;
    for (int i = 0; i < 8; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x20) { st = pl[3]; break; }
    }
    printf("{\"ok\":%d,\"leave\":%d}\n", st == 0 ? 1 : 0, st);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *cmd = argc > 1 ? argv[1] : "info";
    const char *dev = getenv("ZIG_TTY") ? getenv("ZIG_TTY") : "/dev/ttyS2";

    /* Две копии воруют друг у друга байты из порта - пускаем по одной. */
    int lk = open("/var/lock/almond3s-zig.lock", O_CREAT | O_RDWR, 0600);
    if (lk >= 0 && flock(lk, LOCK_EX | LOCK_NB) != 0) die("занято");

    if (port_open(dev) < 0) die("нет порта");

    int ver = 0, reason = 0;
    if (!ash_reset(&ver, &reason)) die("чип молчит");

    int proto = 0, stype = 0, sver = 0;
    if (!ezsp_version(&proto, &stype, &sver)) die("нет ответа EZSP");

    int prof = set_cfg(0x0C, 2);      /* stack profile: ZigBee PRO */
    set_cfg(0x0D, 5);                 /* security level */
    /* Режим передатчика: у модуля с внешним усилителем нулевой (обычный) путь
       не работает. 0 обычный, 1 boost, 2 альтернативный выход, 3 оба. */
    const char *txm = getenv("ZIG_TXMODE");
    int txmode = txm ? atoi(txm) : 3;
    int txst = set_cfg(0x17, txmode);

    /* Заводской сервер зовёт setRadioPower - попробуем и мы. Идентификатор
       кадра берём из окружения, чтобы перебирать без пересборки. */
    if (getenv("ZIG_RHO")) {
        unsigned char d[3] = { 0x0E, 1, (unsigned char)atoi(getenv("ZIG_RHO")) }, pl[64];
        ezsp_cmd(0xAB, d, 3);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0xAB) { fprintf(stderr, "radioHoldOff=%d -> %d\n", d[2], pl[3]); break; }
        }
    }

    const char *rp = getenv("ZIG_RPOW");
    int rp_id = getenv("ZIG_RPID") ? (int)strtol(getenv("ZIG_RPID"), NULL, 0) : 0x99;
    int rp_st = -2;
    if (rp) {
        unsigned char d[1] = { (unsigned char)atoi(rp) }, pl[64];
        ezsp_cmd((unsigned char)rp_id, d, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4) { rp_st = (pl[2] == rp_id) ? pl[3] : -3; break; }
        }
        fprintf(stderr, "setRadioPower(id=0x%02X) -> %d\n", rp_id, rp_st);
    }

    int init = -1;
    /* mfglib работает только на неподнятом стеке, поэтому «tone» тоже без
       networkInit - как и сканы. */
    int scanning = !strcmp(cmd, "escan") || !strcmp(cmd, "ascan")
                || !strcmp(cmd, "tone") || !strcmp(cmd, "listen")
                || !strcmp(cmd, "send") || !strcmp(cmd, "beacon");
    if (!scanning) {
        init = network_init();
        /* Стеку нужно мгновение, чтобы доложить о поднятой сети. */
        if (init == 0) {
            unsigned char pl[64];
            for (int i = 0; i < 4; i++) ezsp_read(pl, sizeof pl, 400);
        }
    }

    if (!strcmp(cmd, "info")) {
        printf("{\"ok\":1,\"ash\":%d,\"reset\":%d,\"ezsp\":%d,\"stack_type\":%d,"
               "\"netinit\":%d,\"profile\":%d,\"txmode\":%d,\"txstatus\":%d,"
               "\"stack\":\"%d.%d.%d.%d\"}\n",
               ver, reason, proto, stype, init, prof, txmode, txst,
               (sver >> 12) & 15, (sver >> 8) & 15, (sver >> 4) & 15, sver & 15);
    } else if (!strcmp(cmd, "escan")) {
        unsigned int mk = argc > 3 ? (1u << atoi(argv[3])) : 0x07FFF800u;
        scan(0, argc > 2 ? atoi(argv[2]) : 3, mk);
    } else if (!strcmp(cmd, "ascan")) {
        unsigned int mk = argc > 3 ? (1u << atoi(argv[3])) : 0x07FFF800u;
        scan(1, argc > 2 ? atoi(argv[2]) : 5, mk);
    } else if (!strcmp(cmd, "form")) {
        int pan = argc > 2 ? (int)strtol(argv[2], NULL, 0) : 0x1A2B;
        int ch  = argc > 3 ? atoi(argv[3]) : 15;
        int pw  = argc > 4 ? atoi(argv[4]) : 8;
        unsigned char key[16];
        for (int i = 0; i < 16; i++) key[i] = (unsigned char)(0x30 + i);
        if (argc > 5 && strlen(argv[5]) >= 32)
            for (int i = 0; i < 16; i++) {
                char b[3] = { argv[5][i * 2], argv[5][i * 2 + 1], 0 };
                key[i] = (unsigned char)strtol(b, NULL, 16);
            }
        form(pan, ch, pw, key);
    } else if (!strcmp(cmd, "beacon")) {
        /* Фоновый маячок: слушаем канал и раз в период кричим своё имя.
           Услышанных соседей складываем в JSON для страницы «Соседи».
           Стек не поднимаем - заводская библиотека работает только на спящем. */
        int ch = argc > 2 ? atoi(argv[2]) : 20;
        int period = argc > 3 ? atoi(argv[3]) : 10;
        const char *me = argc > 4 ? argv[4] : "almond";
        const char *out = getenv("ZIG_PEERS") ? getenv("ZIG_PEERS") : "/tmp/lcd_zig_peers.json";
        unsigned char pl[128], d[130];
        int r_start = -1, r_ch = -1;

        signal(SIGTERM, on_term);
        signal(SIGINT, on_term);

        d[0] = 1;
        ezsp_cmd(0x83, d, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x83) { r_start = pl[3]; break; }
        }
        d[0] = (unsigned char)ch;
        ezsp_cmd(0x8A, d, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x8A) { r_ch = pl[3]; break; }
        }
        if (r_start != 0 || r_ch != 0) {
            printf("{\"ok\":0,\"start\":%d,\"channel\":%d}\n", r_start, r_ch);
            return 1;
        }

        /* Короткий адрес выводим из имени - лишь бы аппараты отличались. */
        unsigned int myid = 0;
        for (const char *q = me; *q; q++) myid = myid * 31u + (unsigned char)*q;
        myid = (myid & 0x7FFF) | 0x0001;

        struct { char name[24]; int rssi, lqi; long seen; int seq; char tele[320]; } pr[8];
        int npr = 0;
        memset(pr, 0, sizeof pr);
        long last_tx = 0, last_save = 0;
        int seq = 0;
        while (!stop_flag) {
            long now = (long)time(NULL);
            if (now - last_tx >= period) {
                last_tx = now;
                int tl = (int)strlen(me);
                if (tl > 20) tl = 20;
                unsigned char tele[80];
                int tn = tele_pack(tele, sizeof tele);
                /* Кадр 802.15.4: без заголовка радио приёмника фильтрует
                   пакет по мусору в первых байтах. FCF = кадр данных со
                   сжатым PAN, адреса короткие, получатель широковещательный. */
                int n = 0;
                unsigned char body[128];
                body[n++] = 0x41;                       /* FCF: данные, сжатый PAN */
                body[n++] = 0x88;                       /* FCF: адреса короткие */
                body[n++] = (unsigned char)seq++;
                body[n++] = 0xFF; body[n++] = 0xFF;     /* PAN получателя: всем */
                body[n++] = 0xFF; body[n++] = 0xFF;     /* кому: всем */
                body[n++] = (unsigned char)(myid & 0xFF);
                body[n++] = (unsigned char)((myid >> 8) & 0xFF);
                body[n++] = 0x41;                       /* наша метка полезной части */
                body[n++] = 0x01;                       /* версия формата */
                body[n++] = (unsigned char)tl;
                memcpy(body + n, me, tl); n += tl;
                memcpy(body + n, tele, tn); n += tn;
                body[n++] = 0; body[n++] = 0;           /* место под CRC радио */
                d[0] = (unsigned char)n;
                memcpy(d + 1, body, n);
                ezsp_cmd(0x89, d, n + 1);

                for (int i = 0; i < 3; i++) {
                    int pn = ezsp_read(pl, sizeof pl, 200);
                    if (pn >= 4 && pl[2] == 0x89) {
                        if (getenv("ZIG_DEBUG"))
                            fprintf(stderr, "маячок: длина %d -> статус %d\n", n, pl[3]);
                        break;
                    }
                }
                /* После передачи приёмник глохнет: поднимаем библиотеку заново
                   с включённым обратным вызовом и возвращаем канал. */
                int s_end = -1, s_start = -1, s_ch = -1;
                ezsp_cmd(0x84, NULL, 0);
                for (int i = 0; i < 3; i++) {
                    int pn = ezsp_read(pl, sizeof pl, 300);
                    if (pn >= 4 && pl[2] == 0x84) { s_end = pl[3]; break; }
                }
                d[0] = 1;
                ezsp_cmd(0x83, d, 1);
                for (int i = 0; i < 3; i++) {
                    int pn = ezsp_read(pl, sizeof pl, 300);
                    if (pn >= 4 && pl[2] == 0x83) { s_start = pl[3]; break; }
                }
                d[0] = (unsigned char)ch;
                ezsp_cmd(0x8A, d, 1);
                for (int i = 0; i < 3; i++) {
                    int pn = ezsp_read(pl, sizeof pl, 300);
                    if (pn >= 4 && pl[2] == 0x8A) { s_ch = pl[3]; break; }
                }
                if (getenv("ZIG_DEBUG"))
                    fprintf(stderr, "возврат в приём: end=%d start=%d ch=%d\n",
                            s_end, s_start, s_ch);
            }
            int pn = ezsp_read(pl, sizeof pl, 700);
            if (pn > 0 && getenv("ZIG_DEBUG"))
                fprintf(stderr, "приём: pn=%d id=0x%02X метка=0x%02X len=%d\n",
                        pn, pn > 2 ? pl[2] : 0, pn > 6 ? pl[6] : 0, pn > 5 ? pl[5] : 0);
            /* Кадр: [lqi, rssi, длина] + MAC-заголовок 9 байт + наша часть */
            if (pn >= 21 && pl[2] == 0x8E && pl[6] == 0x41 && pl[7] == 0x88
                && pl[15] == 0x41) {
                int lqi = pl[3], rssi = (signed char)pl[4], len = pl[5];
                int tl = pl[17];
                if (tl < 0 || tl > 20) tl = 0;
                char nm[24];
                int k = 0;
                for (; k < tl && 18 + k < pn; k++) {
                    unsigned char c = pl[18 + k];
                    nm[k] = (c >= 32 && c < 127) ? (char)c : '.';
                }
                nm[k] = 0;
                char mj[320];
                int tstart = 18 + tl, tlen = len - 14 - tl;
                if (tlen < 0) tlen = 0;
                if (tstart + tlen > pn) tlen = pn - tstart;
                tele_unpack(pl + tstart, tlen, mj, sizeof mj);
                if (k > 0 && strcmp(nm, me) != 0) {
                    int idx = -1;
                    for (int j = 0; j < npr; j++) if (!strcmp(pr[j].name, nm)) idx = j;
                    if (idx < 0 && npr < 8) { idx = npr++; snprintf(pr[idx].name, sizeof pr[idx].name, "%s", nm); }
                    if (idx >= 0) {
                        pr[idx].rssi = rssi;
                        pr[idx].lqi = lqi;
                        pr[idx].seen = (long)time(NULL);
                        pr[idx].seq = pl[7];
                        snprintf(pr[idx].tele, sizeof pr[idx].tele, "%s", mj);
                    }
                }
            }
            now = (long)time(NULL);
            if (now - last_save >= 2) {
                last_save = now;
                char tmp[128];
                snprintf(tmp, sizeof tmp, "%s.tmp", out);
                FILE *f = fopen(tmp, "w");
                if (f) {
                    fprintf(f, "{\"ok\":1,\"me\":\"%s\",\"ch\":%d,\"ts\":%ld,\"peers\":[", me, ch, now);
                    for (int j = 0; j < npr; j++)
                        fprintf(f, "%s{\"name\":\"%s\",\"rssi\":%d,\"lqi\":%d,\"age\":%ld,\"m\":{%s}}",
                                j ? "," : "", pr[j].name, pr[j].rssi, pr[j].lqi,
                                now - pr[j].seen, pr[j].tele);
                    fprintf(f, "]}\n");
                    fclose(f);
                    rename(tmp, out);
                }
            }
        }
        ezsp_cmd(0x84, NULL, 0);
        ezsp_read(pl, sizeof pl, 400);
    } else if (!strcmp(cmd, "listen") || !strcmp(cmd, "send")) {
        /* Заводская библиотека умеет и передавать, и принимать сырые пакеты в
           том же диапазоне. Стек для этого не нужен - а он у нас и не передаёт. */
        int ch = argc > 2 ? atoi(argv[2]) : 20;
        int sec = argc > 3 ? atoi(argv[3]) : 10;
        int sending = !strcmp(cmd, "send");
        const char *text = argc > 4 ? argv[4] : "ALMOND";
        unsigned char pl[128], d[130];
        int r_start = -1, r_ch = -1;

        d[0] = (unsigned char)(sending ? 0 : 1);      /* rxCallback */
        ezsp_cmd(0x83, d, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x83) { r_start = pl[3]; break; }
        }
        d[0] = (unsigned char)ch;
        ezsp_cmd(0x8A, d, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x8A) { r_ch = pl[3]; break; }
        }
        if (sending) {
            d[0] = 0; d[1] = 3;
            ezsp_cmd(0x8C, d, 2);
            ezsp_read(pl, sizeof pl, 600);
        }

        printf("{\"ok\":%d,\"start\":%d,\"channel\":%d,\"ch\":%d,\"mode\":\"%s\"}\n",
               (r_start == 0 && r_ch == 0) ? 1 : 0, r_start, r_ch, ch,
               sending ? "send" : "listen");

        time_t t0 = time(NULL);
        int seq = 0, heard = 0;
        while (time(NULL) - t0 < sec) {
            if (sending) {
                int tl = (int)strlen(text);
                if (tl > 100) tl = 100;
                d[0] = (unsigned char)(tl + 4);        /* метка, номер, текст, 2 байта CRC */
                d[1] = 0x41;                            /* метка «свой» */
                d[2] = (unsigned char)seq++;
                memcpy(d + 3, text, tl);
                d[3 + tl] = 0; d[4 + tl] = 0;
                ezsp_cmd(0x89, d, tl + 5);
                for (int i = 0; i < 3; i++) {
                    int pn = ezsp_read(pl, sizeof pl, 300);
                    if (pn >= 4 && pl[2] == 0x89) {
                        printf("{\"sent\":%d,\"status\":%d}\n", seq, pl[3]);
                        break;
                    }
                }
                sleep(1);
            } else {
                int pn = ezsp_read(pl, sizeof pl, 900);
                if (pn >= 6 && pl[2] == 0x8E) {
                    int lqi = pl[3], rssi = (signed char)pl[4], len = pl[5];
                    if (getenv("ZIG_DEBUG")) {
                        fprintf(stderr, "сырой кадр (pn=%d, len=%d):", pn, len);
                        for (int k = 6; k < pn && k < 40; k++) fprintf(stderr, " %02X", pl[k]);
                        fprintf(stderr, "\n");
                    }
                    char txt[64] = "";
                    int show = len > 2 ? len - 2 : 0;      /* хвост - CRC радио */
                    for (int k = 0; k < show && k < 40 && 6 + k < pn; k++) {
                        unsigned char c = pl[6 + k];
                        txt[k] = (c >= 32 && c < 127) ? (char)c : '.';
                    }
                    printf("{\"heard\":1,\"lqi\":%d,\"rssi\":%d,\"len\":%d,\"data\":\"%s\"}\n",
                           lqi, rssi, len, txt);
                    heard++;
                }
            }
        }
        if (!sending) printf("{\"done\":1,\"heard\":%d}\n", heard);
        ezsp_cmd(0x84, NULL, 0);
        ezsp_read(pl, sizeof pl, 600);
    } else if (!strcmp(cmd, "getval")) {
        unsigned char pl[64], d[1] = { (unsigned char)(argc > 2 ? strtol(argv[2], NULL, 0) : 0x0E) };
        int stt = -1, len = 0;
        char hex[64] = "";
        ezsp_cmd(0xAA, d, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 700);
            if (pn >= 5 && pl[2] == 0xAA) {
                stt = pl[3]; len = pl[4];
                for (int k = 0; k < len && k < 16 && 5 + k < pn; k++)
                    snprintf(hex + strlen(hex), sizeof hex - strlen(hex), "%02X", pl[5 + k]);
                break;
            }
        }
        printf("{\"ok\":%d,\"id\":%d,\"status\":%d,\"len\":%d,\"value\":\"%s\"}\n",
               stt == 0 ? 1 : 0, d[0], stt, len, hex);
    } else if (!strcmp(cmd, "setval")) {
        unsigned char pl[64], d[3];
        d[0] = (unsigned char)(argc > 2 ? strtol(argv[2], NULL, 0) : 0x0E);
        d[1] = 1;
        d[2] = (unsigned char)(argc > 3 ? strtol(argv[3], NULL, 0) : 0);
        int stt = -1;
        ezsp_cmd(0xAB, d, 3);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 700);
            if (pn >= 4 && pl[2] == 0xAB) { stt = pl[3]; break; }
        }
        printf("{\"ok\":%d,\"id\":%d,\"v\":%d,\"status\":%d}\n",
               stt == 0 ? 1 : 0, d[0], d[2], stt);
    } else if (!strcmp(cmd, "cfg")) {
        /* getConfigurationValue по всем идентификаторам: ищем нули там, где
           стеку нужны буферы и профиль - без них передача невозможна. */
        unsigned char pl[64], d[1];
        printf("{\"ok\":1,\"cfg\":[");
        int first = 1;
        for (int id = 0; id <= 0x35; id++) {
            d[0] = (unsigned char)id;
            ezsp_cmd(0x52, d, 1);
            for (int i = 0; i < 4; i++) {
                int pn = ezsp_read(pl, sizeof pl, 400);
                if (pn >= 6 && pl[2] == 0x52) {
                    if (pl[3] == 0) {
                        printf("%s{\"id\":%d,\"v\":%d}", first ? "" : ",",
                               id, pl[4] | (pl[5] << 8));
                        first = 0;
                    }
                    break;
                }
            }
        }
        printf("]}\n");
    } else if (!strcmp(cmd, "setcfg")) {
        unsigned char pl[64], d[3];
        int id = argc > 2 ? (int)strtol(argv[2], NULL, 0) : 0;
        int val = argc > 3 ? (int)strtol(argv[3], NULL, 0) : 0;
        int stt = -1;
        d[0] = (unsigned char)id;
        d[1] = (unsigned char)(val & 0xFF);
        d[2] = (unsigned char)((val >> 8) & 0xFF);
        ezsp_cmd(0x53, d, 3);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x53) { stt = pl[3]; break; }
        }
        printf("{\"ok\":%d,\"id\":%d,\"v\":%d,\"status\":%d}\n",
               stt == 0 ? 1 : 0, id, val, stt);
    } else if (!strcmp(cmd, "tone")) {
        /* Заводская библиотека: включаем несущую на канале, чтобы проверить,
           работает ли передатчик вообще (соседний аппарат ловит энергосканом). */
        int ch = argc > 2 ? atoi(argv[2]) : 26;
        int sec = argc > 3 ? atoi(argv[3]) : 10;
        unsigned char pl[64], d[4];
        int r_start = -1, r_ch = -1, r_pow = -1, r_tone = -1;
        ezsp_cmd(0x83, (unsigned char[]){ 0 }, 1);
        for (int i = 0; i < 6; i++) { int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x83) { r_start = pl[3]; break; } }
        d[0] = (unsigned char)ch;
        ezsp_cmd(0x8A, d, 1);
        for (int i = 0; i < 6; i++) { int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x8A) { r_ch = pl[3]; break; } }
        d[0] = 0; d[1] = 3;
        ezsp_cmd(0x8C, d, 2);
        for (int i = 0; i < 6; i++) { int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x8C) { r_pow = pl[3]; break; } }
        ezsp_cmd(0x85, NULL, 0);
        for (int i = 0; i < 6; i++) { int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x85) { r_tone = pl[3]; break; } }
        printf("{\"ok\":%d,\"start\":%d,\"channel\":%d,\"power\":%d,\"tone\":%d,\"ch\":%d,\"sec\":%d}\n",
               r_tone == 0 ? 1 : 0, r_start, r_ch, r_pow, r_tone, ch, sec);
        time_t t0 = time(NULL);
        while (time(NULL) - t0 < sec) ezsp_read(pl, sizeof pl, 500);
        ezsp_cmd(0x86, NULL, 0);
        ezsp_read(pl, sizeof pl, 600);
        ezsp_cmd(0x84, NULL, 0);
        ezsp_read(pl, sizeof pl, 600);
    } else if (!strcmp(cmd, "hold")) {
        /* Держим сеть поднятой и приём открытым заданное число секунд, не
           закрывая порт: проверяем, не засыпает ли чип без хоста. */
        int sec = argc > 2 ? atoi(argv[2]) : 30;
        unsigned char pl[64], d1[1] = { 0xFF };
        int pj = -1;
        ezsp_cmd(0x22, d1, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 500);
            if (pn >= 4 && pl[2] == 0x22) { pj = pl[3]; break; }
        }
        printf("{\"ok\":1,\"netinit\":%d,\"permit\":%d,\"hold\":%d}\n", init, pj, sec);
        time_t t0 = time(NULL);
        while (time(NULL) - t0 < sec) ezsp_read(pl, sizeof pl, 500);
    } else if (!strcmp(cmd, "state")) {
        state();
    } else if (!strcmp(cmd, "leave")) {
        leave();
    } else {
        die("неизвестная команда");
    }
    /* Скан начинается со сброса чипа, а он роняет поднятую сеть: после скана
       поднимаем её обратно, иначе аппарат перестаёт отвечать на маяки соседей
       и сам становится невидимым. */
    if (scanning) network_init();
    close(fd);
    return 0;
}
