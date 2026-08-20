
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <sys/select.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <signal.h>
#include <mbedtls/aes.h>

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

static int ezsp_v8;

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
    if (ezsp_v8) {
        pl[pn++] = 0x00;
        pl[pn++] = 0x01;
        pl[pn++] = frame_id;
        pl[pn++] = 0x00;
    } else {
        pl[pn++] = 0x00;
        pl[pn++] = frame_id;
    }
    memcpy(pl + pn, par, parlen);
    pn += parlen;
    mask_data(pl, pn);
    memcpy(body + n, pl, pn);
    n += pn;
    send_frame(body, n);
    tx_num = (unsigned char)((tx_num + 1) & 7);
}

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

#define ZSEC_PLAIN 0x00
#define ZSEC_CCM   0x01
#define ZSEC_MIC   4

static unsigned char zkey[16];
static int zkey_ok;

static void zkey_load(void)
{
    const char *path = getenv("ZIG_KEY") ? getenv("ZIG_KEY") : "/tmp/.zig_key";
    char hex[64];
    FILE *f = fopen(path, "r");
    zkey_ok = 0;
    if (!f) return;
    if (fgets(hex, sizeof hex, f) && strlen(hex) >= 32) {
        for (int i = 0; i < 16; i++) {
            char b[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
            char *end;
            long v = strtol(b, &end, 16);
            if (end != b + 2) { fclose(f); return; }
            zkey[i] = (unsigned char)v;
        }
        zkey_ok = 1;
    }
    fclose(f);
}

static void zsec_nonce(unsigned char *n, unsigned int src, unsigned int ctr)
{
    memset(n, 0, 13);
    n[0] = (unsigned char)(src & 0xFF);
    n[1] = (unsigned char)((src >> 8) & 0xFF);
    n[2] = (unsigned char)(ctr & 0xFF);
    n[3] = (unsigned char)((ctr >> 8) & 0xFF);
    n[4] = (unsigned char)((ctr >> 16) & 0xFF);
    n[5] = (unsigned char)((ctr >> 24) & 0xFF);
    n[12] = ZSEC_CCM;
}

static void ccm_block(mbedtls_aes_context *a, unsigned char *x, const unsigned char *b)
{
    unsigned char t[16];
    for (int i = 0; i < 16; i++) t[i] = x[i] ^ b[i];
    mbedtls_aes_crypt_ecb(a, MBEDTLS_AES_ENCRYPT, t, x);
}

static void ccm_tag(mbedtls_aes_context *a, const unsigned char *nonce,
                    const unsigned char *aad, int aadlen,
                    const unsigned char *msg, int mlen, unsigned char *tag)
{
    unsigned char x[16] = {0}, b[16];
    int i;

    b[0] = (unsigned char)((aadlen ? 0x40 : 0x00) | (((4 - 2) / 2) << 3) | (2 - 1));
    memcpy(b + 1, nonce, 13);
    b[14] = (unsigned char)((mlen >> 8) & 0xFF);
    b[15] = (unsigned char)(mlen & 0xFF);
    ccm_block(a, x, b);

    if (aadlen) {
        int off = 0;
        memset(b, 0, 16);
        b[0] = (unsigned char)((aadlen >> 8) & 0xFF);
        b[1] = (unsigned char)(aadlen & 0xFF);
        for (i = 0; i < 14 && i < aadlen; i++) b[2 + i] = aad[i];
        ccm_block(a, x, b);
        off = i;
        while (off < aadlen) {
            memset(b, 0, 16);
            for (i = 0; i < 16 && off + i < aadlen; i++) b[i] = aad[off + i];
            ccm_block(a, x, b);
            off += i;
        }
    }
    for (int off = 0; off < mlen; off += 16) {
        memset(b, 0, 16);
        for (i = 0; i < 16 && off + i < mlen; i++) b[i] = msg[off + i];
        ccm_block(a, x, b);
    }
    memcpy(tag, x, ZSEC_MIC);
}

static void ccm_ctr(mbedtls_aes_context *a, const unsigned char *nonce,
                    unsigned char *data, int len, unsigned char *s0)
{
    unsigned char ctr[16], sblk[16];
    ctr[0] = (unsigned char)(2 - 1);
    memcpy(ctr + 1, nonce, 13);
    ctr[14] = 0; ctr[15] = 0;
    if (s0) {
        mbedtls_aes_crypt_ecb(a, MBEDTLS_AES_ENCRYPT, ctr, sblk);
        memcpy(s0, sblk, 16);
    }
    for (int off = 0, blk = 1; off < len; off += 16, blk++) {
        ctr[14] = (unsigned char)((blk >> 8) & 0xFF);
        ctr[15] = (unsigned char)(blk & 0xFF);
        mbedtls_aes_crypt_ecb(a, MBEDTLS_AES_ENCRYPT, ctr, sblk);
        for (int i = 0; i < 16 && off + i < len; i++) data[off + i] ^= sblk[i];
    }
}

static int zsec_seal(unsigned char *buf, int len, const unsigned char *aad, int aadlen,
                     unsigned int src, unsigned int ctr, unsigned char *tag)
{
    mbedtls_aes_context a;
    unsigned char nonce[13], s0[16], t[ZSEC_MIC];
    if (!zkey_ok) return -1;
    zsec_nonce(nonce, src, ctr);
    mbedtls_aes_init(&a);
    if (mbedtls_aes_setkey_enc(&a, zkey, 128) != 0) { mbedtls_aes_free(&a); return -1; }
    ccm_tag(&a, nonce, aad, aadlen, buf, len, t);
    ccm_ctr(&a, nonce, buf, len, s0);
    for (int i = 0; i < ZSEC_MIC; i++) tag[i] = t[i] ^ s0[i];
    mbedtls_aes_free(&a);
    return 0;
}

static int zsec_open(unsigned char *buf, int len, const unsigned char *aad, int aadlen,
                     unsigned int src, unsigned int ctr, const unsigned char *tag)
{
    mbedtls_aes_context a;
    unsigned char nonce[13], s0[16], t[ZSEC_MIC];
    if (!zkey_ok) return -1;
    zsec_nonce(nonce, src, ctr);
    mbedtls_aes_init(&a);
    if (mbedtls_aes_setkey_enc(&a, zkey, 128) != 0) { mbedtls_aes_free(&a); return -1; }
    ccm_ctr(&a, nonce, buf, len, s0);
    ccm_tag(&a, nonce, aad, aadlen, buf, len, t);
    mbedtls_aes_free(&a);
    for (int i = 0; i < ZSEC_MIC; i++)
        if ((unsigned char)(t[i] ^ s0[i]) != tag[i]) return -2;
    return 0;
}

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
#define T_OPER 0x10
#define T_RSRQ 0x11
#define T_SINR 0x12
#define T_BAND 0x13
#define T_CA   0x14
#define T_MODE 0x15
#define T_VNODE 0x16
#define T_NODE 0x17

static const struct { unsigned char id; const char *key; } TELE_STR[] = {
    { T_OPER, "oper" }, { T_BAND, "band" }, { T_CA, "ca" },
    { T_MODE, "mode" }, { T_VNODE, "vpn_node" },
};

static const struct { unsigned char id; const char *key; int width; } TELE[] = {
    { T_SIG, "sig", 1 }, { T_RSRP, "rsrp", 1 }, { T_BATT, "batt", 1 },
    { T_CHG, "chg", 1 }, { T_CPU, "cpu", 1 }, { T_MEM, "mem", 1 },
    { T_DISK, "disk", 1 }, { T_UP, "up", 2 }, { T_WIFI, "wifi", 1 },
    { T_PING, "ping", 2 }, { T_SMS, "sms", 1 }, { T_RX, "rx", 4 },
    { T_TX, "tx", 4 }, { T_TEMP, "temp", 1 }, { T_VPN, "vpn", 1 },
    { T_RSRQ, "rsrq", 1 }, { T_SINR, "sinr", 1 }, { T_NODE, "node", 1 },
};

static int my_node;

#define TELE_MODEM "/tmp/5gmodem_tele.json"
#define TELE_SELF  "/tmp/almond_tele.json"
#define TELE_STALE 90

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

static int jstr(const char *buf, const char *key, char *out, int max)
{
    char pat[48];
    snprintf(pat, sizeof pat, "\"%s\":", key);
    const char *p = strstr(buf, pat);
    if (!p) return 0;
    p += strlen(pat);
    while (*p == ' ') p++;
    if (*p != '"') return 0;
    p++;
    int n = 0;
    while (*p && *p != '"' && n < max - 1) {
        if (*p == '\\' && p[1]) p++;
        out[n++] = *p++;
    }
    out[n] = 0;
    return n;
}

static int tele_slurp(const char *path, char *buf, int max, int stale)
{
    struct stat sb;
    buf[0] = 0;
    if (stat(path, &sb) != 0) return 0;
    if (stale > 0 && (long)time(NULL) - (long)sb.st_mtime > stale) return -1;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t got = fread(buf, 1, (size_t)max - 1, f);
    buf[got] = 0;
    fclose(f);
    return got > 0 ? 1 : 0;
}

static int tele_pack_from(const char *buf, unsigned char *out, int n, int max)
{
    for (unsigned i = 0; i < sizeof TELE / sizeof TELE[0]; i++) {
        long v = jnum(buf, TELE[i].key, 0x7FFFFFFF);
        if (v == 0x7FFFFFFF) continue;
        if (n + 2 + TELE[i].width > max) break;
        out[n++] = TELE[i].id;
        out[n++] = (unsigned char)TELE[i].width;
        for (int b = 0; b < TELE[i].width; b++)
            out[n++] = (unsigned char)((v >> (8 * b)) & 0xFF);
    }
    for (unsigned i = 0; i < sizeof TELE_STR / sizeof TELE_STR[0]; i++) {
        char sv[32];
        if (jstr(buf, TELE_STR[i].key, sv, sizeof sv) <= 0) continue;
        int sl = (int)strlen(sv);
        if (sl > 16) sl = 16;
        if (sl <= 0 || n + 2 + sl > max) continue;
        out[n++] = TELE_STR[i].id;
        out[n++] = (unsigned char)sl;
        memcpy(out + n, sv, (size_t)sl);
        n += sl;
    }
    return n;
}

static int tele_pack(unsigned char *out, int max)
{
    char self[1024], modem[1024];
    int n = 0;
    const char *sp = getenv("ZIG_TELE_SELF") ? getenv("ZIG_TELE_SELF") : TELE_SELF;
    const char *mp = getenv("ZIG_TELE_MODEM") ? getenv("ZIG_TELE_MODEM") : TELE_MODEM;

    if (tele_slurp(sp, self, sizeof self, 0) > 0)
        n = tele_pack_from(self, out, n, max);
    if (tele_slurp(mp, modem, sizeof modem, TELE_STALE) > 0)
        n = tele_pack_from(modem, out, n, max);
    if (my_node > 0 && n + 3 <= max) {
        out[n++] = T_NODE;
        out[n++] = 1;
        out[n++] = (unsigned char)my_node;
    }
    return n;
}

static void tele_unpack(const unsigned char *in, int n, char *out, int max)
{
    int off = 0, first = 1;
    out[0] = 0;
    for (int i = 0; i + 2 <= n; ) {
        int id = in[i], w = in[i + 1];
        int is_str = 0;
        for (unsigned q = 0; q < sizeof TELE_STR / sizeof TELE_STR[0]; q++)
            if (TELE_STR[q].id == id) is_str = 1;
        if (is_str) {
            if (w < 0 || i + 2 + w > n) break;
            char ov[24]; int oi = 0;
            for (; oi < w && oi < 20; oi++) {
                unsigned char c = in[i + 2 + oi];
                ov[oi] = (c >= 32 && c < 127 && c != '"' && c != '\\') ? (char)c : '.';
            }
            ov[oi] = 0;
            const char *skey = "oper";
            for (unsigned q = 0; q < sizeof TELE_STR / sizeof TELE_STR[0]; q++)
                if (TELE_STR[q].id == id) skey = TELE_STR[q].key;
            off += snprintf(out + off, max - off, "%s\"%s\":\"%s\"",
                            first ? "" : ",", skey, ov);
            first = 0;
            i += 2 + w;
            if (off > max - 24) break;
            continue;
        }
        if (w < 1 || w > 4 || i + 2 + w > n) break;
        long v = 0;
        for (int b = 0; b < w; b++) v |= (long)in[i + 2 + b] << (8 * b);
        if (w == 1 && (id == T_RSRP || id == T_TEMP || id == T_RSRQ || id == T_SINR))
            v = (signed char)v;
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

static void port_baud(int speed)
{
    struct termios t;
    speed_t s = speed == 115200 ? B115200 : speed == 57600 ? B57600 :
                speed == 38400 ? B38400 : speed == 19200 ? B19200 : B9600;
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    cfsetispeed(&t, s);
    cfsetospeed(&t, s);
    t.c_cflag |= CLOCAL | CREAD;
    t.c_cflag &= ~CRTSCTS;
    t.c_iflag &= ~(IXON | IXOFF | IXANY);
    tcsetattr(fd, TCSADRAIN, &t);
    tcflush(fd, TCIFLUSH);
}

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
    if (ezsp_v8 && pn >= 5) {
        pl[2] = pl[3];
        memmove(pl + 3, pl + 5, (size_t)(pn - 5));
        pn -= 2;
    }
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
    ezsp_v8 = 0;
    ezsp_cmd(0x00, par, 1);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 800);
        if (pn >= 7 && pl[2] == 0x00) {
            *proto = pl[3];
            *stack_type = pl[4];
            *stack_ver = (pl[6] << 8) | pl[5];
            if (*proto >= 8) {
                ezsp_v8 = 1;
                par[0] = (unsigned char)*proto;
                ezsp_cmd(0x00, par, 1);
                for (int k = 0; k < 6; k++) {
                    int qn = ezsp_read(pl, sizeof pl, 800);
                    if (qn >= 7 && pl[2] == 0x00) {
                        *stack_type = pl[4];
                        *stack_ver = (pl[6] << 8) | pl[5];
                        break;
                    }
                }
            }
            return 1;
        }
    }
    return 0;
}

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
    remove("/tmp/.zig_flashing");
    printf("{\"ok\":0,\"error\":\"%s\"}\n", msg);
    exit(1);
}

