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
#include <sys/select.h>
#include <dirent.h>

#define TELE_PEERS  "/tmp/lcd_zig_peers.json"
#define TELE_SELF   "/tmp/almond_tele.json"
#define TELE_MODEM  "/tmp/5gmodem_tele.json"
#define TELE_STALE  90
#define SCRIPTS     "/etc/almond3s/scripts"
#define NIGHT_STATE "/etc/almond3s/night_wifi_off"

/* Диалекты управления. Home Assistant слушает свои темы дискавери, HOMEd их
 * не читает вовсе - у него своя структура fd/td. Поэтому не «или-или», а два
 * набора тем от одного демона; что включить, решает uci. */
enum { DIA_NONE = 0, DIA_HA = 1, DIA_HOMED = 2 };

/* Органы управления. Действие - готовый скрипт из комплекта, никакой новой
 * логики: демон только доставляет нажатие. Выключение аппарата наружу НЕ
 * выносим - обратно его удалённо не включить. */
enum { CTL_SWITCH = 0, CTL_BUTTON = 1 };
static const struct { const char *key, *name, *icon; int type; const char *on, *off; } CTRL[] = {
    { "vpn",     "VPN",           "mdi:vpn",           CTL_SWITCH,
      SCRIPTS "/vpn_clash.sh start", SCRIPTS "/vpn_clash.sh stop" },
    { "screen",  "Экран",         "mdi:monitor",       CTL_SWITCH,
      SCRIPTS "/screen.sh on",       SCRIPTS "/screen.sh off" },
    { "wifi_ap", "Точки Wi-Fi",   "mdi:wifi",          CTL_SWITCH,
      SCRIPTS "/night_wifi.sh on",   SCRIPTS "/night_wifi.sh off" },
    { "modem_reset", "Сброс модема", "mdi:restart",    CTL_BUTTON,
      SCRIPTS "/lte_reset.sh",       NULL },
    { "reboot",  "Перезагрузка",  "mdi:restart-alert", CTL_BUTTON,
      SCRIPTS "/reboot.sh",          NULL },
};
#define NCTRL ((int)(sizeof CTRL / sizeof CTRL[0]))

static char g_pfx[64] = "almond3s", g_node[64] = "almond", g_hpfx[64] = "homed";
static int  g_dia = DIA_NONE;
/* Тема состояния с retain: подписчик получает последние метрики сразу при
 * подключении, а не ждёт следующего цикла (по умолчанию до минуты). Держим
 * это ключом, а не насовсем: retain оставляет на брокере последний снимок и
 * после того, как аппарат выключили, - для кого-то это ложная свежесть. */
static int  g_retain = 0;

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

static int mqtt_subscribe(const char *topic)
{
    static unsigned char buf[512];
    static unsigned short pid = 1;
    int tl = (int)strlen(topic);
    int rem = 2 + 2 + tl + 1;
    int n = 0;
    if (rem + 8 > (int)sizeof buf) return -1;
    buf[n++] = 0x82;                       /* SUBSCRIBE, QoS 1 по протоколу */
    n += enc_len(buf + n, rem);
    buf[n++] = (unsigned char)(pid >> 8);
    buf[n++] = (unsigned char)(pid & 0xFF);
    pid++;
    n += put_str(buf + n, topic);
    buf[n++] = 0;                          /* запрашиваем QoS 0 */
    return write(sock, buf, (size_t)n) == n ? 0 : -1;
}

static int read_exact(unsigned char *b, int n)
{
    int got = 0;
    while (got < n) {
        int r = (int)read(sock, b + got, (size_t)(n - got));
        if (r <= 0) return -1;
        got += r;
    }
    return 0;
}

/* Один пакет со входа. Возвращает 1, если это PUBLISH и тема с телом разобраны,
 * 0 для всего прочего (SUBACK, PINGRESP), -1 при обрыве. Слишком длинное тело
 * дочитываем в никуда: рвать соединение из-за чужого сообщения незачем. */
