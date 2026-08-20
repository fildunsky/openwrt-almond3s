#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#define TELE_PEERS  "/tmp/lcd_zig_peers.json"
#define TELE_SELF   "/tmp/almond_tele.json"
#define TELE_MODEM  "/tmp/5gmodem_tele.json"
#define TELE_STALE  90

static int sock = -1;
static volatile int stop_flag;

static void on_term(int sig)
{
    (void)sig;
    stop_flag = 1;
}

static int enc_len(unsigned char *o, int len)
{
    int n = 0;
    do {
        unsigned char b = (unsigned char)(len % 128);
        len /= 128;
        if (len > 0) b |= 0x80;
        o[n++] = b;
    } while (len > 0 && n < 4);
    return n;
}

static int put_str(unsigned char *o, const char *s)
{
    int l = (int)strlen(s);
    o[0] = (unsigned char)(l >> 8);
    o[1] = (unsigned char)(l & 0xFF);
    memcpy(o + 2, s, (size_t)l);
    return l + 2;
}

static int mqtt_publish(const char *topic, const char *payload, int retain)
{
    static unsigned char buf[4096];
    int tl = (int)strlen(topic), pl = (int)strlen(payload);
    int rem = 2 + tl + pl;
    int n = 0;
    if (rem + 8 > (int)sizeof buf) return -1;
    buf[n++] = (unsigned char)(0x30 | (retain ? 1 : 0));
    n += enc_len(buf + n, rem);
    n += put_str(buf + n, topic);
    memcpy(buf + n, payload, (size_t)pl);
    n += pl;
    return write(sock, buf, (size_t)n) == n ? 0 : -1;
}

static int mqtt_connect(const char *host, int port, const char *id,
                        const char *user, const char *pass, const char *will_topic)
{
    struct addrinfo hints, *res = NULL, *p;
    char sport[8];
    unsigned char buf[512], rsp[8];
    int n = 0, rem, flags = 0x02;

    snprintf(sport, sizeof sport, "%d", port);
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, sport, &hints, &res) != 0) return -1;
    for (p = res; p; p = p->ai_next) {
        sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (sock < 0) continue;
        struct timeval tv = { 10, 0 };
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(sock, p->ai_addr, p->ai_addrlen) == 0) break;
        close(sock);
        sock = -1;
    }
    freeaddrinfo(res);
    if (sock < 0) return -1;

    if (will_topic && will_topic[0]) flags |= 0x04 | 0x20;
    if (user && user[0]) flags |= 0x80;
    if (pass && pass[0]) flags |= 0x40;

    rem = 10 + 2 + (int)strlen(id);
    if (will_topic && will_topic[0]) rem += 2 + (int)strlen(will_topic) + 2 + 7;
    if (user && user[0]) rem += 2 + (int)strlen(user);
    if (pass && pass[0]) rem += 2 + (int)strlen(pass);

    buf[n++] = 0x10;
    n += enc_len(buf + n, rem);
    n += put_str(buf + n, "MQTT");
    buf[n++] = 0x04;
    buf[n++] = (unsigned char)flags;
    buf[n++] = 0x00; buf[n++] = 0x3C;
    n += put_str(buf + n, id);
    if (will_topic && will_topic[0]) {
        n += put_str(buf + n, will_topic);
        n += put_str(buf + n, "offline");
    }
    if (user && user[0]) n += put_str(buf + n, user);
    if (pass && pass[0]) n += put_str(buf + n, pass);

    if (write(sock, buf, (size_t)n) != n) { close(sock); sock = -1; return -1; }
    if (read(sock, rsp, 4) != 4 || rsp[0] != 0x20 || rsp[3] != 0x00) {
        close(sock);
        sock = -1;
        return -1;
    }
    return 0;
}

static int slurp(const char *path, char *buf, int max, int stale)
{
    struct stat sb;
    FILE *f;
    size_t got;
    buf[0] = 0;
    if (stat(path, &sb) != 0) return 0;
    if (stale > 0 && (long)time(NULL) - (long)sb.st_mtime > stale) return -1;
    f = fopen(path, "r");
    if (!f) return 0;
    got = fread(buf, 1, (size_t)max - 1, f);
    buf[got] = 0;
    fclose(f);
    return got > 0 ? 1 : 0;
}