static char scan_json[4096];
static int scan_errs;

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

    int first = 1, done = 0, items = 0, errs = 0, last_err = 0;
    char badch[96] = "";
    int jn = snprintf(scan_json, sizeof scan_json, "{\"ok\":1,\"%s\":[", active ? "networks" : "channels");
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
            jn += snprintf(scan_json + jn, sizeof scan_json - jn, "%s{\"ch\":%d,\"rssi\":%d}", first ? "" : ",", pl[3], (signed char)pl[4]);
            first = 0;
            items++;
        } else if (active && pn >= 17 && pl[2] == 0x1B) {
            jn += snprintf(scan_json + jn, sizeof scan_json - jn, "%s{\"ch\":%d,\"pan\":%d,\"join\":%d,\"lqi\":%d,\"rssi\":%d,"
                   "\"epan\":\"%02X%02X%02X%02X%02X%02X%02X%02X\"}",
                   first ? "" : ",", pl[3], pl[4] | (pl[5] << 8), pl[14],
                   pl[pn - 2], (signed char)pl[pn - 1],
                   pl[13], pl[12], pl[11], pl[10], pl[9], pl[8], pl[7], pl[6]);
            first = 0;
            items++;
        } else if (pn >= 5 && pl[2] == 0x1C) {
            if (pl[4] != 0) {
                errs++; last_err = pl[4];
                snprintf(badch + strlen(badch), sizeof badch - strlen(badch),
                         "%s%d", errs > 1 ? "," : "", pl[3]);
            }
            else done = 1;
        }
    }
    snprintf(scan_json + jn, sizeof scan_json - jn,
             "],\"count\":%d,\"done\":%d,\"errors\":%d,\"last_error\":%d,\"failed\":[%s]}\n",
             items, done, errs, last_err, badch);
    scan_errs = errs;
    return items;
}

static int mfg_power(int mode, int pw)
{
    unsigned char d[3] = { (unsigned char)(mode & 0xFF),
                           (unsigned char)((mode >> 8) & 0xFF),
                           (unsigned char)(signed char)pw }, pl[64];
    ezsp_cmd(0x8C, d, 3);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 600);
        if (pn >= 4 && pl[2] == 0x8C) return pl[3];
    }
    return -1;
}

static int join_net(int pan, int channel, int power, const unsigned char *key)
{
    unsigned char par[64], pl[64];
    int n = 0;

    int secmask = getenv("ZIG_SECMASK") ? (int)strtol(getenv("ZIG_SECMASK"), NULL, 0) : 0x0300;
    par[n++] = (unsigned char)(secmask & 0xFF); par[n++] = (unsigned char)((secmask >> 8) & 0xFF);
    par[n++] = 0x00; par[n++] = 0x00;
    memcpy(par + n, key, 16); n += 16;
    memcpy(par + n, key, 16); n += 16;
    par[n++] = 0x00;
    memset(par + n, 0, 8); n += 8;
    ezsp_cmd(0x68, par, n);
    int st = -1;
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 800);
        if (pn >= 4 && pl[2] == 0x68) { st = pl[3]; break; }
    }

    n = 0;
    par[n++] = 0x02;
    for (int i = 0; i < 8; i++) par[n++] = (unsigned char)(0xA5 - i);
    par[n++] = (unsigned char)(pan & 0xFF);
    par[n++] = (unsigned char)((pan >> 8) & 0xFF);
    par[n++] = (unsigned char)power;
    par[n++] = (unsigned char)channel;
    par[n++] = 0x00;
    par[n++] = 0x00; par[n++] = 0x00;
    par[n++] = 0x00;
    unsigned int chmask = 1u << channel;
    par[n++] = (unsigned char)(chmask & 0xFF);
    par[n++] = (unsigned char)((chmask >> 8) & 0xFF);
    par[n++] = (unsigned char)((chmask >> 16) & 0xFF);
    par[n++] = (unsigned char)((chmask >> 24) & 0xFF);
    ezsp_cmd(0x1F, par, n);

    int jst = -1, up = -1;
    for (int i = 0; i < 60; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x1F) jst = pl[3];
        if (pn >= 4 && pl[2] == 0x19) { up = pl[3]; if (pl[3] == 0x90) break; }
    }
    printf("{\"ok\":%d,\"security\":%d,\"join\":%d,\"stack\":%d,\"pan\":%d,\"ch\":%d}\n",
           up == 0x90 ? 1 : 0, st, jst, up, pan, channel);
    return up == 0x90 ? 0 : -1;
}

