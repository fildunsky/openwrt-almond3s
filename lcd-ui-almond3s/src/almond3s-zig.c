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
    static unsigned char seq;
    unsigned char body[128];
    int n = 0;
    body[n++] = (unsigned char)(((tx_num & 7) << 4) | (rx_ack & 7));
    unsigned char pl[64];
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
    for (int i = 0; i < 160 && !done; i++) {
        int pn = ezsp_read(pl, sizeof pl, 500);
        if (!pn) continue;
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

    int init = -1;
    int scanning = !strcmp(cmd, "escan") || !strcmp(cmd, "ascan");
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
               "\"netinit\":%d,\"stack\":\"%d.%d.%d.%d\"}\n",
               ver, reason, proto, stype, init,
               (sver >> 12) & 15, (sver >> 8) & 15, (sver >> 4) & 15, sver & 15);
    } else if (!strcmp(cmd, "escan")) {
        scan(0, argc > 2 ? atoi(argv[2]) : 3, 0x07FFF800u);
    } else if (!strcmp(cmd, "ascan")) {
        scan(1, argc > 2 ? atoi(argv[2]) : 5, 0x07FFF800u);
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