static int mqtt_poll(char *topic, int tmax, char *body, int bmax)
{
    unsigned char h, b, tmp[256];
    int mul = 1, rem = 0, tl, pl, i;
    if (read_exact(&h, 1) != 0) return -1;
    do {
        if (read_exact(&b, 1) != 0) return -1;
        rem += (b & 127) * mul;
        mul *= 128;
    } while ((b & 128) && mul <= 128 * 128 * 128);

    if ((h >> 4) != 3) {                   /* не PUBLISH - просто вычитываем */
        while (rem > 0) {
            int c = rem > (int)sizeof tmp ? (int)sizeof tmp : rem;
            if (read_exact(tmp, c) != 0) return -1;
            rem -= c;
        }
        return 0;
    }
    if (rem < 2) return 0;
    if (read_exact(tmp, 2) != 0) return -1;
    rem -= 2;
    tl = (tmp[0] << 8) | tmp[1];
    if (tl > rem) return 0;
    for (i = 0; i < tl; i++) {
        unsigned char c;
        if (read_exact(&c, 1) != 0) return -1;
        if (i < tmax - 1) topic[i] = (char)c;
    }
    topic[tl < tmax - 1 ? tl : tmax - 1] = 0;
    rem -= tl;
    if ((h & 0x06) != 0) {                 /* QoS > 0: следом идёт номер пакета */
        if (rem < 2) return 0;
        if (read_exact(tmp, 2) != 0) return -1;
        rem -= 2;
    }
    pl = 0;
    while (rem > 0) {
        unsigned char c;
        if (read_exact(&c, 1) != 0) return -1;
        if (pl < bmax - 1) body[pl++] = (char)c;
        rem--;
    }
    body[pl] = 0;
    return 1;
}

static void run_script(const char *cmd)
{
    char line[256];
    if (!cmd || !cmd[0]) return;
    /* В фоне: перезагрузка и сброс модема длятся секунды, а демон в это время
     * должен продолжать отвечать брокеру на пинги. */
    snprintf(line, sizeof line, "%s >/dev/null 2>&1 &", cmd);
    if (system(line) < 0) {}
}

/* Состояние экрана - по яркости светодиода подсветки. Имя светодиода зависит
 * от DTS, поэтому ищем маской, как это делает screen.sh. */