static int form(int pan, int channel, int power, const unsigned char *key)
{
    unsigned char par[64], pl[64];
    int n = 0;

    int secmask = getenv("ZIG_SECMASK") ? (int)strtol(getenv("ZIG_SECMASK"), NULL, 0) : 0x0200;
    par[n++] = (unsigned char)(secmask & 0xFF); par[n++] = (unsigned char)((secmask >> 8) & 0xFF);
    par[n++] = 0x00; par[n++] = 0x00;
    memcpy(par + n, key, 16); n += 16;
    memcpy(par + n, key, 16); n += 16;
    par[n++] = 0x00;
    memset(par + n, 0, 8); n += 8;
    ezsp_cmd(0x68, par, n);
    int st = -1;
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 800);
        if (pn >= 4 && pl[2] == 0x68) { st = pl[3]; break; }
    }

    n = 0;
    for (int i = 0; i < 8; i++) par[n++] = (unsigned char)(0xA5 - i);
    par[n++] = (unsigned char)(pan & 0xFF);
    par[n++] = (unsigned char)((pan >> 8) & 0xFF);
    par[n++] = (unsigned char)power;
    par[n++] = (unsigned char)channel;
    par[n++] = 0x00;
    par[n++] = 0x00; par[n++] = 0x00;
    par[n++] = 0x00;
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
        if (pn >= 4 && pl[2] == 0x19) { fst = 0; break; }
    }
    int pj = -1, pol = -1;
    if (fst == 0) {
        int dec = getenv("ZIG_TCPOLICY") ? (int)strtol(getenv("ZIG_TCPOLICY"), NULL, 0) : 0x07;
        unsigned char dp[2] = { 0x00, (unsigned char)dec };
        ezsp_cmd(0x55, dp, 2);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 700);
            if (pn >= 4 && pl[2] == 0x55) { pol = pl[3]; break; }
        }
        unsigned char d1[1] = { 0xFF };
        ezsp_cmd(0x22, d1, 1);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 700);
            if (pn >= 4 && pl[2] == 0x22) { pj = pl[3]; break; }
        }
    }
    printf("{\"ok\":%d,\"security\":%d,\"form\":%d,\"policy\":%d,\"permit\":%d,\"pan\":%d,\"ch\":%d}\n",
           fst == 0 ? 1 : 0, st, fst, pol, pj, pan, channel);
    return fst == 0;
}

static int node_type(void)
{
    unsigned char pl[64];
    ezsp_cmd(0x28, NULL, 0);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 25 && pl[2] == 0x28) return pl[4];
    }
    return -1;
}

static int tc_policy(void)
{
    unsigned char pl[64];
    int dec = getenv("ZIG_TCPOLICY") ? (int)strtol(getenv("ZIG_TCPOLICY"), NULL, 0) : 0x07;
    unsigned char dp[2] = { 0x00, (unsigned char)dec };
    ezsp_cmd(0x55, dp, 2);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x55) return pl[3];
    }
    return -1;
}

static int permit_join(int secs)
{
    unsigned char pl[64], d[1] = { (unsigned char)secs };
    ezsp_cmd(0x22, d, 1);
    for (int i = 0; i < 8; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x22) return pl[3];
    }
    return -1;
}

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

#define ZCMD_MARK 0xC1

static int frame_build(unsigned char *body, int seq, unsigned int myid, unsigned int ctr,
                       const unsigned char *payload, int plen)
{
    int n = 0;
    body[n++] = 0x41; body[n++] = 0x88;
    body[n++] = (unsigned char)seq;
    body[n++] = 0xFF; body[n++] = 0xFF; body[n++] = 0xFF; body[n++] = 0xFF;
    body[n++] = (unsigned char)(myid & 0xFF);
    body[n++] = (unsigned char)((myid >> 8) & 0xFF);
    body[n++] = 0x41;
    int secpos = n;
    body[n++] = zkey_ok ? ZSEC_CCM : ZSEC_PLAIN;
    body[n++] = (unsigned char)(ctr & 0xFF);
    body[n++] = (unsigned char)((ctr >> 8) & 0xFF);
    body[n++] = (unsigned char)((ctr >> 16) & 0xFF);
    body[n++] = (unsigned char)((ctr >> 24) & 0xFF);
    int aadlen = n, pstart = n;
    memcpy(body + n, payload, plen); n += plen;
    if (zkey_ok) {
        unsigned char tag[ZSEC_MIC];
        if (zsec_seal(body + pstart, plen, body, aadlen, myid, ctr, tag) == 0) {
            memcpy(body + n, tag, ZSEC_MIC); n += ZSEC_MIC;
        } else {
            body[secpos] = ZSEC_PLAIN;
        }
    }
    body[n++] = 0; body[n++] = 0;
    return n;
}

static void mfg_send(const unsigned char *body, int n, int ch)
{
    unsigned char pl[128], d[176];
    if (n < 1 || n > 174) return;
    d[0] = (unsigned char)n;
    memcpy(d + 1, body, n);
    ezsp_cmd(0x89, d, n + 1);
    for (int i = 0; i < 3; i++) { int pn = ezsp_read(pl, sizeof pl, 200); if (pn >= 4 && pl[2] == 0x89) break; }
    ezsp_cmd(0x84, NULL, 0);
    for (int i = 0; i < 3; i++) { int pn = ezsp_read(pl, sizeof pl, 300); if (pn >= 4 && pl[2] == 0x84) break; }
    d[0] = 1; ezsp_cmd(0x83, d, 1);
    for (int i = 0; i < 3; i++) { int pn = ezsp_read(pl, sizeof pl, 300); if (pn >= 4 && pl[2] == 0x83) break; }
    d[0] = (unsigned char)ch; ezsp_cmd(0x8A, d, 1);
    for (int i = 0; i < 3; i++) { int pn = ezsp_read(pl, sizeof pl, 300); if (pn >= 4 && pl[2] == 0x8A) break; }
}

static int cmd_exec(const char *action)
{
    static const struct { const char *name, *run; } WL[] = {
        { "vpn_off", "/etc/almond3s/scripts/vpn_clash.sh stop" },
        { "vpn_on",  "/etc/almond3s/scripts/vpn_clash.sh start" },
        { "reboot",  "/etc/almond3s/scripts/reboot.sh" },
        { "modem",   "/etc/almond3s/scripts/lte_reset.sh" },
    };
    for (unsigned i = 0; i < sizeof WL / sizeof WL[0]; i++)
        if (!strcmp(action, WL[i].name)) {
            char buf[128];
            snprintf(buf, sizeof buf, "(%s) >/dev/null 2>&1 &", WL[i].run);
            system(buf);
            return 0;
        }
    return -1;
}

struct peer_ent { char name[24]; int rssi, lqi; unsigned int src; long seen;
                  char part[4][160]; unsigned char raw[4][72]; int rawlen[4]; };
#define PEER_MAX 16
static struct peer_ent pr[PEER_MAX];
static int npr;

static int peer_slot(const char *nm)
{
    for (int j = 0; j < npr; j++) if (!strcmp(pr[j].name, nm)) return j;
    int idx;
    if (npr < PEER_MAX) idx = npr++;
    else {
        idx = 0;
        for (int j = 1; j < npr; j++) if (pr[j].seen < pr[idx].seen) idx = j;
    }
    memset(&pr[idx], 0, sizeof pr[idx]);
    snprintf(pr[idx].name, sizeof pr[idx].name, "%s", nm);
    return idx;
}

#define ZCL_EP        1
#define ZCL_PROFILE   0x0104
#define CL_BASIC      0x0000
#define CL_POWER      0x0001
#define CL_TEMP       0x0402
#define CL_ALMOND      0xFC00

static int aps_build(unsigned char *o, int cluster, int seq)
{
    int n = 0;
    o[n++] = (unsigned char)(ZCL_PROFILE & 0xFF);
    o[n++] = (unsigned char)(ZCL_PROFILE >> 8);
    o[n++] = (unsigned char)(cluster & 0xFF);
    o[n++] = (unsigned char)(cluster >> 8);
    o[n++] = ZCL_EP;
    o[n++] = ZCL_EP;
    o[n++] = 0x40; o[n++] = 0x01;
    o[n++] = 0x00; o[n++] = 0x00;
    o[n++] = (unsigned char)seq;
    return n;
}

static int zcl_report(unsigned char *o, int seq)
{
    int n = 0;
    o[n++] = 0x18;
    o[n++] = (unsigned char)seq;
    o[n++] = 0x0A;
    return n;
}

static void zcl_attr_u8(unsigned char *o, int *n, int attr, int v)
{
    o[(*n)++] = (unsigned char)(attr & 0xFF);
    o[(*n)++] = (unsigned char)(attr >> 8);
    o[(*n)++] = 0x20;
    o[(*n)++] = (unsigned char)v;
}