static void json_body(const char *src, char *out, int max, int *first)
{
    const char *p = strchr(src, '{');
    const char *e = p ? strrchr(p, '}') : NULL;
    int o = (int)strlen(out);
    if (!p || !e || e <= p + 1) return;
    for (const char *q = p + 1; q < e && o < max - 2; q++) {
        if ((*q == ' ' || *q == '\n' || *q == '\t') && o == (int)strlen(out)) continue;
        if (*first && (*q == ' ' || *q == '\n')) continue;
        out[o++] = *q;
    }
    out[o] = 0;
    while (o > 0 && (out[o - 1] == ' ' || out[o - 1] == ',')) out[--o] = 0;
    *first = 0;
}

static const struct { const char *key, *name, *unit, *dev, *icon; } SENS[] = {
    { "sig",  "Сигнал",        "%",   "signal_strength", NULL },
    { "rsrp", "RSRP",          "dBm", "signal_strength", NULL },
    { "rsrq", "RSRQ",          "dB",  NULL,              "mdi:signal" },
    { "sinr", "SINR",          "dB",  NULL,              "mdi:signal" },
    { "temp", "Температура модема", "°C", "temperature", NULL },
    { "batt", "Батарея",       "%",   "battery",         NULL },
    { "cpu",  "Процессор",     "%",   NULL,              "mdi:cpu-32-bit" },
    { "mem",  "Память",        "%",   NULL,              "mdi:memory" },
    { "disk", "Диск",          "%",   NULL,              "mdi:harddisk" },
    { "up",   "Аптайм",        "min", "duration",        NULL },
    { "wifi", "Клиентов Wi-Fi", NULL, NULL,              "mdi:wifi" },
    { "ping", "Пинг",          "ms",  "duration",        NULL },
    { "rx",   "Приём",         "B/s", "data_rate",       NULL },
    { "tx",   "Передача",      "B/s", "data_rate",       NULL },
    { "sms",  "Новых SMS",     NULL,  NULL,              "mdi:message-text" },
    { "oper", "Оператор",      NULL,  NULL,              "mdi:sim" },
    { "band", "Диапазон",      NULL,  NULL,              "mdi:radio-tower" },
    { "mode", "Режим сети",    NULL,  NULL,              "mdi:network" },
    { "vpn_node", "Узел VPN",  NULL,  NULL,              "mdi:vpn" },
};

static const struct { const char *key, *name, *dev; } BINS[] = {
    { "vpn", "VPN",     "connectivity" },
    { "chg", "Зарядка", "battery_charging" },
};

static char seen_names[8][32];
static int seen_cnt;

static int seen_peer(const char *name)
{
    for (int i = 0; i < seen_cnt; i++)
        if (!strcmp(seen_names[i], name)) return 1;
    if (seen_cnt < 8) snprintf(seen_names[seen_cnt++], sizeof seen_names[0], "%s", name);
    return 0;
}

static void discovery(const char *pfx, const char *node, const char *state, const char *avail)
{
    char topic[256], msg[768];
    for (unsigned i = 0; i < sizeof SENS / sizeof SENS[0]; i++) {
        snprintf(topic, sizeof topic, "homeassistant/sensor/%s_%s/config", node, SENS[i].key);
        snprintf(msg, sizeof msg,
                 "{\"name\":\"%s\",\"state_topic\":\"%s\",\"value_template\":\"{{ value_json.%s }}\","
                 "\"availability_topic\":\"%s\",\"unique_id\":\"%s_%s\"%s%s%s%s%s%s,"
                 "\"device\":{\"identifiers\":[\"%s\"],\"name\":\"%s\",\"model\":\"Almond 3S\"}}",
                 SENS[i].name, state, SENS[i].key, avail, node, SENS[i].key,
                 SENS[i].unit ? ",\"unit_of_measurement\":\"" : "", SENS[i].unit ? SENS[i].unit : "",
                 SENS[i].unit ? "\"" : "",
                 SENS[i].dev ? ",\"device_class\":\"" : "", SENS[i].dev ? SENS[i].dev : "",
                 SENS[i].dev ? "\"" : "",
                 node, node);
        mqtt_publish(topic, msg, 1);
        (void)pfx;
    }
    for (unsigned i = 0; i < sizeof BINS / sizeof BINS[0]; i++) {
        snprintf(topic, sizeof topic, "homeassistant/binary_sensor/%s_%s/config", node, BINS[i].key);
        snprintf(msg, sizeof msg,
                 "{\"name\":\"%s\",\"state_topic\":\"%s\",\"value_template\":\"{{ value_json.%s }}\","
                 "\"payload_on\":1,\"payload_off\":0,\"availability_topic\":\"%s\","
                 "\"unique_id\":\"%s_%s\",\"device_class\":\"%s\","
                 "\"device\":{\"identifiers\":[\"%s\"],\"name\":\"%s\",\"model\":\"Almond 3S\"}}",
                 BINS[i].name, state, BINS[i].key, avail, node, BINS[i].key, BINS[i].dev,
                 node, node);
        mqtt_publish(topic, msg, 1);
    }
}