static int screen_on(void)
{
    DIR *d = opendir("/sys/class/leds");
    struct dirent *e;
    char path[256];
    int v = 1;
    if (!d) return 1;
    while ((e = readdir(d)) != NULL) {
        FILE *f;
        if (!strstr(e->d_name, "power")) continue;
        snprintf(path, sizeof path, "/sys/class/leds/%s/brightness", e->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        if (fscanf(f, "%d", &v) != 1) v = 1;
        fclose(f);
        break;
    }
    closedir(d);
    return v > 0;
}

/* Точки Wi-Fi считаем поднятыми, пока night_wifi.sh не оставил список
 * погашенных им интерфейсов. */
static int wifi_ap_on(void)
{
    struct stat st;
    return !(stat(NIGHT_STATE, &st) == 0 && st.st_size > 0);
}

static int json_flag(const char *json, const char *key)
{
    char pat[32];
    const char *p;
    snprintf(pat, sizeof pat, "\"%s\":", key);
    p = strstr(json, pat);
    return p ? (atoi(p + strlen(pat)) != 0) : 0;
}

static char last_state[2048];

static int ctrl_state(int i)
{
    if (CTRL[i].type == CTL_BUTTON) return 0;
    if (!strcmp(CTRL[i].key, "screen")) return screen_on();
    if (!strcmp(CTRL[i].key, "wifi_ap")) return wifi_ap_on();
    return json_flag(last_state, CTRL[i].key);
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

/* num=1 - числовое измерение: в дискавери уходит state_class "measurement",
 * без него Home Assistant показывает значение в карточке, но не ведёт
 * долговременную статистику - графиков за неделю по такому сенсору не будет.
 * Текстовым (оператор, диапазон, режим, узел VPN) state_class не положен. */
static const struct { const char *key, *name, *unit, *dev, *icon; int num; } SENS[] = {
    { "sig",  "Сигнал",        "%",   "signal_strength", NULL,               1 },
    { "rsrp", "RSRP",          "dBm", "signal_strength", NULL,               1 },
    { "rsrq", "RSRQ",          "dB",  NULL,              "mdi:signal",       1 },
    { "sinr", "SINR",          "dB",  NULL,              "mdi:signal",       1 },
    { "temp", "Температура модема", "°C", "temperature", NULL,               1 },
    { "batt", "Батарея",       "%",   "battery",         NULL,               1 },
    { "cpu",  "Процессор",     "%",   NULL,              "mdi:cpu-32-bit",   1 },
    { "mem",  "Память",        "%",   NULL,              "mdi:memory",       1 },
    { "disk", "Диск",          "%",   NULL,              "mdi:harddisk",     1 },
    { "up",   "Аптайм",        "min", "duration",        NULL,               1 },
    { "wifi", "Клиентов Wi-Fi", NULL, NULL,              "mdi:wifi",         1 },
    { "ping", "Пинг",          "ms",  "duration",        NULL,               1 },
    { "rx",   "Приём",         "B/s", "data_rate",       NULL,               1 },
    { "tx",   "Передача",      "B/s", "data_rate",       NULL,               1 },
    { "sms",  "Новых SMS",     NULL,  NULL,              "mdi:message-text", 1 },
    { "oper", "Оператор",      NULL,  NULL,              "mdi:sim",          0 },
    { "band", "Диапазон",      NULL,  NULL,              "mdi:radio-tower",  0 },
    { "mode", "Режим сети",    NULL,  NULL,              "mdi:network",      0 },
    { "vpn_node", "Узел VPN",  NULL,  NULL,              "mdi:vpn",          0 },
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
    char topic[256], msg[1024];
    for (unsigned i = 0; i < sizeof SENS / sizeof SENS[0]; i++) {
        snprintf(topic, sizeof topic, "homeassistant/sensor/%s_%s/config", node, SENS[i].key);
        snprintf(msg, sizeof msg,
                 "{\"name\":\"%s\",\"state_topic\":\"%s\",\"value_template\":\"{{ value_json.%s }}\","
                 "\"availability_topic\":\"%s\",\"unique_id\":\"%s_%s\"%s%s%s%s%s%s%s%s%s%s,"
                 "\"device\":{\"identifiers\":[\"%s\"],\"name\":\"%s\",\"model\":\"Almond 3S\"}}",
                 SENS[i].name, state, SENS[i].key, avail, node, SENS[i].key,
                 SENS[i].unit ? ",\"unit_of_measurement\":\"" : "", SENS[i].unit ? SENS[i].unit : "",
                 SENS[i].unit ? "\"" : "",
                 SENS[i].dev ? ",\"device_class\":\"" : "", SENS[i].dev ? SENS[i].dev : "",
                 SENS[i].dev ? "\"" : "",
                 SENS[i].icon ? ",\"icon\":\"" : "", SENS[i].icon ? SENS[i].icon : "",
                 SENS[i].icon ? "\"" : "",
                 SENS[i].num ? ",\"state_class\":\"measurement\"" : "",
                 node, node);
        mqtt_publish(topic, msg, 1);
        (void)pfx;
    }
    for (unsigned i = 0; i < sizeof BINS / sizeof BINS[0]; i++) {
        snprintf(topic, sizeof topic, "homeassistant/binary_sensor/%s_%s/config", node, BINS[i].key);
        /* Когда управление включено, VPN приезжает выключателем. Лампочку с тем
         * же именем снимаем пустым retain - иначе в HA две сущности об одном и
         * том же, да ещё с одинаковым unique_id. */
        if ((g_dia & DIA_HA) && !strcmp(BINS[i].key, "vpn")) {
            mqtt_publish(topic, "", 1);
            continue;
        }
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

/* Органы управления для Home Assistant: выключатели и кнопки. Состояние
 * выключателя берётся из общей темы состояния - отдельных тем не заводим. */
static void discovery_ctrl(const char *node, const char *state, const char *avail)
{
    char topic[256], msg[1024], cmdt[256];
    for (int i = 0; i < NCTRL; i++) {
        snprintf(cmdt, sizeof cmdt, "%s/%s/set/%s", g_pfx, node, CTRL[i].key);
        if (CTRL[i].type == CTL_SWITCH) {
            snprintf(topic, sizeof topic, "homeassistant/switch/%s_%s/config", node, CTRL[i].key);
            snprintf(msg, sizeof msg,
                     "{\"name\":\"%s\",\"command_topic\":\"%s\",\"payload_on\":\"on\","
                     "\"payload_off\":\"off\",\"state_topic\":\"%s\","
                     "\"value_template\":\"{{ value_json.%s }}\",\"state_on\":\"1\",\"state_off\":\"0\","
                     "\"availability_topic\":\"%s\",\"unique_id\":\"%s_%s\",\"icon\":\"%s\","
                     "\"device\":{\"identifiers\":[\"%s\"],\"name\":\"%s\",\"model\":\"Almond 3S\"}}",
                     CTRL[i].name, cmdt, state, CTRL[i].key, avail, node, CTRL[i].key,
                     CTRL[i].icon, node, node);
        } else {
            snprintf(topic, sizeof topic, "homeassistant/button/%s_%s/config", node, CTRL[i].key);
            snprintf(msg, sizeof msg,
                     "{\"name\":\"%s\",\"command_topic\":\"%s\",\"payload_press\":\"press\","
                     "\"availability_topic\":\"%s\",\"unique_id\":\"%s_%s\",\"icon\":\"%s\","
                     "\"device\":{\"identifiers\":[\"%s\"],\"name\":\"%s\",\"model\":\"Almond 3S\"}}",
                     CTRL[i].name, cmdt, avail, node, CTRL[i].key, CTRL[i].icon, node, node);
        }
        mqtt_publish(topic, msg, 1);
    }
}

/* HOMEd про наши темы дискавери не знает: устройство заводится у него в
 * database.json службы custom, а по MQTT мы разговариваем его же структурой -
 * состояние в fd, команды приходят в td. Выключатель у него зовётся status. */
static void homed_state(const char *node, const char *payload)
{
    char topic[256], msg[64];
    snprintf(topic, sizeof topic, "%s/fd/custom/%s", g_hpfx, node);
    mqtt_publish(topic, payload, g_retain);
    for (int i = 0; i < NCTRL; i++) {
        snprintf(topic, sizeof topic, "%s/fd/custom/%s_%s", g_hpfx, node, CTRL[i].key);
        snprintf(msg, sizeof msg, "{\"status\":\"%s\"}", ctrl_state(i) ? "on" : "off");
        mqtt_publish(topic, msg, 0);
    }
}

static void subscribe_all(const char *node)
{
    char topic[256];
    for (int i = 0; i < NCTRL; i++) {
        if (g_dia & DIA_HA) {
            snprintf(topic, sizeof topic, "%s/%s/set/%s", g_pfx, node, CTRL[i].key);
            mqtt_subscribe(topic);
        }
        if (g_dia & DIA_HOMED) {
            snprintf(topic, sizeof topic, "%s/td/custom/%s_%s", g_hpfx, node, CTRL[i].key);
            mqtt_subscribe(topic);
        }
    }
}

/* Разбор входящего: и «on/off» от Home Assistant, и {"status":"on"} от HOMEd.
 * Кнопке содержимое безразлично - важен сам факт сообщения. */
static void handle_cmd(const char *topic, const char *body, const char *node)
{
    const char *key = strrchr(topic, '/');
    int on;
    if (!key) return;
    key++;
    for (int i = 0; i < NCTRL; i++) {
        char hid[128];
        snprintf(hid, sizeof hid, "%s_%s", node, CTRL[i].key);
        if (strcmp(key, CTRL[i].key) != 0 && strcmp(key, hid) != 0) continue;
        if (CTRL[i].type == CTL_BUTTON) {
            /* Кнопке содержимое безразлично - кроме явного «off». В HOMEd
             * кнопка выражается выключателем, и отпускание тумблера прислало бы
             * второе сообщение: без этой проверки сброс модема случался бы
             * дважды за одно нажатие. */
            if (strstr(body, "off") != NULL) return;
            fprintf(stderr, "нажатие: %s\n", CTRL[i].key);
            run_script(CTRL[i].on);
            if (g_dia & DIA_HOMED) {
                char t[256];
                snprintf(t, sizeof t, "%s/fd/custom/%s_%s", g_hpfx, node, CTRL[i].key);
                mqtt_publish(t, "{\"status\":\"off\"}", 0);
            }
            return;
        }
        on = (strstr(body, "\"on\"") != NULL) || !strcmp(body, "on") || !strcmp(body, "1");
        fprintf(stderr, "переключение: %s -> %s\n", CTRL[i].key, on ? "on" : "off");
        run_script(on ? CTRL[i].on : CTRL[i].off);
        return;
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
    const char *dia = argc > 8 ? argv[8] : "off";
    const char *hpfx = argc > 9 ? argv[9] : "homed";
    g_retain = argc > 10 ? (atoi(argv[10]) != 0) : 0;
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

    if (!strcmp(dia, "ha")) g_dia = DIA_HA;
    else if (!strcmp(dia, "homed")) g_dia = DIA_HOMED;
    else if (!strcmp(dia, "both")) g_dia = DIA_HA | DIA_HOMED;
    snprintf(g_pfx, sizeof g_pfx, "%s", pfx);
    snprintf(g_node, sizeof g_node, "%s", node);
    snprintf(g_hpfx, sizeof g_hpfx, "%s", hpfx);

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
            if (g_dia & DIA_HA) discovery_ctrl(node, state, avail);
            if (g_dia) subscribe_all(node);
            fprintf(stderr, "подключено к %s:%d%s\n", host, port,
                    g_dia ? " (с управлением)" : "");
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
                if (g_dia) {
                    /* Состояние экрана и точек Wi-Fi в телеметрии не лежит -
                     * дописываем прямо здесь, иначе выключателям нечем
                     * показывать своё положение. */
                    char ex[64];
                    snprintf(ex, sizeof ex, "%s\"screen\":%d,\"wifi_ap\":%d",
                             l > 1 ? "," : "", screen_on(), wifi_ap_on());
                    if (l + (int)strlen(ex) + 2 < (int)sizeof payload) strcat(payload, ex);
                }
                strcat(payload, "}");
            }
            snprintf(last_state, sizeof last_state, "%s", payload);
            if (mqtt_publish(state, payload, g_retain) != 0) {
                close(sock);
                sock = -1;
                continue;
            }
            if (g_dia & DIA_HOMED) homed_state(node, payload);

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
                    mqtt_publish(ptopic, pjson, g_retain);
                    if (g_dia & DIA_HOMED) {
                        char ht[256];
                        snprintf(ht, sizeof ht, "%s/fd/custom/%s", g_hpfx, pname);
                        mqtt_publish(ht, pjson, 0);
                    }
                }
            }
        }

        unsigned char ping[2] = { 0xC0, 0x00 };
        if (write(sock, ping, 2) != 2) { close(sock); sock = -1; continue; }

        /* Раньше здесь стоял глухой sleep, и всё пришедшее копилось в сокете.
         * Теперь те же пять секунд ждём на select и разбираем входящее: без
         * этого не только команды, но и ответы на пинг никто не вычитывал. */
        {
            struct timeval tv = { 5, 0 };
            while (!stop_flag) {
                fd_set rf;
                int r;
                FD_ZERO(&rf);
                FD_SET(sock, &rf);
                r = select(sock + 1, &rf, NULL, NULL, &tv);
                if (r < 0) break;
                if (r == 0) break;
                {
                    char t[256], b[512];
                    int k = mqtt_poll(t, sizeof t, b, sizeof b);
                    if (k < 0) { close(sock); sock = -1; break; }
                    if (k == 1 && g_dia) handle_cmd(t, b, node);
                }
                tv.tv_sec = 0;
                tv.tv_usec = 200000;   /* добираем то, что уже пришло следом */
            }
            if (sock < 0) continue;
        }
    }

    if (sock >= 0) {
        mqtt_publish(avail, "offline", 1);
        unsigned char bye[2] = { 0xE0, 0x00 };
        if (write(sock, bye, 2) != 2) {}
        close(sock);
    }
    return 0;
}