static void zcl_attr_s16(unsigned char *o, int *n, int attr, int v)
{
    o[(*n)++] = (unsigned char)(attr & 0xFF);
    o[(*n)++] = (unsigned char)(attr >> 8);
    o[(*n)++] = 0x29;
    o[(*n)++] = (unsigned char)(v & 0xFF);
    o[(*n)++] = (unsigned char)((v >> 8) & 0xFF);
}

static void zcl_attr_bytes(unsigned char *o, int *n, int attr,
                           const unsigned char *b, int bl)
{
    o[(*n)++] = (unsigned char)(attr & 0xFF);
    o[(*n)++] = (unsigned char)(attr >> 8);
    o[(*n)++] = 0x41;
    o[(*n)++] = (unsigned char)bl;
    memcpy(o + *n, b, (size_t)bl);
    *n += bl;
}

static int mesh_send(int cluster, const unsigned char *zcl, int zn, int seq)
{
    unsigned char par[200], pl[128];
    int n = 0;
    par[n++] = 0xFF; par[n++] = 0xFF;
    n += aps_build(par + n, cluster, seq);
    par[n++] = 30;
    par[n++] = (unsigned char)seq;
    par[n++] = (unsigned char)zn;
    memcpy(par + n, zcl, (size_t)zn);
    n += zn;
    ezsp_cmd(0x36, par, n);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x36) return pl[3];
    }
    return -1;
}

static int mesh_unicast(unsigned int dest, int cluster, const unsigned char *zcl,
                        int zn, int seq)
{
    unsigned char par[200], pl[128];
    int n = 0;
    par[n++] = 0x00;
    par[n++] = (unsigned char)(dest & 0xFF);
    par[n++] = (unsigned char)((dest >> 8) & 0xFF);
    n += aps_build(par + n, cluster, seq);
    par[n++] = (unsigned char)seq;
    par[n++] = (unsigned char)zn;
    memcpy(par + n, zcl, (size_t)zn);
    n += zn;
    ezsp_cmd(0x34, par, n);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x34) return pl[3];
    }
    return -1;
}

static int mesh_endpoint(void)
{
    unsigned char par[32], pl[64];
    int n = 0;
    par[n++] = ZCL_EP;
    par[n++] = (unsigned char)(ZCL_PROFILE & 0xFF);
    par[n++] = (unsigned char)(ZCL_PROFILE >> 8);
    par[n++] = 0x07; par[n++] = 0x00;
    par[n++] = 1;
    par[n++] = 4;
    par[n++] = 0;
    static const int IN[] = { CL_BASIC, CL_POWER, CL_TEMP, CL_ALMOND };
    for (unsigned i = 0; i < sizeof IN / sizeof IN[0]; i++) {
        par[n++] = (unsigned char)(IN[i] & 0xFF);
        par[n++] = (unsigned char)(IN[i] >> 8);
    }
    ezsp_cmd(0x02, par, n);
    for (int i = 0; i < 6; i++) {
        int pn = ezsp_read(pl, sizeof pl, 700);
        if (pn >= 4 && pl[2] == 0x02) return pl[3];
    }
    return -1;
}