static int peer_next(const char *buf, int from, char *name, int nmax,
                     char *body, int bmax, int *age)
{
    const char *p = strstr(buf + from, "{\"name\":\"");
    if (!p) return -1;
    p += 9;
    int n = 0;
    while (*p && *p != '"' && n < nmax - 1) name[n++] = *p++;
    name[n] = 0;
    const char *a = strstr(p, "\"age\":");
    *age = a ? atoi(a + 6) : 9999;
    const char *m = strstr(p, "\"m\":{");
    if (!m) return -1;
    m += 5;
    const char *e = strchr(m, '}');
    if (!e) return -1;
    int bl = (int)(e - m);
    if (bl >= bmax) bl = bmax - 1;
    memcpy(body, m, (size_t)bl);
    body[bl] = 0;
    return (int)(e - buf);
}

int main(int argc, char **argv)
{
    const char *host = argc > 1 ? argv[1] : NULL;
    int port = argc > 2 ? atoi(argv[2]) : 1883;
    const char *node = argc > 3 ? argv[3] : "almond";
    const char *user = argc > 4 ? argv[4] : "";
    const char *pass = argc > 5 ? argv[5] : "";
    const char *pfx = argc > 6 ? argv[6] : "almond3s";
    int period = argc > 7 ? atoi(argv[7]) : 60;
    char state[256], avail[256], selfb[1024], modemb[1024], payload[2048];
    static char peersb[4096];
    long last = 0;

    if (!host || !host[0]) {
        printf("{\"ok\":0,\"error\":\"не задан брокер\"}\n");
        return 1;
    }
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGPIPE, SIG_IGN);

    snprintf(state, sizeof state, "%s/%s/state", pfx, node);
    snprintf(avail, sizeof avail, "%s/%s/available", pfx, node);

    while (!stop_flag) {
        if (sock < 0) {
            if (mqtt_connect(host, port, node, user, pass, avail) != 0) {
                sleep(15);
                continue;
            }
            mqtt_publish(avail, "online", 1);
            discovery(pfx, node, state, avail);
            fprintf(stderr, "подключено к %s:%d\n", host, port);
        }

        long now = (long)time(NULL);
        if (now - last >= period) {
            int first = 1;
            last = now;
            payload[0] = 0;
            strcpy(payload, "{");
            if (slurp(TELE_SELF, selfb, sizeof selfb, 0) > 0)
                json_body(selfb, payload, sizeof payload, &first);
            if (slurp(TELE_MODEM, modemb, sizeof modemb, TELE_STALE) > 0) {
                int l = (int)strlen(payload);
                if (l > 1 && payload[l - 1] != ',') strcat(payload, ",");
                json_body(modemb, payload, sizeof payload, &first);
            }
            {
                int l = (int)strlen(payload);
                while (l > 1 && (payload[l - 1] == ',' || payload[l - 1] == ' ')) payload[--l] = 0;
                strcat(payload, "}");
            }
            if (mqtt_publish(state, payload, 0) != 0) {
                close(sock);
                sock = -1;
                continue;
            }

            if (slurp(TELE_PEERS, peersb, sizeof peersb, 0) > 0) {
                int off = 0, guard = 0;
                char pname[32], pbody[1024], ptopic[256], pavail[256];
                int page;
                while (guard++ < 8) {
                    int nx = peer_next(peersb, off, pname, sizeof pname,
                                       pbody, sizeof pbody, &page);
                    if (nx < 0) break;
                    off = nx;
                    if (page > 300 || pname[0] == 0) continue;
                    snprintf(ptopic, sizeof ptopic, "%s/%s/state", pfx, pname);
                    snprintf(pavail, sizeof pavail, "%s/%s/available", pfx, pname);
                    if (!seen_peer(pname)) {
                        mqtt_publish(pavail, "online", 1);
                        discovery(pfx, pname, ptopic, pavail);
                    }
                    char pjson[1100];
                    snprintf(pjson, sizeof pjson, "{%s}", pbody);
                    mqtt_publish(ptopic, pjson, 0);
                }
            }
        }

        unsigned char ping[2] = { 0xC0, 0x00 };
        if (write(sock, ping, 2) != 2) { close(sock); sock = -1; continue; }
        sleep(5);
    }

    if (sock >= 0) {
        mqtt_publish(avail, "offline", 1);
        unsigned char bye[2] = { 0xE0, 0x00 };
        if (write(sock, bye, 2) != 2) {}
        close(sock);
    }
    return 0;
}