static void mesh_rx(const unsigned char *pl, int pn, const char *me)
{
    if (pn >= 20 && pl[2] == 0x45) {
        int cl = pl[6] | (pl[7] << 8);
        int lqi = pl[15], rssi = (signed char)pl[16];
        unsigned int src = (unsigned int)pl[17] | ((unsigned int)pl[18] << 8);
        int ln = pl[21];
        const unsigned char *b = pl + 22;
        if (getenv("ZIG_DEBUG"))
    fprintf(stderr, "принято: кластер %04X от %04X, длина %d\n", cl, src, ln);
        if (cl == CL_ALMOND && ln >= 8 && 22 + ln <= pn && b[2] == 0x0A) {
    const unsigned char *a = b + 3;
    int alen = ln - 3;
    int part = a[0] | (a[1] << 8);
    if (part > 3) part = 3;
    if (alen >= 4 && a[2] == 0x41) {
        int blen = a[3];
        const unsigned char *v = a + 4;
        if (blen >= 1 && blen <= alen - 4) {
            int tl = v[0];
            if (tl > 0 && tl <= 20 && tl + 1 <= blen) {
                char nm[24];
                int k = 0;
                for (; k < tl; k++) {
                    unsigned char c = v[1 + k];
                    nm[k] = (c >= 32 && c < 127) ? (char)c : '.';
                }
                nm[k] = 0;
                if (!strcmp(nm, me)) return;
                char mj[320];
                tele_unpack(v + 1 + tl, blen - 1 - tl, mj, sizeof mj);
                int idx = peer_slot(nm);
                if (idx >= 0) {
                    pr[idx].rssi = rssi;
                    pr[idx].lqi = lqi;
                    pr[idx].src = src;
                    pr[idx].seen = (long)time(NULL);
                    snprintf(pr[idx].part[part], sizeof pr[idx].part[part],
                             "%s", mj);
                    if (ln > 0 && ln <= (int)sizeof pr[idx].raw[part]) {
                        memcpy(pr[idx].raw[part], b, (size_t)ln);
                        pr[idx].rawlen[part] = ln;
                    }
                }
            }
        }
    }
        }
    }
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *cmd = argc > 1 ? argv[1] : "info";
    const char *dev = getenv("ZIG_TTY") ? getenv("ZIG_TTY") : "/dev/ttyS2";

    int lk = open("/var/lock/almond3s-zig.lock", O_CREAT | O_RDWR, 0600);
    if (lk >= 0) {
        int got = 0;
        for (int i = 0; i < 60; i++) {
            if (flock(lk, LOCK_EX | LOCK_NB) == 0) { got = 1; break; }
            usleep(100000);
        }
        if (!got) die("занято");
    }

    if (port_open(dev) < 0) die("нет порта");

    int ver = 0, reason = 0;
    int flashing = !strcmp(cmd, "flash") || !strcmp(cmd, "btlscan");
    if (!strcmp(cmd, "flash")) {
        FILE *mk0 = fopen("/tmp/.zig_flashing", "w");
        if (mk0) fclose(mk0);
    }
    int ash_ok = ash_reset(&ver, &reason);
    if (!ash_ok && !flashing) die("чип молчит");

    int proto = 0, stype = 0, sver = 0;
    if (ash_ok && !ezsp_version(&proto, &stype, &sver) && !flashing) die("нет ответа EZSP");

    int prof = set_cfg(0x0C, 2);
    set_cfg(0x0D, 5);
    const char *txm = getenv("ZIG_TXMODE");
    int txmode = txm ? atoi(txm) : 1;
    int txst = set_cfg(0x17, txmode);

    int cca = getenv("ZIG_CCA") ? atoi(getenv("ZIG_CCA")) : -20;
    int cca_st = -1;
    if (ezsp_v8 && cca < 20) {
        unsigned char cd[3] = { 0x15, 1, (unsigned char)(signed char)cca }, cpl[64];
        ezsp_cmd(0xAB, cd, 3);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(cpl, sizeof cpl, 600);
            if (pn >= 4 && cpl[2] == 0xAB) { cca_st = cpl[3]; break; }
        }
    }

    const char *gp = getenv("ZIG_GPIO");
    if (gp) {
        char buf[128];
        snprintf(buf, sizeof buf, "%s", gp);
        for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
            int pin = -1, cfg = -1, out = 0;
            if (sscanf(tok, "%d:%x:%d", &pin, &cfg, &out) < 2) continue;
            unsigned char d[3] = { (unsigned char)pin, (unsigned char)cfg, (unsigned char)out }, pl[64];
            ezsp_cmd(0xAC, d, 3);
            for (int i = 0; i < 6; i++) {
                int pn = ezsp_read(pl, sizeof pl, 600);
                if (pn >= 4 && pl[2] == 0xAC) {
                    fprintf(stderr, "нога %d режим 0x%X -> статус %d\n", pin, cfg, pl[3]);
                    break;
                }
            }
        }
    }

    if (getenv("ZIG_RHO")) {
        int vid = getenv("ZIG_VID") ? (int)strtol(getenv("ZIG_VID"), NULL, 0) : 0x0E;
        unsigned char d[3] = { (unsigned char)vid, 1, (unsigned char)atoi(getenv("ZIG_RHO")) }, pl[64];
        ezsp_cmd(0xAB, d, 3);
        for (int i = 0; i < 6; i++) {
            int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0xAB) { fprintf(stderr, "значение 0x%02X=%d -> статус %d\n", d[0], d[2], pl[3]); break; }
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
    int scanning = !strcmp(cmd, "escan") || !strcmp(cmd, "ascan")
                || !strcmp(cmd, "tone") || !strcmp(cmd, "listen")
                || !strcmp(cmd, "send") || !strcmp(cmd, "beacon")
                || !strcmp(cmd, "mesh");
    if (!scanning) {
        init = network_init();
        if (init == 0) {
            unsigned char pl[64];
            for (int i = 0; i < 4; i++) ezsp_read(pl, sizeof pl, 400);
        }
    }

    if (!strcmp(cmd, "info")) {
        printf("{\"ok\":1,\"ash\":%d,\"reset\":%d,\"ezsp\":%d,\"stack_type\":%d,"
               "\"netinit\":%d,\"profile\":%d,\"txmode\":%d,\"txstatus\":%d,"
               "\"cca\":%d,\"cca_status\":%d,"
               "\"stack\":\"%d.%d.%d.%d\"}\n",
               ver, reason, proto, stype, init, prof, txmode, txst, cca, cca_st,
               (sver >> 12) & 15, (sver >> 8) & 15, (sver >> 4) & 15, sver & 15);
    } else if (!strcmp(cmd, "escan")) {
        unsigned int mk = argc > 3 ? (1u << atoi(argv[3])) : 0x07FFF800u;
        scan(0, argc > 2 ? atoi(argv[2]) : 3, mk);
        fputs(scan_json, stdout);
    } else if (!strcmp(cmd, "ascan")) {
        unsigned int mk = argc > 3 ? (1u << atoi(argv[3])) : 0x07FFF800u;
        int tries = getenv("ZIG_TRIES") ? atoi(getenv("ZIG_TRIES")) : 6;
        int best = -1;
        char keep[4096] = "";
        for (int t = 0; t < (tries < 1 ? 1 : tries); t++) {
            int got = scan(1, argc > 2 ? atoi(argv[2]) : 5, mk);
            if (best < 0 || got > best || (got == best && scan_errs == 0)) {
                best = got;
                snprintf(keep, sizeof keep, "%s", scan_json);
            }
            if (got > 0 && scan_errs == 0) break;
        }
        fputs(keep, stdout);
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
    } else if (!strcmp(cmd, "join")) {
        int pan = argc > 2 ? (int)strtol(argv[2], NULL, 0) : 0x1A2B;
        int ch  = argc > 3 ? atoi(argv[3]) : 15;
        unsigned char key[16];
        for (int i = 0; i < 16; i++) key[i] = (unsigned char)(0x30 + i);
        if (argc > 4 && strlen(argv[4]) >= 32)
            for (int i = 0; i < 16; i++) {
                char b[3] = { argv[4][i * 2], argv[4][i * 2 + 1], 0 };
                key[i] = (unsigned char)strtol(b, NULL, 16);
            }
        join_net(pan, ch, 8, key);
    } else if (!strcmp(cmd, "cca")) {
        int th = argc > 2 ? atoi(argv[2]) : -20;
        int st = -1;
        if (ezsp_v8) {
            unsigned char d[3] = { 0x15, 1, (unsigned char)(signed char)th }, pl[64];
            ezsp_cmd(0xAB, d, 3);
            for (int i = 0; i < 6; i++) {
                int pn = ezsp_read(pl, sizeof pl, 700);
                if (pn >= 4 && pl[2] == 0xAB) { st = pl[3]; break; }
            }
        }
        printf("{\"ok\":%d,\"cca\":%d,\"status\":%d,\"ezsp\":%d}\n",
               st == 0 ? 1 : 0, th, st, proto);
    } else if (!strcmp(cmd, "permit")) {
        int secs = argc > 2 ? atoi(argv[2]) : 254;
        int pol = tc_policy();
        int st = permit_join(secs);
        printf("{\"ok\":%d,\"policy\":%d,\"permit\":%d,\"seconds\":%d}\n",
               st == 0 ? 1 : 0, pol, st, secs);
    } else if (!strcmp(cmd, "children")) {
        unsigned char pl[64], d[1];
        printf("{\"ok\":1,\"children\":[");
        int first = 1;
        for (int idx = 0; idx < 8; idx++) {
            d[0] = (unsigned char)idx;
            ezsp_cmd(0x4A, d, 1);
            for (int i = 0; i < 6; i++) {
                int pn = ezsp_read(pl, sizeof pl, 500);
                if (pn >= 4 && pl[2] == 0x4A) {
                    if (pl[3] == 0 && pn >= 14) {
                        printf("%s{\"idx\":%d,\"id\":%d,\"eui\":\"%02X%02X%02X%02X%02X%02X%02X%02X\"}",
                               first ? "" : ",", idx, pl[4] | (pl[5] << 8),
                               pl[13], pl[12], pl[11], pl[10], pl[9], pl[8], pl[7], pl[6]);
                        first = 0;
                    }
                    break;
                }
            }
        }
        printf("]}\n");
    } else if (!strcmp(cmd, "mesh")) {
        int period = argc > 2 ? atoi(argv[2]) : 30;
        const char *me = argc > 3 ? argv[3] : "almond";
        const char *out = getenv("ZIG_PEERS") ? getenv("ZIG_PEERS") : "/tmp/lcd_zig_peers.json";
        unsigned char pl[192];

        signal(SIGTERM, on_term);
        signal(SIGINT, on_term);

        int ep = mesh_endpoint();
        init = network_init();
        if (init == 0) {
            for (int i = 0; i < 6; i++) ezsp_read(pl, sizeof pl, 500);
            if (node_type() == 1) {
                tc_policy();
                permit_join(0xFF);
            }
        }
        printf("{\"ok\":%d,\"endpoint\":%d,\"netinit\":%d,\"mode\":\"mesh\"}\n",
               (ep == 0 && init == 0) ? 1 : 0, ep, init);
        fflush(stdout);
        if (ep != 0) return 1;

        memset(pr, 0, sizeof pr);
        npr = 0;
        long last_save = 0, last_relay = 0;
        int seq = 0;
        int coord = node_type() == 1;
        my_node = coord ? 1 : 2;
        long last_tx = (long)time(NULL) - period;

        while (!stop_flag) {
            long now = (long)time(NULL);
            if (now - last_tx >= period) {
                last_tx = now;
                unsigned char tele[96];
                int tn = tele_pack(tele, sizeof tele);
                char buf[1024] = "";
                const char *tp = getenv("ZIG_TELE") ? getenv("ZIG_TELE") : "/tmp/lcd_zig_tele.json";
                FILE *tf = fopen(tp, "r");
                if (tf) { size_t got = fread(buf, 1, sizeof buf - 1, tf); buf[got] = 0; fclose(tf); }

                long batt = jnum(buf, "batt", -1);
                if (batt >= 0) {
                    unsigned char z[32];
                    int zn = zcl_report(z, seq);
                    zcl_attr_u8(z, &zn, 0x0021, (int)(batt * 2 > 200 ? 200 : batt * 2));
                    mesh_send(CL_POWER, z, zn, seq++);
                }
                long temp = jnum(buf, "temp", -999);
                if (temp > -999 && temp != 0) {
                    unsigned char z[32];
                    int zn = zcl_report(z, seq);
                    zcl_attr_s16(z, &zn, 0x0000, (int)(temp * 100));
                    mesh_send(CL_TEMP, z, zn, seq++);
                }
                {
                    int ml = (int)strlen(me); if (ml > 20) ml = 20;
                    int off = 0, part = 0;
                    while (off < tn && part < 4) {
                        int room = 44 - ml;
                        int take = 0;
                        while (off + take < tn) {
                            int w = tele[off + take + 1];
                            if (take + 2 + w > room) break;
                            take += 2 + w;
                        }
                        if (take == 0) break;
                        unsigned char blob[96];
                        int bn = 0;
                        blob[bn++] = (unsigned char)ml;
                        memcpy(blob + bn, me, (size_t)ml); bn += ml;
                        memcpy(blob + bn, tele + off, (size_t)take); bn += take;
                        unsigned char z[128];
                        int zn = zcl_report(z, seq);
                        zcl_attr_bytes(z, &zn, part, blob, bn);
                        int st2;
                        if (coord) {
                            st2 = -1;
                            for (int j = 0; j < npr; j++)
                                st2 = mesh_unicast(pr[j].src, CL_ALMOND, z, zn, seq);
                        } else {
                            st2 = mesh_unicast(0x0000, CL_ALMOND, z, zn, seq);
                        }
                        seq++;
                        if (getenv("ZIG_DEBUG"))
                            fprintf(stderr, "часть %d: длина %d -> статус %d\n", part, zn, st2);
                        off += take;
                        part++;
                        for (int w = 0; w < 2; w++) {
                            int rn = ezsp_read(pl, sizeof pl, 60);
                            if (rn > 0) mesh_rx(pl, rn, me);
                        }
                    }
                }
            }

            int pn = ezsp_read(pl, sizeof pl, 700);
            mesh_rx(pl, pn, me);

            if (coord && now - last_relay >= period) {
                last_relay = now;
                for (int i = 0; i < npr; i++) {
                    for (int q = 0; q < 4; q++) {
                        if (pr[i].rawlen[q] <= 0) continue;
                        for (int j = 0; j < npr; j++) {
                            if (j == i) continue;
                            mesh_unicast(pr[j].src, CL_ALMOND, pr[i].raw[q],
                                         pr[i].rawlen[q], seq++);
                        }
                    }
                    int rn = ezsp_read(pl, sizeof pl, 60);
                    if (rn > 0) mesh_rx(pl, rn, me);
                }
            }

            now = (long)time(NULL);
            if (now - last_save >= 2) {
                last_save = now;
                char tmp[128];
                snprintf(tmp, sizeof tmp, "%s.tmp", out);
                FILE *f = fopen(tmp, "w");
                if (f) {
                    fprintf(f, "{\"ok\":1,\"me\":\"%s\",\"mode\":\"mesh\",\"enc\":1,"
                               "\"node\":%d,"
                               "\"chip\":\"EM357 EZSP v%d %d.%d.%d.%d\",\"ts\":%ld,\"peers\":[",
                            me, my_node, proto, (sver >> 12) & 15, (sver >> 8) & 15,
                            (sver >> 4) & 15, sver & 15, now);
                    for (int j = 0; j < npr; j++) {
                        char all[560] = "";
                        for (int q = 0; q < 4; q++) {
                            if (!pr[j].part[q][0]) continue;
                            if (all[0]) strncat(all, ",", sizeof all - strlen(all) - 1);
                            strncat(all, pr[j].part[q], sizeof all - strlen(all) - 1);
                        }
                        fprintf(f, "%s{\"name\":\"%s\",\"rssi\":%d,\"lqi\":%d,\"id\":%u,"
                                   "\"age\":%ld,\"m\":{%s}}",
                                j ? "," : "", pr[j].name, pr[j].rssi, pr[j].lqi, pr[j].src,
                                now - pr[j].seen, all);
                    }
                    fprintf(f, "]}\n");
                    fclose(f);
                    rename(tmp, out);
                }
            }
        }
    } else if (!strcmp(cmd, "flash")) {
        const char *img = argc > 2 ? argv[2] : "/tmp/ncp.ebl";
        int mode = argc > 3 ? atoi(argv[3]) : 1;
        FILE *ff = fopen(img, "rb");
        if (!ff) die("нет образа");
        fseek(ff, 0, SEEK_END);
        long sz = ftell(ff);
        fseek(ff, 0, SEEK_SET);
        unsigned char *img_buf = malloc((size_t)sz);
        if (!img_buf || fread(img_buf, 1, (size_t)sz, ff) != (size_t)sz) die("образ не прочитан");
        fclose(ff);

        unsigned char d[1] = { (unsigned char)mode };
        int lst = -1;
        int settle = getenv("ZIG_SETTLE") ? atoi(getenv("ZIG_SETTLE")) : 4200;

        if (ash_ok) {
            ezsp_cmd(0x8F, d, 1);
            tcdrain(fd);
            fprintf(stderr, "прыжок в загрузчик, жду %d мс\n", settle);
            usleep((useconds_t)settle * 1000);
        } else {
            fprintf(stderr, "чип уже вне приложения, стучу в загрузчик\n");
        }
        port_baud(115200);

        char acc[600] = "";
        int menu = 0;
        struct timespec w0, w1;
        clock_gettime(CLOCK_MONOTONIC, &w0);
        for (;;) {
            char c = '\r';
            if (write(fd, &c, 1) < 0) {}
            unsigned char b[128];
            fd_set r;
            FD_ZERO(&r);
            FD_SET(fd, &r);
            struct timeval tv = { 0, 400000 };
            if (select(fd + 1, &r, NULL, NULL, &tv) > 0) {
                int n = (int)read(fd, b, sizeof b);
                int al = (int)strlen(acc);
                for (int k = 0; k < n; k++) {
                    if (al >= (int)sizeof acc - 2) { memmove(acc, acc + 200, (size_t)(al - 200 + 1)); al -= 200; }
                    acc[al++] = (b[k] >= 32 && b[k] < 127) ? (char)b[k] : '.';
                    acc[al] = 0;
                }
            }
            if (strstr(acc, "BL >")) { menu = 1; break; }
            clock_gettime(CLOCK_MONOTONIC, &w1);
            if (w1.tv_sec - w0.tv_sec > 9) break;
        }
        if (!menu) {
            remove("/tmp/.zig_flashing");
            printf("{\"ok\":0,\"launch\":%d,\"error\":\"меню не отвечает\",\"seen\":\"%s\"}\n", lst, acc);
            return 1;
        }
        fprintf(stderr, "загрузчик на связи\n");

        usleep(800000);
        tcflush(fd, TCIFLUSH);
        acc[0] = 0;
        { char c = '1'; if (write(fd, &c, 1) < 0) {} }
        tcdrain(fd);
        int ready = 0, crc_mode = 1;
        for (int i = 0; i < 120 && !ready; i++) {
            unsigned char b[128];
            fd_set r;
            FD_ZERO(&r);
            FD_SET(fd, &r);
            struct timeval tv = { 0, 50000 };
            if (select(fd + 1, &r, NULL, NULL, &tv) > 0) {
                int n = (int)read(fd, b, sizeof b);
                for (int k = 0; k < n; k++) {
                    if (b[k] == 'C') { ready = 1; crc_mode = 1; }
                    else if (b[k] == 0x15) { ready = 1; crc_mode = 0; }
                }
                int al = (int)strlen(acc);
                for (int k = 0; k < n && al < (int)sizeof acc - 2; k++)
                    acc[al++] = (b[k] >= 32 && b[k] < 127) ? (char)b[k] : '.', acc[al] = 0;
            }
        }
        fprintf(stderr, "приём %s (%s): %s\n", ready ? "открыт" : "молчит, шлю вслепую",
                crc_mode ? "CRC" : "контрольная сумма", acc);

        long blocks = (sz + 127) / 128;
        unsigned char pkt[133];
        for (long blk = 0; blk < blocks; blk++) {
            long off = blk * 128;
            int len = (int)(sz - off > 128 ? 128 : sz - off);
            pkt[0] = 0x01;
            pkt[1] = (unsigned char)((blk + 1) & 0xFF);
            pkt[2] = (unsigned char)(255 - ((blk + 1) & 0xFF));
            memset(pkt + 3, 0xFF, 128);
            memcpy(pkt + 3, img_buf + off, (size_t)len);
            int pktlen;
            if (crc_mode) {
                unsigned short cc = 0;
                for (int i = 0; i < 128; i++) {
                    cc ^= (unsigned short)pkt[3 + i] << 8;
                    for (int k = 0; k < 8; k++)
                        cc = (cc & 0x8000) ? (unsigned short)((cc << 1) ^ 0x1021) : (unsigned short)(cc << 1);
                }
                pkt[131] = (unsigned char)(cc >> 8);
                pkt[132] = (unsigned char)(cc & 0xFF);
                pktlen = 133;
            } else {
                unsigned char sum = 0;
                for (int i = 0; i < 128; i++) sum = (unsigned char)(sum + pkt[3 + i]);
                pkt[131] = sum;
                pktlen = 132;
            }

            int ok = 0;
            for (int try = 0; try < 8 && !ok; try++) {
                if (blk == 0 && try == 1 && crc_mode) {
                    crc_mode = 0;
                    unsigned char sum = 0;
                    for (int i = 0; i < 128; i++) sum = (unsigned char)(sum + pkt[3 + i]);
                    pkt[131] = sum;
                    pktlen = 132;
                    fprintf(stderr, "перехожу на контрольную сумму\n");
                }
                if (write(fd, pkt, (size_t)pktlen) < 0) {}
                struct timespec s0, s1;
                clock_gettime(CLOCK_MONOTONIC, &s0);
                for (;;) {
                    unsigned char rb;
                    fd_set r;
                    FD_ZERO(&r);
                    FD_SET(fd, &r);
                    struct timeval tv = { 0, 200000 };
                    if (select(fd + 1, &r, NULL, NULL, &tv) > 0 && read(fd, &rb, 1) == 1) {
                        if (rb == 0x06) { ok = 1; break; }
                        if (rb == 0x15) break;
                        if (rb == 0x18) { printf("{\"ok\":0,\"error\":\"отменено чипом\",\"block\":%ld}\n", blk + 1); return 1; }
                    }
                    clock_gettime(CLOCK_MONOTONIC, &s1);
                    if (s1.tv_sec - s0.tv_sec > 4) break;
                }
            }
            if (!ok) {
                remove("/tmp/.zig_flashing");
                printf("{\"ok\":0,\"error\":\"блок не принят\",\"block\":%ld}\n", blk + 1);
                return 1;
            }
            if ((blk % 40) == 0) fprintf(stderr, "блоков отправлено %ld из %ld\n", blk, blocks);
        }

        unsigned char eot = 0x04;
        for (int i = 0; i < 5; i++) {
            if (write(fd, &eot, 1) < 0) {}
            unsigned char rb;
            fd_set r;
            FD_ZERO(&r);
            FD_SET(fd, &r);
            struct timeval tv = { 1, 500000 };
            if (select(fd + 1, &r, NULL, NULL, &tv) > 0 && read(fd, &rb, 1) == 1 && rb == 0x06) break;
        }
        acc[0] = 0;
        struct timespec e0, e1;
        clock_gettime(CLOCK_MONOTONIC, &e0);
        for (;;) {
            unsigned char b[128];
            fd_set r;
            FD_ZERO(&r);
            FD_SET(fd, &r);
            struct timeval tv = { 0, 200000 };
            if (select(fd + 1, &r, NULL, NULL, &tv) > 0) {
                int n = (int)read(fd, b, sizeof b);
                int al = (int)strlen(acc);
                for (int k = 0; k < n && al < (int)sizeof acc - 2; k++)
                    acc[al++] = (b[k] >= 32 && b[k] < 127) ? (char)b[k] : '.', acc[al] = 0;
            }
            clock_gettime(CLOCK_MONOTONIC, &e1);
            if (e1.tv_sec - e0.tv_sec > 8) break;
        }
        if (write(fd, "2\r", 2) < 0) {}
        tcdrain(fd);
        sleep(3);
        port_baud(57600);
        remove("/tmp/.zig_flashing");
        printf("{\"ok\":1,\"blocks\":%ld,\"size\":%ld,\"tail\":\"%s\"}\n", blocks, sz, acc);
    } else if (!strcmp(cmd, "btlscan")) {
        int mode = argc > 2 ? atoi(argv[2]) : 1;
        unsigned char d[1] = { (unsigned char)mode };
        ezsp_cmd(0x8F, d, 1);
        tcdrain(fd);
        usleep((useconds_t)(getenv("ZIG_SETTLE") ? atoi(getenv("ZIG_SETTLE")) : 1200) * 1000);
        static const int BAUDS[] = { 115200, 57600, 38400, 19200, 9600 };
        printf("{\"ok\":1,\"mode\":%d,\"probe\":[", mode);
        for (unsigned bi = 0; bi < sizeof BAUDS / sizeof BAUDS[0]; bi++) {
            port_baud(BAUDS[bi]);
            char acc[300] = "";
            char hx[300] = "";
            static const char POKES[] = { '\r', 0x55, '\n', 'C', ' ', '?' };
            int wake = getenv("ZIG_WAKE") ? (int)strtol(getenv("ZIG_WAKE"), NULL, 0) : -1;
            int npoke = getenv("ZIG_NPOKE") ? atoi(getenv("ZIG_NPOKE")) : 6;
            for (int poke = 0; poke < npoke; poke++) {
                char c = wake >= 0 ? (char)wake : POKES[poke % 6];
                if (write(fd, &c, 1) < 0) {}
                struct timespec p0, p1;
                clock_gettime(CLOCK_MONOTONIC, &p0);
                for (;;) {
                    unsigned char b[64];
                    fd_set r;
                    FD_ZERO(&r);
                    FD_SET(fd, &r);
                    struct timeval tv = { 0, 60000 };
                    if (select(fd + 1, &r, NULL, NULL, &tv) > 0) {
                        int n = (int)read(fd, b, sizeof b);
                        for (int k = 0; k < n; k++) {
                            int al = (int)strlen(acc);
                            if (al < (int)sizeof acc - 2) {
                                acc[al] = (b[k] >= 32 && b[k] < 127) ? (char)b[k] : '.';
                                acc[al + 1] = 0;
                            }
                            if (strlen(hx) < sizeof hx - 4)
                                snprintf(hx + strlen(hx), sizeof hx - strlen(hx), "%02X", b[k]);
                        }
                    }
                    clock_gettime(CLOCK_MONOTONIC, &p1);
                    if ((p1.tv_sec - p0.tv_sec) * 1000 + (p1.tv_nsec - p0.tv_nsec) / 1000000 > 250) break;
                }
            }
            printf("%s{\"baud\":%d,\"text\":\"%s\",\"hex\":\"%s\"}",
                   bi ? "," : "", BAUDS[bi], acc, hx);
        }
        printf("]}\n");
    } else if (!strcmp(cmd, "btl")) {
        int mode = argc > 2 ? atoi(argv[2]) : 1;
        int baud = argc > 3 ? atoi(argv[3]) : 115200;
        int secs = argc > 4 ? atoi(argv[4]) : 6;
        const char *poke = getenv("ZIG_POKE") ? getenv("ZIG_POKE") : "\r";
        unsigned char d[1] = { (unsigned char)mode }, pl[64];
        int lst = -1;
        ezsp_cmd(0x8F, d, 1);
        for (int i = 0; i < 2; i++) {
            int pn = ezsp_read(pl, sizeof pl, 150);
            if (pn >= 4 && pl[2] == 0x8F) { lst = pl[3]; break; }
        }
        port_baud(baud);
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        char hex[2048] = "", txt[1024] = "";
        int total = 0;
        for (;;) {
            if (poke[0]) {
                if (!strcmp(poke, "CR")) { char c = '\r'; if (write(fd, &c, 1) < 0) {} }
                else if (!strcmp(poke, "U")) { char c = 0x55; if (write(fd, &c, 1) < 0) {} }
                else if (!strcmp(poke, "C")) { char c = 'C'; if (write(fd, &c, 1) < 0) {} }
                else if (strcmp(poke, "none") != 0) { if (write(fd, poke, strlen(poke)) < 0) {} }
            }
            fd_set r;
            FD_ZERO(&r);
            FD_SET(fd, &r);
            struct timeval tv = { 0, 30000 };
            if (select(fd + 1, &r, NULL, NULL, &tv) > 0) {
                unsigned char b[128];
                int n = (int)read(fd, b, sizeof b);
                for (int k = 0; k < n && total < 400; k++, total++) {
                    snprintf(hex + strlen(hex), sizeof hex - strlen(hex), "%02X ", b[k]);
                    int tl = (int)strlen(txt);
                    if (tl < (int)sizeof txt - 2)
                        txt[tl] = (b[k] >= 32 && b[k] < 127) ? (char)b[k] : '.', txt[tl + 1] = 0;
                }
            }
            clock_gettime(CLOCK_MONOTONIC, &t1);
            if ((t1.tv_sec - t0.tv_sec) > secs) break;
        }
        printf("{\"ok\":%d,\"launch\":%d,\"baud\":%d,\"bytes\":%d,\"hex\":\"%s\",\"text\":\"%s\"}\n",
               total > 0 ? 1 : 0, lst, baud, total, hex, txt);
    } else if (!strcmp(cmd, "beacon")) {
        int ch = argc > 2 ? atoi(argv[2]) : 20;
        int period = argc > 3 ? atoi(argv[3]) : 10;
        const char *me = argc > 4 ? argv[4] : "almond";
        const char *out = getenv("ZIG_PEERS") ? getenv("ZIG_PEERS") : "/tmp/lcd_zig_peers.json";
        unsigned char pl[128], d[130];
        int r_start = -1, r_ch = -1;

        signal(SIGTERM, on_term);
        signal(SIGINT, on_term);
        zkey_load();

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
        mfg_power(txmode, getenv("ZIG_POWER") ? atoi(getenv("ZIG_POWER")) : 3);
        if (r_start != 0 || r_ch != 0) {
            printf("{\"ok\":0,\"start\":%d,\"channel\":%d}\n", r_start, r_ch);
            return 1;
        }

        unsigned int myid = 0;
        for (const char *q = me; *q; q++) myid = myid * 31u + (unsigned char)*q;
        myid = (myid & 0x7FFF) | 0x0001;

        struct { char name[24]; int rssi, lqi; long seen; int seq; unsigned int ctr;
                 unsigned int cmd_ctr; long cmd_seen; char tele[320]; } pr[8];
        const char *cmdfile = getenv("ZIG_CMDFILE") ? getenv("ZIG_CMDFILE") : "/tmp/.zig_cmd";
        int npr = 0;
        memset(pr, 0, sizeof pr);
        long last_tx = 0, last_save = 0;
        int seq = 0;
        while (!stop_flag) {
            long now = (long)time(NULL);
            {
                char cb[160];
                int cn = 0;
                FILE *cf = fopen(cmdfile, "r");
                if (cf) {
                    cn = (int)fread(cb, 1, sizeof cb - 1, cf);
                    fclose(cf);
                    remove(cmdfile);
                }
                if (cn > 0) {
                    cb[cn] = 0;
                    char tgt[24] = "", act[24] = "";
                    if (sscanf(cb, "%23s %23s", tgt, act) == 2 && tgt[0] && act[0]
                        && strcmp(tgt, me) == 0) {
                        cmd_exec(act);
                        if (getenv("ZIG_DEBUG"))
                            fprintf(stderr, "команда '%s' себе выполнена\n", act);
                    } else if (sscanf(cb, "%23s %23s", tgt, act) == 2 && tgt[0] && act[0]) {
                        int ml = (int)strlen(me); if (ml > 20) ml = 20;
                        int tl2 = (int)strlen(tgt); if (tl2 > 20) tl2 = 20;
                        int al = (int)strlen(act); if (al > 20) al = 20;
                        unsigned char payload[80];
                        int pn2 = 0;
                        payload[pn2++] = ZCMD_MARK;
                        payload[pn2++] = (unsigned char)ml;
                        memcpy(payload + pn2, me, ml); pn2 += ml;
                        payload[pn2++] = (unsigned char)tl2;
                        memcpy(payload + pn2, tgt, tl2); pn2 += tl2;
                        payload[pn2++] = (unsigned char)al;
                        memcpy(payload + pn2, act, al); pn2 += al;
                        unsigned char fb[176];
                        unsigned int cctr = (unsigned int)time(NULL);
                        int fn = frame_build(fb, seq++, myid, cctr, payload, pn2);
                        for (int rep = 0; rep < 4; rep++) mfg_send(fb, fn, ch);
                        if (getenv("ZIG_DEBUG"))
                            fprintf(stderr, "команда '%s' -> %s отправлена\n", act, tgt);
                    }
                }
            }
            if (now - last_tx >= period) {
                last_tx = now;
                int tl = (int)strlen(me);
                if (tl > 20) tl = 20;
                unsigned char tele[80];
                int tn = tele_pack(tele, sizeof tele);
                int n = 0;
                unsigned char body[160];
                unsigned int ctr = (unsigned int)time(NULL);
                body[n++] = 0x41;
                body[n++] = 0x88;
                body[n++] = (unsigned char)seq++;
                body[n++] = 0xFF; body[n++] = 0xFF;
                body[n++] = 0xFF; body[n++] = 0xFF;
                body[n++] = (unsigned char)(myid & 0xFF);
                body[n++] = (unsigned char)((myid >> 8) & 0xFF);
                body[n++] = 0x41;
                body[n++] = zkey_ok ? ZSEC_CCM : ZSEC_PLAIN;
                body[n++] = (unsigned char)(ctr & 0xFF);
                body[n++] = (unsigned char)((ctr >> 8) & 0xFF);
                body[n++] = (unsigned char)((ctr >> 16) & 0xFF);
                body[n++] = (unsigned char)((ctr >> 24) & 0xFF);
                int aadlen = n;
                int pstart = n;
                body[n++] = (unsigned char)tl;
                memcpy(body + n, me, tl); n += tl;
                memcpy(body + n, tele, tn); n += tn;
                int plen = n - pstart;
                if (zkey_ok) {
                    unsigned char tag[ZSEC_MIC];
                    if (zsec_seal(body + pstart, plen, body, aadlen, myid, ctr, tag) == 0) {
                        memcpy(body + n, tag, ZSEC_MIC);
                        n += ZSEC_MIC;
                    } else {
                        body[9] = ZSEC_PLAIN;
                    }
                }
                body[n++] = 0; body[n++] = 0;
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
            if (pn >= 26 && pl[2] == 0x8E && pl[6] == 0x41 && pl[7] == 0x88
                && pl[15] == 0x41) {
                int lqi = pl[3], rssi = (signed char)pl[4], len = pl[5];
                int sec = pl[16];
                unsigned int src = pl[13] | (pl[14] << 8);
                unsigned int ctr = (unsigned int)pl[17] | ((unsigned int)pl[18] << 8)
                                 | ((unsigned int)pl[19] << 16) | ((unsigned int)pl[20] << 24);
                int plen = len - 15 - 2 - (sec == ZSEC_CCM ? ZSEC_MIC : 0);
                unsigned char body[160];
                if (plen < 2 || plen > (int)sizeof body || 21 + plen > pn) continue;
                memcpy(body, pl + 21, plen);
                if (sec == ZSEC_CCM) {
                    if (!zkey_ok) continue;
                    if (zsec_open(body, plen, pl + 6, 15, src, ctr,
                                  pl + 21 + plen) != 0) continue;
                } else if (zkey_ok) {
                    continue;
                }
                if (body[0] == ZCMD_MARK) {
                    int o2 = 1;
                    int sl = o2 < plen ? body[o2++] : 0;
                    if (sl < 0 || sl > 20 || o2 + sl > plen) { continue; }
                    char sname[24]; int si = 0;
                    for (; si < sl; si++) { unsigned char c = body[o2 + si];
                        sname[si] = (c >= 32 && c < 127) ? (char)c : '.'; }
                    sname[si] = 0; o2 += sl;
                    int dl = o2 < plen ? body[o2++] : 0;
                    if (dl < 0 || dl > 20 || o2 + dl > plen) { continue; }
                    char dname[24]; memcpy(dname, body + o2, dl); dname[dl] = 0; o2 += dl;
                    int al = o2 < plen ? body[o2++] : 0;
                    if (al < 0 || al > 20 || o2 + al > plen) { continue; }
                    char act[24]; memcpy(act, body + o2, al); act[al] = 0;
                    if (strcmp(dname, me) != 0) { continue; }
                    if (sec != ZSEC_CCM) { continue; }
                    int idx = peer_slot(sname);
                    if (idx >= 0) {
                        if (ctr <= pr[idx].cmd_ctr && (long)time(NULL) - pr[idx].cmd_seen < 300) continue;
                        pr[idx].cmd_ctr = ctr;
                        pr[idx].cmd_seen = (long)time(NULL);
                    }
                    cmd_exec(act);
                    if (getenv("ZIG_DEBUG"))
                        fprintf(stderr, "команда '%s' от %s выполнена\n", act, sname);
                    continue;
                }
                int tl = body[0];
                if (tl < 0 || tl > 20 || tl + 1 > plen) tl = 0;
                char nm[24];
                int k = 0;
                for (; k < tl; k++) {
                    unsigned char c = body[1 + k];
                    nm[k] = (c >= 32 && c < 127) ? (char)c : '.';
                }
                nm[k] = 0;
                char mj[320];
                tele_unpack(body + 1 + tl, plen - 1 - tl, mj, sizeof mj);
                if (k > 0 && strcmp(nm, me) != 0) {
                    int idx = peer_slot(nm);
                    if (idx >= 0 && sec == ZSEC_CCM && ctr <= pr[idx].ctr
                        && (long)time(NULL) - pr[idx].seen < 120) continue;
                    if (idx >= 0) {
                        pr[idx].ctr = ctr;
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
                    fprintf(f, "{\"ok\":1,\"me\":\"%s\",\"ch\":%d,\"enc\":%d,"
                               "\"chip\":\"EM357 EZSP v%d %d.%d.%d.%d\",\"ts\":%ld,\"peers\":[",
                            me, ch, zkey_ok, proto, (sver >> 12) & 15, (sver >> 8) & 15,
                            (sver >> 4) & 15, sver & 15, now);
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
        int ch = argc > 2 ? atoi(argv[2]) : 20;
        int sec = argc > 3 ? atoi(argv[3]) : 10;
        int sending = !strcmp(cmd, "send");
        const char *text = argc > 4 ? argv[4] : "ALMOND";
        unsigned char pl[128], d[130];
        int r_start = -1, r_ch = -1;

        d[0] = (unsigned char)(sending ? 0 : 1);
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
            int pw = getenv("ZIG_POWER") ? atoi(getenv("ZIG_POWER")) : 3;
            int pmode = getenv("ZIG_PMODE") ? atoi(getenv("ZIG_PMODE")) : txmode;
            fprintf(stderr, "мощность %d режим %d -> статус %d\n",
                    pw, pmode, mfg_power(pmode, pw));
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
                d[0] = (unsigned char)(tl + 4);
                d[1] = 0x41;
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
                    int show = len > 2 ? len - 2 : 0;
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
    } else if (!strcmp(cmd, "tokens")) {
        static const char *TN[] = { "custom_version", "string", "board_name",
                                    "manuf_id", "phy_config", "bootload_key",
                                    "ash_config", "ezsp_storage", "stack_cal",
                                    "cbke", "install_code", "cal_filter" };
        unsigned char pl[128], d[1];
        printf("{\"ok\":1,\"tokens\":{");
        int first = 1;
        for (int id = 0; id < 12; id++) {
            d[0] = (unsigned char)id;
            ezsp_cmd(0x0B, d, 1);
            for (int i = 0; i < 5; i++) {
                int pn = ezsp_read(pl, sizeof pl, 500);
                if (pn >= 4 && pl[2] == 0x0B) {
                    char hex[130] = "";
                    int n = pn - 4;
                    if (n > 48) n = 48;
                    for (int k = 0; k < n; k++)
                        snprintf(hex + strlen(hex), sizeof hex - strlen(hex), "%02X", pl[4 + k]);
                    printf("%s\"%s\":\"%s\"", first ? "" : ",", TN[id], hex);
                    first = 0;
                    break;
                }
            }
        }
        printf("}}\n");
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
        int tmode = argc > 4 ? atoi(argv[4]) : txmode;
        int tpow = argc > 5 ? atoi(argv[5])
                            : (getenv("ZIG_POWER") ? atoi(getenv("ZIG_POWER")) : 3);
        r_pow = mfg_power(tmode, tpow);
        ezsp_cmd(0x85, NULL, 0);
        for (int i = 0; i < 6; i++) { int pn = ezsp_read(pl, sizeof pl, 600);
            if (pn >= 4 && pl[2] == 0x85) { r_tone = pl[3]; break; } }
        printf("{\"ok\":%d,\"start\":%d,\"channel\":%d,\"power\":%d,\"tone\":%d,\"ch\":%d,\"sec\":%d,"
               "\"mode\":%d,\"dbm\":%d}\n",
               r_tone == 0 ? 1 : 0, r_start, r_ch, r_pow, r_tone, ch, sec, tmode, tpow);
        fflush(stdout);
        time_t t0 = time(NULL);
        while (time(NULL) - t0 < sec) ezsp_read(pl, sizeof pl, 500);
        ezsp_cmd(0x86, NULL, 0);
        ezsp_read(pl, sizeof pl, 600);
        ezsp_cmd(0x84, NULL, 0);
        ezsp_read(pl, sizeof pl, 600);
    } else if (!strcmp(cmd, "hold")) {
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
    if (scanning) network_init();
    close(fd);
    return 0;
}
