#!/usr/bin/ucode
//
// lcd_ui.uc V260401 by Sublimity
//
// Архитектура: uloop (event loop) + ubus (system data) + uci (config)
// Данные: /tmp/lcd_data.json (от data_collector)
// Рендер: JSON через persistent unix socket → lcd_server / lcd_render
// Тач: ioctl /dev/lcd (kernel lcd_drv touch thread)
//
// Build: scp lcd_ui.uc root@192.168.11.1:/usr/bin/lcd_ui.uc
// Run:   ucode /usr/bin/lcd_ui.uc &
//

'use strict';

import { AF_UNIX, SOCK_STREAM, create as create_socket, poll as sock_poll } from 'socket';
let fs = require("fs");

// No PID lock needed — procd manages single instance (no auto-restart loop below)

// Optional modules — graceful degrade
let ubus_mod, uci_mod, uloop_mod;
try { ubus_mod = require("ubus"); } catch(e) {}
try { uci_mod = require("uci"); } catch(e) {}
try { uloop_mod = require("uloop"); } catch(e) {}

// --- Constants ---
let LCD_W = 320, LCD_H = 240;
let SOCK_PATH = "/tmp/lcd.sock";
let DATA_PATH = "/tmp/lcd_data.json";
let TOUCH_PATH = "/tmp/.lcd_touch";
let SCRIPTS = "/etc/lcd/scripts";  // shell scripts directory

// Colors (lcd_render accepts: #RRGGBB, #XXXX raw RGB565, named)
let C = {
    bg:      "#0D1117", // GitHub Dark Canvas
    hdr:     "#161B22", // GitHub Dark Overlay
    white:   "#C9D1D9", // GH Text Primary
    green:   "#3FB950", // GH Success
    red:     "#F85149", // GH Danger
    yellow:  "#D29922", // GH Warning
    cyan:    "#58A6FF", // GH Accent Blue
    gray:    "#8B949E", // GH Text Secondary
    btn:     "#21262D", // GH Sub-panel
    back:    "#A40E26", // Subdued red for back bar
    accent:  "#58A6FF", // Same as cyan
    dim:     "#484F58", // GH Border/Dim
    widget:  "#161B22", // GitHub Dark Overlay
    border:  "#30363D", // GH Border
    transparent: "#000000", // the logo overlay uses black as transparent
    // Weather icon shading tones
    sun_core:   "#FFD866", // bright sun disc
    sun_ray:    "#D29922", // dimmer amber rays (== yellow)
    cloud_lit:  "#9BA7B4", // cloud, lit top
    cloud_shd:  "#5A6270", // cloud, shadowed underside
    bolt:       "#FFF176", // lightning bolt
};

// Пороги и шкалы — те же, что в таблице C дашборда 5gmodem и в 5gtop.
let MET = {
    signal: { bar: function(v) { return v; },
              lv: function(v) { return v >= 60 ? "ok" : (v >= 30 ? "warn" : "crit"); } },
    rsrp:   { bar: function(v) { return (v + 130) * 100 / 50; },
              lv: function(v) { return v >= -90 ? "ok" : (v >= -105 ? "warn" : "crit"); } },
    rsrq:   { bar: function(v) { return (v + 20) * 100 / 17; },
              lv: function(v) { return v >= -12 ? "ok" : (v >= -16 ? "warn" : "crit"); } },
    sinr:   { bar: function(v) { return (v + 10) * 100 / 30; },
              lv: function(v) { return v >= 13 ? "ok" : (v >= 0 ? "warn" : "crit"); } },
    rssi:   { bar: function(v) { return (v + 110) * 100 / 60; },
              lv: function(v) { return v >= -65 ? "ok" : (v >= -85 ? "warn" : "crit"); } },
};
let LVC = { ok: C.green, warn: C.yellow, crit: C.red };

// length() в ucode возвращает длину в БАЙТАХ. Кириллица в UTF-8 занимает два
// байта, поэтому расчёт ширины текста давал двойную величину и центрирование
// уезжало влево. Считаем знаки: продолжения UTF-8 (10xxxxxx) не в счёт.
function tlen(s) {
    s ??= "";
    let n = 0;
    for (let i = 0; i < length(s); i++)
        if ((ord(s, i) & 0xC0) != 0x80) n++;
    return n;
}

// Обрезка по знакам, а не по байтам: substr() резал кириллицу пополам.
// Тот же формат, что formatPhone в 5gmodem: +7 (993) 335-01-29.
function phone_fmt(raw) {
    let s = trim(raw ?? "");
    if (s == "" || s == "-") return "";
    let d = "";
    for (let i = 0; i < length(s); i++) {
        let c = substr(s, i, 1);
        if (c >= "0" && c <= "9") d += c;
    }
    if (length(d) == 11 && substr(d, 0, 1) == "8") d = "7" + substr(d, 1);
    if (length(d) == 11 && substr(d, 0, 1) == "7")
        return sprintf("+7 (%s) %s-%s-%s", substr(d, 1, 3), substr(d, 4, 3),
                       substr(d, 7, 2), substr(d, 9, 2));
    return s;
}

// Компактный номер: «+7(993)335-01-29» - те же данные, что и с пробелами, но
// 16 знаков вместо 18. Используем везде, где номер делит строку с чем-то ещё.
function phone_short(raw) {
    return replace(phone_fmt(raw), / /g, "");
}

function tcut(s, max) {
    s ??= "";
    if (tlen(s) <= max) return s;
    let out = "", n = 0;
    for (let i = 0; i < length(s); i++) {
        if ((ord(s, i) & 0xC0) != 0x80) {
            if (n >= max) break;
            n++;
        }
        out += chr(ord(s, i));
    }
    return out;
}

function clampi(v, a, b) {
    v = int(v);
    return v < a ? a : (v > b ? b : v);
}

// Timing (seconds)
let T = {
    data:   2,     // data refresh
    burnin: 300,   // сдвиг против выгорания, секунды
    saver:  240,   // idle → screensaver (4 min)
    off:    300,   // idle → backlight off (5 min)
};

// Layout
let HDR_H   = 22;
let TG_LINK = "t.me/openwrt_fun";

let COLS    = 2;
let BTN_PAD = 4;
let BTN_W   = ((LCD_W - (BTN_PAD * 3)) / 2); // 154
let BTN_H   = 68;
let START_Y = HDR_H + BTN_PAD;
let BACK_Y  = LCD_H - 32;

// Touch: lcd_drv returns pixel coordinates directly (0-319, 0-239)
// No ADC mapping needed

// --- State ---
let st = {
    page:   "dashboard",
    mpg:    1,         // menu page (1 or 2)
    screen: "active",
    data:   {},        // sensor data from data_collector
    ltch:   time(),    // last touch time
    ldraw:  0,         // last draw time
    frame:  0,
    ox: 0, oy: 0,     // burn-in pixel offset
    tp:     false,     // touch was pressed (edge detection)
    saver_frame: 0,    // screensaver animation
    blank:  false,     // подсветка погашена (стиль заставки «выкл»)
    sms:    null,      // разобранный список SMS
    sms_ts: 0,         // mtime кэша, по которому разбирали
    sms_pg: 0,         // страница списка
    sms_i:  -1,        // открытое сообщение
    sms_tp: 0,         // страница текста открытого сообщения
    sms_wait: false,   // ждём фоновое чтение из модема
};

// --- Connections ---
let uconn = null;
if (ubus_mod) {
    uconn = ubus_mod.connect();
    if (!uconn) warn("lcd_ui: ubus connect failed\n");
}

let ucur = null;
if (uci_mod) ucur = uci_mod.cursor();

// ---- Язык интерфейса ----
//
// Ключ словаря - английская строка, значение - русская. Незнакомая строка
// возвращается как есть, поэтому забытый перевод не ломает экран, а просто
// остаётся по-английски. Переводим только то, что видит пользователь:
// форматы чисел, ключи JSON и служебные сообщения в логи - не трогаем.

let LANG = null;

function lang() {
    if (LANG == null)
        LANG = (ucur ? (ucur.get("lcd", "display", "lang") ?? "ru") : "ru");
    return LANG;
}

function lang_set(v) {
    LANG = v;
    if (ucur) {
        ucur.set("lcd", "display", "lang", v);
        ucur.commit("lcd");
    }
}

let TR_RU = {
    "System Info": "Система",
    "SYSTEM": "СИСТЕМА",
    "POWER": "ПИТАНИЕ",
    "SOFTWARE": "ПРОШИВКА",
    "Uptime %s": "Время работы %s",
    "Mem %dM": "ОЗУ %dМ",
    "CPU %s": "ЦП %s",
    "Model %s": "Модель %s",
    "Kernel %s": "Ядро %s",
    "Battery not installed": "Батарея не вставлена",
    "ADC %d": "АЦП %d",
    "Battery": "Батарея",
    "Charging": "Заряжается",
    "Raw %s": "Сырые %s",
    "Status OK": "Всё в порядке",
    "Status invalid": "Нет данных",
    "MODEM": "МОДЕМ",
    "SIGNAL": "СИГНАЛ",
    "CELL / NETWORK": "СОТА / СЕТЬ",
    "ROAM": "РОУМ",
    "Modem": "Модем",
    "Modem Reset": "Сброс модема",
    "LTE restart": "перезапуск",
    "Resetting modem...": "Перезапуск модема...",
    "Reboot": "Перезагрузка",
    "System": "Система",
    "REBOOT?": "ПЕРЕЗАГРУЗКА?",
    "YES": "ДА",
    "NO": "НЕТ",
    "Rebooting...": "Перезагружаюсь...",
    "Cancelled": "Отменено",
    "Cancelled (timeout)": "Отменено (таймаут)",
    "Weather": "Погода",
    "Update now": "обновить",
    "Updating forecast...": "Обновляю прогноз...",
    "WEATHER": "ПОГОДА",
    "WEATHER - %s": "ПОГОДА - %s",
    "No data yet": "Нет данных",
    "Tap Weather in menu to fetch": "Меню > Погода - обновить",
    "Open menu > Weather to fetch": "Меню > Погода - обновить",
    "Feels %s   Hum %s": "Ощущается %s   Влажность %s",
    "Feels %s  Hum %s  Wind %s": "Ощущается %s  Влажность %s  Ветер %s",
    "Wind %s": "Ветер %s",
    "City %d/%d": "Город %d/%d",
    "City": "Город",
    "Fetching %s...": "Загружаю %s...",
    "Display": "Экран",
    "SCREENSAVER AFTER": "ЗАСТАВКА ЧЕРЕЗ",
    "Never": "Никогда",
    "%d sec": "%d сек",
    "%d min": "%d мин",
    "Tap screen to wake": "Касание - разбудить",
    "LANGUAGE": "ЯЗЫК",
    "BURN-IN SHIFT": "СДВИГ",
    "SCREENSAVER": "ЗАСТАВКА",
    "full": "Всё",
    "clock": "Часы",
    "line": "Строка",
    "on": "вкл",
    "off": "выкл",
    "Pass: %s": "Пароль: %s",
    "Clients: %d": "Клиентов: %d",
    "WI-FI STATUS": "СОСТОЯНИЕ WI-FI",
    "No Clients": "Нет клиентов",
    "Traffic": "Трафик",
    "UPLINK - %s": "АПЛИНК - %s",
    "IP & clients": "адреса и клиенты",
    "VIEW": "ВИД",
    "Shift": "Сдвиг",
    "Night": "Ночь",
    "NIGHT FROM": "НОЧЬ С",
    "NIGHT TO": "ДО",
    "Model": "Модель",
    "Band": "Диапазон",
    "Number": "Номер",
    "SMS": "СМС",
    "inbox": "входящие",
    "%d new": "новых: %d",
    "Reading inbox...": "Читаю ящик...",
    "No messages": "Сообщений нет",
    "BACK": "НАЗАД",
    "Blank now": "Погасить",
    "MORE >>>": "ЕЩЁ >>>",
    "<<< BACK": "<<< НАЗАД",
    "< BACK": "< НАЗАД",
    "External IP": "Внешний IP",
    "Exit IP:": "Выход:",
    "Disconnected": "Нет связи",
    "Not connected": "Не подключен",
    "Unknown": "Неизвестно",
    "via VPN (WireGuard)": "через VPN (WireGuard)",
    "QR unavailable": "QR недоступен",
    "install qrencode": "поставьте qrencode",
    "uci unavailable": "uci недоступен",
    "%d clients": "%d клиентов",
    "CELL INFO": "ИНФО О СОТЕ",
    "IDENTITY": "ИДЕНТИФИКАТОРЫ",
    "RADIO": "РАДИО",
    "CARRIERS": "НЕСУЩИЕ",
    "ANTENNA PORTS": "АНТЕННЫЕ ПОРТЫ",
    "NEIGHBOURS": "СОСЕДНИЕ СОТЫ",
    "OWN CELL": "СВОЯ СОТА",
    "serving": "своя",
    "Cell %d/%d": "Сота %d/%d",
    "no aggregation": "агрегации нет",
    "no data": "нет данных",
    "initialising...": "инициализация...",
    "no network": "нет сети",
    "no address": "нет адреса",
    "SERVICES": "СЕРВИСЫ",
    "Services": "Сервисы",
    "check": "проверить",
    "Ping": "Пинг",
    "Checking...": "Проверка...",
    "no answer": "нет ответа",
    "not checked": "не проверялось",
    "Info": "Инфо",
    "WiFi": "Wi-Fi",
    "System status": "Состояние",
    "Network": "Сеть",
    "Speed": "Скорость",
};

function tr(s) {
    return lang() == "ru" ? (TR_RU[s] ?? s) : s;
}

// 5gmodem отдаёт время связи как «0d, 00:17:15» - латинская «d» на русском
// экране смотрится чужеродно.
function conn_fmt(v) {
    v = trim(v ?? "");
    if (v == "" || v == "-") return "";
    return lang() == "ru" ? replace(v, "d,", "д,") : v;
}



// =============================================
//  LCD RENDER COMMUNICATION
// =============================================

let cmds = [];

function Q(j) {
    push(cmds, j);
}

function lcd_clear(c) {
    Q(sprintf('{"cmd":"clear","color":"%s"}', c ?? C.bg));
}

function lcd_rect(x, y, w, h, c) {
    Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s"}', x, y, w, h, c));
}

function lcd_text(x, y, text, color, bg, sz) {
    // Экранируем для JSON. Перевод строки обязателен: команды разделяются
    // именно \n, и живой перевод строки в тексте разрезал бы команду пополам.
    text = replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n");
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d}',
        x, y, text, color ?? C.white, bg ?? C.bg, sz ?? 2));
}

// Native socket — connect/send/close per flush (fast, no deadlock)
function lcd_flush() {
    if (!length(cmds)) return;
    push(cmds, '{"cmd":"flush"}');
    let payload = join("\n", cmds) + "\n";
    cmds = [];

    let s;
    try {
        s = create_socket(AF_UNIX, SOCK_STREAM, 0);
        s.connect(SOCK_PATH);
        s.send(payload);
        s.close();
    } catch(e) {
        try { s.close(); } catch(e2) {}
    }
}

// Самая высокая палка вровень со значком батареи - 16 пикселей.
function draw_sigbars(x, y, bars, col, empty) {
    for (let i = 0; i < 5; i++) {
        let bh = 4 + i * 3;
        lcd_rect(x + i * 8, y + 16 - bh, 6, bh, i < bars ? col : (empty ?? C.dim));
    }
}

// Зарядка - зелёная рамка вместо серой. Значок мелкий, рисовать внутри него
// молнию бессмысленно: вырез по фону читается как трещина, а не как символ.
// Незаполненные деления рисуем приглушённым цветом, как незажжённые палки
// уровня сигнала: пустота внутри рамки читалась как «данных нет».
function draw_batt_icon(x, y, w, h, bg, pct, nobat, mono, chg, empty) {
    let frame = mono ?? (chg ? C.green : C.gray);
    lcd_rect(x, y, w, h, frame);
    lcd_rect(x + 1, y + 1, w - 2, h - 2, bg);
    lcd_rect(x + w, y + 5, 2, h - 10, frame);
    if (nobat) return;
    let sections = pct > 75 ? 4 : (pct > 50 ? 3 : (pct > 25 ? 2 : (pct > 0 ? 1 : 0)));
    let sc = mono ?? (sections == 1 ? C.red : (sections == 2 ? C.yellow : C.green));
    let pitch = int((w - 4) / 4);
    let ec = empty ?? C.dim;
    for (let i = 0; i < 4; i++)
        lcd_rect(x + 3 + i * pitch, y + 2, pitch - 2, h - 4, i < sections ? sc : ec);
}



// =============================================
//  HISTORY + TRAFFIC
// =============================================

let HIST_LEN = 60;

let hist = {
    rsrp:  [],   // LTE RSRP (dBm)
    rsrq:  [],   // LTE RSRQ (dB)
    ping:  [],   // Google ping ms
    rx:    [],   // wwan0 RX bytes/sec
    tx:    [],   // wwan0 TX bytes/sec
    wan_rx: [],  // wan RX bytes/sec
    wan_tx: [],  // wan TX bytes/sec
};

let last_net = null;

function hist_push(arr, val) {
    push(arr, val);
    if (length(arr) > HIST_LEN)
        splice(arr, 0, 1);
}

// Второй график был жёстко привязан к "wan". На роутере, где аплинк - LTE или
// Wi-Fi-клиент, эта строка всегда нулевая, а реальный трафик не виден нигде.
// Берём интерфейс маршрута по умолчанию: он и есть текущий аплинк.
let uplink_dev = null;
let uplink_seen = 0;

function default_iface() {
    let now = time();
    if (uplink_dev != null && now - uplink_seen < 10) return uplink_dev;
    uplink_seen = now;
    let raw = fs.readfile("/proc/net/route");
    if (raw) {
        for (let line in split(raw, "\n")) {
            let f = split(trim(line), /[ \t]+/);
            if (length(f) > 2 && f[1] == "00000000") {
                uplink_dev = f[0];
                return uplink_dev;
            }
        }
    }
    uplink_dev = null;
    return null;
}

function collect_traffic() {
    let raw = fs.readfile("/proc/net/dev");
    if (!raw) return;
    let period = T.data > 0 ? T.data : 1;
    let now_net = {};
    for (let line in split(raw, "\n")) {
        let m = match(line, /^\s*(\S+):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)/);
        if (m)
            now_net[m[1]] = { rx: +m[2], tx: +m[3] };
    }
    if (last_net) {
        let delta = (iface, key) => {
            let cur = now_net[iface]?.[key] ?? 0;
            let prev = last_net[iface]?.[key] ?? 0;
            let d = cur - prev;
            return d >= 0 ? int(d / period) : 0;
        };
        hist_push(hist.rx, delta("wwan0", "rx"));
        hist_push(hist.tx, delta("wwan0", "tx"));
        let up = default_iface() ?? "wan";
        hist_push(hist.wan_rx, delta(up, "rx"));
        hist_push(hist.wan_tx, delta(up, "tx"));
    }
    last_net = now_net;
}

function update_history() {
    let d = st.data;
    hist_push(hist.rsrp, int(+(d?.uqmi?.rsrp ?? 0)));
    hist_push(hist.rsrq, int(+(d?.uqmi?.rsrq ?? 0)));
    hist_push(hist.ping, int(+(d?.ping?.google_ms ?? 0)));
    collect_traffic();
}

// Line graph with scale, thresholds, and labels
// thresholds: [{val, color, label}, ...] — horizontal reference lines
// Трафик охватывает три порядка: фон в сотни байт и пик в мегабайты. На
// линейной шкале масштаб задаёт единственный всплеск, и он держит потолок все
// 60 отсчётов истории - остальное рисуется в один пиксель. Логарифм по
// основанию 2 (целочисленный, x256) показывает и то, и другое.
function lg2(v) {
    v = int(v);
    if (v <= 1) return 0;
    let e = 0, x = v;
    while (x >= 2) { x = int(x / 2); e++; }
    return e * 256 + int(v * 256 / (1 << e)) - 256;
}

// Отсчёт ведём не от нуля, а от 1 КБ/с: иначе фоновые сотни байт на простое
// заполняли бы график почти доверху - логарифм у самого нуля растёт круто.
let LOG_FLOOR = 1024;

function log_frac(val, mx) {
    let base = lg2(LOG_FLOOR);
    let lm = lg2(mx) - base;
    if (lm <= 0) return 0;
    let f = (lg2(val) - base) * 1000 / lm;
    return f < 0 ? 0 : (f > 1000 ? 1000 : f);
}

function draw_graph(x, y, w, h, data, color, mn, mx, thresholds, fill) {
    let n = length(data);
    if (n < 2) return;
    if (mx <= mn) mx = mn + 1;
    let range = mx - mn;

    // Background
    lcd_rect(x, y, w, h, "#0841");

    // Threshold lines (dashed — draw every 4px)
    if (thresholds) {
        for (let t in thresholds) {
            let ty2 = y + h - int((t.val - mn) / range * h);
            if (ty2 > y && ty2 < y + h) {
                for (let dx = 0; dx < w; dx += 8)
                    lcd_rect(x + dx, ty2, 4, 1, t.color ?? C.gray);
                // Label on right
                lcd_text(x + w - 30, ty2 - 4, t.label ?? "", t.color ?? C.gray, "#0841", 1);
            }
        }
    }

    // Scale labels (left: max, bottom: min)
    lcd_text(x + 1, y + 1, sprintf("%d", mx), C.gray, "#0841", 1);
    lcd_text(x + 1, y + h - 9, sprintf("%d", mn), C.gray, "#0841", 1);

    // Plot line: connect points
    let pts = n > HIST_LEN ? HIST_LEN : n;
    let start = n - pts;
    let step_x = (w - 2) / (pts - 1);

    let prev_px = -1, prev_py = -1;
    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * step_x);
        let py = y + h - 1 - int((val - mn) / range * (h - 2));
        if (py < y) py = y;
        if (py >= y + h) py = y + h - 1;

        // Горизонтальная полка на ширину шага: раньше рисовались только
        // вертикальные перепады, и график выглядел набором полосок.
        let seg_w = int(step_x); if (seg_w < 1) seg_w = 1;
        if (fill)
            lcd_rect(px, py, seg_w, y + h - py, color);
        else
            lcd_rect(px, py, seg_w, 1, color);

        if (prev_px >= 0 && !fill) {
            let dy = py - prev_py;
            let steps = (dy > 0 ? dy : -dy);
            if (steps > 0) {
                let y_start = dy > 0 ? prev_py : py;
                lcd_rect(px, y_start, 1, steps, color);
            }
        }
        prev_px = px;
        prev_py = py;
    }

    // Current value — bright dot
    if (pts > 0) {
        let last_val = data[n - 1];
        let last_py = y + h - 1 - int((last_val - mn) / range * (h - 2));
        let last_px = x + w - 3;
        lcd_rect(last_px - 1, last_py - 1, 4, 4, C.white);
    }
}

function draw_graph_compact(x, y, w, h, data, color, mn, mx, fill) {
    lcd_rect(x, y, w, h, "#0B1220");
    let n = length(data);
    if (n < 2) return;
    if (mx <= mn) mx = mn + 1;
    let range = mx - mn;
    let pts = n > HIST_LEN ? HIST_LEN : n;
    let start = n - pts;
    let step_x = (w - 2) / (pts - 1);
    let prev_px = -1, prev_py = -1;

    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * step_x);
        let py = y + h - 1 - int((val - mn) / range * (h - 2));
        if (py < y) py = y;
        if (py >= y + h) py = y + h - 1;
        if (fill) {
            let fh = int(log_frac(val, mx) * (h - 2) / 1000);
            let seg_w0 = int(step_x); if (seg_w0 < 1) seg_w0 = 1;
            if (fh > 0) lcd_rect(px, y + h - fh, seg_w0, fh, color);
            prev_px = px;
            prev_py = y + h - fh;
            continue;
        }
        let seg_w = int(step_x); if (seg_w < 1) seg_w = 1;
        {
            lcd_rect(px, py, seg_w, 1, color);
            if (prev_px >= 0) {
                let dy = py - prev_py;
                let ys = dy > 0 ? prev_py : py;
                lcd_rect(px, ys, 1, dy > 0 ? dy : -dy, color);
            }
        }
        prev_px = px;
        prev_py = py;
    }
}

function arr_minmax(arr) {
    if (length(arr) == 0) return { min: 0, max: 1 };
    let mn = 999999, mx = -999999;
    for (let v in arr) {
        if (v < mn) mn = v;
        if (v > mx) mx = v;
    }
    return { min: mn, max: mx };
}


// =============================================
//  DATA COLLECTION
// =============================================

// Прочитанные ключи модема. Имя файла у 5gmodem собирается из usb-пути, где
// всё, кроме букв и цифр, заменено подчёркиванием: 1-1 -> sms_seen.1_1.
function sms_seen_set(path) {
    let set = {};
    let f = "/etc/5gmodem/sms_seen." + replace(path ?? "", /[^A-Za-z0-9]/g, "_");
    let raw = fs.readfile(f);
    if (raw)
        for (let k in split(trim(raw), "\n"))
            if (k != "") set[k] = true;
    return set;
}

function refresh_data() {
    // Primary: data_collector JSON
    let raw = fs.readfile(DATA_PATH);
    let d = raw ? json(raw) : {};

    // EC21: uqmi script JSON
    let uqmi_raw = fs.readfile("/tmp/lte_uqmi.json");
    if (uqmi_raw) {
        d.uqmi = json(uqmi_raw);
    } else if (d?.lte) {
        // Модем опрашивает 5gmodem, uqmi_status.sh не ставим: два опросчика
        // дерутся за AT-порт. Собираем d.uqmi из d.lte, чтобы страницы,
        // написанные под uqmi, работали без правок в каждом месте.
        d.uqmi = {
            rsrp:    d.lte.rsrp,
            rsrq:    d.lte.rsrq,
            sinr:    d.lte.sinr,
            rssi:    d.lte.rssi,
            band:    d.lte.band,
            mode:    d.lte.mode,
            pci:     d.lte.pci,
            enb_id:  d.lte.enbid,
            cell_id: d.lte.cid,
            mcc:     d.lte.mcc,
            mnc:     d.lte.mnc,
            ip:      d.lte.ip,
        };
    }

    let svc_raw = fs.readfile("/tmp/lcd_services.json");
    if (svc_raw) {
        try { d.services = json(svc_raw); } catch(e) { }
    }

    // Непрочитанные SMS: sessionwatch.sh в 5gmodem раз в круг атомарно
    // переписывает это зеркало (recv минус seen, мультипарт уже склеен).
    //
    // Но зеркало обновляется раз в круг, а отметка прочитанным ставится
    // мгновенно - и конвертик висел бы до минуты после того, как сообщение
    // прочитали на «Входящих» или его забрал Telegram. Поэтому seen вычитаем
    // сами, по тем же файлам: ровно это делает `smsbridge.sh newcount
    // for=<путь>`, но нам, локальной программе, дешевле прочитать их напрямую,
    // чем форкать скрипт на каждом тике.
    let sms_raw = fs.readfile("/tmp/5gmodem_sms_new.json");
    if (sms_raw) {
        try {
            let sj = json(sms_raw);
            let all = type(sj?.sms) == "array" ? sj.sms : [];
            let fresh = [], seen = {};
            for (let m in all) {
                let path = m?.modem ?? "";
                if (!exists(seen, path)) seen[path] = sms_seen_set(path);
                if (m?.key && seen[path][m.key]) continue;
                push(fresh, m);
            }
            d.sms_new = length(fresh);
            d.sms_list = fresh;
        } catch (e) { }
    }

    // Supplement: ubus system info (more accurate uptime/mem/load)
    if (uconn) {
        let si = uconn.call("system", "info", {});
        if (si) {
            if (si.uptime) d.uptime = si.uptime;
            let mem = si.memory;
            if (mem) d.mem_free_mb = int((mem.available ?? mem.free ?? 0) / 1048576);
            if (si.load) d.cpu_load_raw = si.load[0];
        }
        
        let wan_st = uconn.call("network.interface.wan", "status", {});
        if (wan_st && wan_st["ipv4-address"] && length(wan_st["ipv4-address"]) > 0) {
            d.wan_ip = wan_st["ipv4-address"][0].address;
        } else {
            d.wan_ip = null;
        }
    }

    // Weather: cached by weather_fetch.sh as a small pipe-delimited line
    // "condition|temp|feels|humidity|wind|city" — not fetched here directly,
    // and wrapped defensively so a malformed cache file can't crash the daemon.
    // The city name comes straight from the CITY variable in weather_fetch.sh
    // (not from the weather API), so that's the ONE place to change it.
    let weather_raw = fs.readfile("/tmp/lcd_weather.txt");
    if (weather_raw) {
        try {
            let parts = split(trim(weather_raw), "|");
            if (length(parts) >= 5) {
                d.weather = {
                    desc:     trim(parts[0]),
                    temp:     trim(parts[1]),
                    feels:    trim(parts[2]),
                    humidity: trim(parts[3]),
                    wind:     trim(parts[4]),
                    city:     length(parts) >= 6 ? trim(parts[5]) : null,
                };
            }
        } catch (e) {
            warn(sprintf("lcd_ui: weather parse failed: %s\n", e));
        }
    }

    st.data = d;
    update_history();
}


// =============================================
//  TOUCH INPUT
// =============================================

// Touch: read directly from /dev/lcd via ioctl 1
// Returns {x, y} on press, null if not pressed
// Uses tiny C helper or direct /dev/lcd read
let touch_fd = null;
let touch_was_pressed = false;
let touch_read_ok = null;

function read_touch() {
    // Method 1: read touch file if touch_poll is running (legacy)
    let raw = fs.readfile(TOUCH_PATH);
    if (raw) {
        fs.unlink(TOUCH_PATH);
        let m = match(trim(raw), /^(\d+)\s+(\d+)/);
        if (m) return { x: +m[1], y: +m[2] };
    }
    // Poll /dev/lcd via the C touch helper
    if (touch_read_ok == null)
        touch_read_ok = (fs.stat("/tmp/touch_read") != null);
    if (!touch_read_ok) return null;
    let p = fs.popen("/tmp/touch_read 2>/dev/null", "r");
    if (p) {
        let line = p.read("line");
        p.close();
        if (line) {
            let m = match(trim(line), /^(\d+)\s+(\d+)\s+(\d+)/);
            if (m && +m[3] > 0) {
                if (!touch_was_pressed) {
                    touch_was_pressed = true;
                    return { x: +m[1], y: +m[2] };
                }
            } else {
                touch_was_pressed = false;
            }
        }
    }
    return null;
}


// =============================================
//  HELPERS
// =============================================

function lte_quality(rsrp) {
    if (rsrp < 0 && rsrp > -90)  return { label: "Excellent", bars: 5, color: C.green };
    if (rsrp <= -90 && rsrp > -100) return { label: "Good",      bars: 4, color: C.green };
    if (rsrp <= -100 && rsrp > -110) return { label: "OK",        bars: 3, color: C.yellow };
    if (rsrp <= -110 && rsrp > -120) return { label: "Weak",      bars: 2, color: C.yellow };
    if (rsrp <= -120 && rsrp < 0)    return { label: "Bad",       bars: 1, color: C.red };
    return { label: "No signal", bars: 0, color: C.red };
}
// Уровень одним источником для шапки и страницы Modem: если 5gmodem отдал
// готовый процент, лесенка считается из него, иначе откат на RSRP.
// Подпись на кнопке «Модем»: раньше там было качество сигнала («ОК»), что
// ничего не говорило о состоянии. Дозвонился - показываем адрес, не дозвонился
// - на какой стадии застряли.
function modem_status(l) {
    let ip = l?.ip ?? "";
    if (ip != "" && ip != "-") return ip;
    let reg = int(+(l?.reg ?? 0));
    if (reg == 1 || reg == 5) return tr("no address");
    if ((l?.modem ?? "") == "" || (l?.modem ?? "") == "-") return tr("initialising...");
    return tr("no network");
}

function sig_state() {
    let l = st.data?.lte ?? {};
    let sigp = int(+(l.signal ?? 0));
    if (sigp > 0)
        return { bars: clampi((sigp + 19) / 20, 1, 5),
                 color: LVC[MET.signal.lv(sigp)], pct: sigp };
    let lq = lte_quality(int(+(l.rsrp ?? 0)));
    return { bars: lq.bars, color: lq.color, pct: 0 };
}


function get_plmn_name(mcc, mnc) {
    if (mcc == 250) {
        if (mnc == 1)  return "MTS";
        if (mnc == 2)  return "MegaFon";
        if (mnc == 11) return "Yota";
        if (mnc == 20) return "Tele2";
        if (mnc == 99) return "Beeline";
    }
    return null;
}

// Draw signal bars centered: n = bars (0-5), color, big = large bars
function draw_signal_bars(n, color, bg) {
    // Large centered bars: 5 bars, each 20px wide, 8px gap, centered on 320px screen
    // Total width: 5*20 + 4*8 = 132px, start x = (320-132)/2 = 94
    let base_x = 94, base_y = 190;  // bottom of bars area
    for (let i = 0; i < 5; i++) {
        let bh = 20 + i * 10;  // bar height: 20,30,40,50,60
        let bx = base_x + i * 28;
        let by = base_y - bh;
        let bc = (i < n) ? color : "#222222";
        lcd_rect(bx, by, 20, bh, bc);
    }
    // Label below bars
    let lq = lte_quality(0);  // dummy, caller should pass label
    lcd_text(base_x, base_y + 4, sprintf("%d/5", n), color, bg, 2);
}

function fmt_bytes(b) {
    b = +(b ?? 0);
    if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824);
    if (b >= 1048576) return sprintf("%.1fM", b / 1048576);
    if (b >= 1024) return sprintf("%.0fK", b / 1024);
    return sprintf("%d", b);
}

function fmt_uptime(s) {
    s = int(+(s ?? 0));
    let d = int(s / 86400);
    let h = int((s % 86400) / 3600);
    let m = int((s % 3600) / 60);
    if (lang() == "ru") {
        if (d > 0) return sprintf("%dд %dч %dм", d, h, m);
        if (h > 0) return sprintf("%dч %dм", h, m);
        return sprintf("%dм", m);
    }
    if (d > 0) return sprintf("%dd%dh%dm", d, h, m);
    if (h > 0) return sprintf("%dh%dm", h, m);
    return sprintf("%dm", m);
}

function clock_str() {
    let t = localtime();
    return t ? sprintf("%02d:%02d", t.hour, t.min) : "--:--";
}

let MONTHS_RU = [ "января", "февраля", "марта", "апреля", "мая", "июня",
                  "июля", "августа", "сентября", "октября", "ноября", "декабря" ];
let MONTHS_EN = [ "January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November", "December" ];

function date_str(short) {
    let t = localtime();
    if (!t) return "--";
    let M = lang() == "ru" ? MONTHS_RU : MONTHS_EN;
    let m = M[clampi(t.mon, 1, 12) - 1];
    // Короткая форма нужна там, где полная перевешивает часы по ширине.
    if (short) return sprintf("%d %s %d", t.mday, tcut(m, 3), t.year);
    return sprintf("%d %s, %d", t.mday, m, t.year);
}

// Было захардкожено: 10 секунд на дашборде и 30 на остальных страницах -
// экран гас, пока на него смотришь. Теперь одно значение из UCI.
let SAVER_STEPS = [ 30, 60, 120, 300, 600, 1200, 1800, 0 ];   // 0 = никогда

function saver_cfg() {
    let v = ucur ? ucur.get("lcd", "display", "saver") : null;
    v = (v == null || v == "") ? 300 : int(+v);
    if (v < 0) v = 300;
    return v;
}

function saver_set(v) {
    if (!ucur) return;
    ucur.set("lcd", "display", "saver", sprintf("%d", v));
    ucur.commit("lcd");
}

// Сдвиг против выгорания. Раз в 30 секунд на два пикселя было заметно, а
// применяется он не ко всему экрану, а только к тем блокам, что читают
// st.ox/st.oy - поэтому части картинки ползали относительно друг друга.
// Теперь раз в пять минут и на пиксель, и это можно выключить.
// Вид заставки: full - как раньше (часы, дата, погода), clock - только часы
// с уровнем и батареей, line - одна строка как в шапке.
let SAVER_STYLES = [ "full", "clock", "line", "off" ];

function saver_style() {
    let v = ucur ? ucur.get("lcd", "display", "saver_style") : null;
    for (let x in SAVER_STYLES) if (x == v) return v;
    return "full";
}

// Ночной режим: заставка светится тускло-зелёным, чтобы не бить по глазам в
// темноте. Достался от zipfo жёстко зашитым на 22:00-06:00; теперь это
// настройка - можно выключить или сдвинуть часы.
function night_cfg() {
    let on = ucur ? ucur.get("lcd", "display", "night") : null;
    let f  = ucur ? ucur.get("lcd", "display", "night_from") : null;
    let t  = ucur ? ucur.get("lcd", "display", "night_to") : null;
    return {
        on:   (on == null || on == "") ? true : (on == "1"),
        from: clampi(int(+(f ?? 22)), 0, 23),
        to:   clampi(int(+(t ?? 6)), 0, 23),
    };
}

function night_set(key, v) {
    if (!ucur) return;
    ucur.set("lcd", "display", key, sprintf("%s", v));
    ucur.commit("lcd");
}

// Интервал может переходить через полночь, поэтому две ветки: 22->6 это
// «после 22 ИЛИ до 6», а 1->7 - обычное «между».
function night_now() {
    let c = night_cfg();
    if (!c.on || c.from == c.to) return false;
    let t = localtime();
    if (!t) return false;
    return c.from < c.to ? (t.hour >= c.from && t.hour < c.to)
                         : (t.hour >= c.from || t.hour < c.to);
}

function saver_style_set(v) {
    if (!ucur) return;
    ucur.set("lcd", "display", "saver_style", v);
    ucur.commit("lcd");
}

function style_btn(i) {
    return { x: 100 + i * 54, y: 76, w: 50, h: 24 };
}

function burnin_cfg() {
    let v = ucur ? ucur.get("lcd", "display", "burnin") : null;
    return (v == null || v == "") ? true : (v == "1");
}

function burnin_set(on) {
    if (!ucur) return;
    ucur.set("lcd", "display", "burnin", on ? "1" : "0");
    ucur.commit("lcd");
    if (!on) { st.ox = 0; st.oy = 0; }
}

function saver_timeout() {
    let v = saver_cfg();
    return v > 0 ? v : 999999999;
}

function saver_label(v) {
    if (v == 0) return "Never";
    if (v < 60) return sprintf(tr("%d sec"), v);
    return sprintf(tr("%d min"), int(v / 60));
}

// Страница «Экран» верстается в одну колонку по центру: значение таймаута
// занимает треть ширины, минус и плюс стоят по бокам от него.
function saver_btn(which) {
    return which < 0 ? { x: 60, y: 42, w: 56, h: 30 }
                     : { x: 204, y: 42, w: 56, h: 30 };
}

function saver_val_box() {
    return { x: 124, y: 42, w: 72, h: 30 };
}

// Ряд состояний: гашение, сдвиг, ночь, язык - по четверти ширины каждая.
function quad_btn(i) {
    return { x: 10 + i * 76, y: 112, w: 72, h: 26 };
}

// Часы «с» и «до»: две группы «минус - значение - плюс» в одной строке.
function hour_btn(row, which) {
    let base = row == 0 ? 14 : 166;
    if (which < 0) return { x: base, y: 158, w: 40, h: 30 };
    if (which > 0) return { x: base + 104, y: 158, w: 40, h: 30 };
    return { x: base + 44, y: 158, w: 56, h: 30 };
}


function btn_pos(idx) {
    let col = (idx - 1) % COLS;
    let row = int((idx - 1) / COLS);
    return {
        x: BTN_PAD + col * (BTN_W + BTN_PAD),
        y: START_Y + row * (BTN_H + BTN_PAD),
        w: BTN_W,
        h: BTN_H,
    };
}

function in_rect(tx, ty, bx, by, bw, bh) {
    return tx >= bx && tx <= bx + bw && ty >= by && ty <= by + bh;
}

function wifi_is_disabled(radio_section, default_section) {
    let radio_dis = ucur ? ucur.get("wireless", radio_section, "disabled") : null;
    let default_dis = ucur ? ucur.get("wireless", default_section, "disabled") : null;
    return radio_dis == "1" || default_dis == "1";
}


// =============================================
//  DRAWING: COMMON
// =============================================

// Конвертик непрочитанного SMS. Рисуем сеткой, как погодные иконки:
// '#' - рамка и линия сгиба, 'o' - бумага. Сетка 22x16 при клетке 1 -
// ровно та же высота, что у батареи и лесенки сигнала в шапке, а сгиб
// получается сплошной линией, а не лесенкой из квадратов.
let ENV_GRID = [
    "######################",
    "##oooooooooooooooooo##",
    "###oooooooooooooooo###",
    "#o##oooooooooooooo##o#",
    "#oo##oooooooooooo##oo#",
    "#ooo##oooooooooo##ooo#",
    "#oooo###oooooo###oooo#",
    "#oooooo##oooo##oooooo#",
    "#ooooooo##oo##ooooooo#",
    "#oooooooo####oooooooo#",
    "#oooooooooooooooooooo#",
    "#oooooooooooooooooooo#",
    "#oooooooooooooooooooo#",
    "#oooooooooooooooooooo#",
    "#oooooooooooooooooooo#",
    "######################",
];

let ENV_W = 22, ENV_H = 16;

function draw_env_icon(x, y, cell, paper, line) {
    cell ??= 1;
    paper ??= "#F2F2F2";
    line ??= C.gray;
    for (let r = 0; r < length(ENV_GRID); r++) {
        let row = ENV_GRID[r];
        for (let c = 0; c < length(row); c++) {
            let ch = substr(row, c, 1);
            if (ch == ".") continue;
            lcd_rect(x + c * cell, y + r * cell, cell, cell,
                     ch == "#" ? line : paper);
        }
    }
}

function draw_header(title, bg_c) {
    bg_c ??= C.hdr;
    lcd_rect(0, 0, LCD_W, HDR_H, bg_c);
    lcd_rect(0, HDR_H, LCD_W, 1, C.border); // header bottom line

    let d = st.data;
    let u = d?.uqmi;
    let sig = sig_state();

    // Слева направо: часы, уровень, оператор. Батарея прижата к правому краю.
    let x = 4;

    let tstr = clock_str();
    lcd_text(x, 4, tstr, C.cyan, bg_c, 2);
    x += tlen(tstr) * 12 + 10;

    draw_sigbars(x, 3, sig.bars, sig.color);
    x += 5 * 8 + 8;

    let env = int(d?.sms_new ?? 0) > 0;
    if (env) {
        draw_env_icon(x, 3, 1, null, null);
        x += ENV_W + 8;
    }

    // Имя оператора читается с одного взгляда, цифры PLMN - нет. Держим их
    // запасным вариантом: у части сетей имя не приходит, тогда лучше код,
    // чем пустое место.
    let mcc = int(+(u?.mcc ?? 0));
    let mnc = int(+(u?.mnc ?? 0));
    let plmn_str = d?.lte?.operator ?? "";
    if (plmn_str == "" || plmn_str == "-")
        plmn_str = mcc > 0 ? sprintf("%03d%02d", mcc, mnc) : "N/A";

    // Справа стоят батарея (32) с зазором, её процент (до 3 знаков) и отступы.
    let bat = d?.battery;
    let bchg = bat?.charging && !bat?.no_battery;
    let bpct = int(+(bat?.percent ?? 0));
    let bstr = bat?.no_battery ? "--" : sprintf("%d", bpct);
    let btxt_w = tlen(bstr) * 12;
    let b_w = 32, b_h = 16, b_y = 3;
    let bat_x = LCD_W - 4 - btxt_w - 6 - b_w - 2;

    // Сколько знаков оператора влезает до батареи, столько и показываем.
    // С конвертиком имя убираем совсем: обрезок вроде «T-Mobi» читается хуже,
    // чем пустое место, а конвертик тут важнее.
    if (!env) {
        let room = int((bat_x - 6 - x) / 12);
        if (room < 1) room = 1;
        lcd_text(x, 4, tcut(plmn_str, room), C.white, bg_c, 2);
    }

    draw_batt_icon(bat_x, b_y, b_w, b_h, bg_c, bpct, bat?.no_battery, null, bchg);
    lcd_text(bat_x + b_w + 6, 4, bstr, C.white, bg_c, 2);
}

function draw_back() {
    lcd_rect(0, BACK_Y, LCD_W, 32, C.back);
    lcd_rect(0, BACK_Y, LCD_W, 2, "#D32F2F"); // top highlight
    lcd_text(120, BACK_Y + 9, tr("< BACK"), C.white, C.back, 2);
}

function draw_btn(idx, title, subtitle, title_c, sub_c, bg_c) {
    let b = btn_pos(idx);
    let bg = bg_c ?? C.btn;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    lcd_rect(b.x, b.y + b.h - 3, b.w, 3, C.border); // internal shadow element
    lcd_text(b.x + 8, b.y + 8, title, title_c ?? C.white, bg, 2);
    if (subtitle)
        lcd_text(b.x + 8, b.y + 38, subtitle, sub_c ?? C.gray, bg, 1);
}


// =============================================
//  WEATHER ICONS (pixel-art, 24x24, drawn from rects)
//
// Each icon is a 24x24 grid of chars. "." = empty; any other char is
// looked up in that icon's `colors` map to give shaded, two/three-tone
// pictograms (e.g. lit cloud top vs. shadowed underside) instead of a
// single flat-color blob. color_override (night mode) collapses
// everything to one tone.
// =============================================

let WICONS = {
    sun: {
        grid: [
            "............B...........",
            "........................",
            "............B...........",
            "........................",
            "....B..............B....",
            ".....B...AAAAA....B.....",
            ".......AAAAAAAAA........",
            "......AAAAAAAAAAA.......",
            "......AAAAAAAAAAA.......",
            ".....AAAAAAAAAAAAA......",
            ".....AAAAAAAAAAAAA......",
            "B.B..AAAAAAAAAAAAA......",
            "B.B..AAAAAAAAAAAAA..B.B.",
            ".....AAAAAAAAAAAAA......",
            "......AAAAAAAAAAA.......",
            "......AAAAAAAAAAA.......",
            ".......AAAAAAAAA........",
            ".........AAAAA..........",
            ".....B............B.....",
            "....B..............B....",
            "...........BB...........",
            "........................",
            "...........BB...........",
            "........................",
        ],
        colors: { A: C.sun_core, B: C.sun_ray },
    },
    partly: {
        grid: [
            "........D...............",
            "........................",
            "........D...............",
            "...D.CCCCCC..D..........",
            "....CCCCCCCC............",
            "...CCCCCCCCCC...........",
            "...CCCCCCCCCC...........",
            "...CCCCCCCBBBB..........",
            "D.DCCCBBBBBBBBBBB.......",
            "...CCBBBBBBBBBBBBBB.....",
            "...CCBBBBBBBBBBBBBBB....",
            "....CBBBBBBBBBBBBBBB....",
            ".....AAAAAAAAAAAAAAA....",
            "...D..AAAAAAAAAAAAAA....",
            "........AAAAAAA.AAA.....",
            "........BBBBBB..........",
            "........D.BBB...........",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, C: C.sun_core, D: C.sun_ray },
    },
    cloud: {
        grid: [
            "........................",
            "........................",
            "........................",
            "..........BBBB..........",
            "........BBBBBBBB........",
            ".......BBBBBBBBBB.......",
            "......BBBBBBBBBBBB..BB..",
            ".....BBBBBBBBBBBBBBBBBB.",
            "...BBBBBBBBBBBBBBBBBBBBB",
            "..BBBBBBBBBBBBBBBBBBBBBB",
            "..BBBBBBBBBBBBBBBBBBBBBB",
            "..BBBBBBBBBBBBBBBBBBBBBB",
            "..AAAAAAAAAAAAAAAAAAAAAA",
            "...AAAAAAAAAAAAAAAAAAAA.",
            ".....AAAAAAAAAAAAAAAA...",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................"
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit },
    },
    rain: {
        grid: [
            "........................",
            "..........B.............",
            "........BBBBBBB.........",
            ".....BBBBBBBBBBBB.......",
            "....BBBBBBBBBBBBBBB.....",
            "....BBBBBBBBBBBBBBBB....",
            "....BBBBBBBBBBBBBBBB....",
            "....AAAAAAAAAAAAAAAA....",
            ".....AAAAAAAAAAAAAAA....",
            ".......AAAAAAAAAAAA.....",
            ".......BBBBBBB..........",
            "........BBBBB...........",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "....C.......C...........",
            "....C.......C...........",
            "........C.......C.......",
            "........C.......C.......",
            "......C.......C.........",
            "......C.......C.........",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, C: C.cyan },
    },
    snow: {
        grid: [
            "........................",
            "..........B.............",
            "........BBBBBBB.........",
            ".....BBBBBBBBBBBB.......",
            "....BBBBBBBBBBBBBBB.....",
            "....BBBBBBBBBBBBBBBB....",
            "....BBBBBBBBBBBBBBBB....",
            "....AAAAAAAAAAAAAAAA....",
            ".....AAAAAAAAAAAAAAA....",
            ".......AAAAAAAAAAAA.....",
            ".......BBBBBBB..........",
            "........BBBBB...........",
            "........................",
            "........................",
            "........................",
            "........................",
            "....C.........C.........",
            "...CCC.......CCC........",
            "....C....C....C....C....",
            "........CCC.......CCC...",
            "......C..C.C....C..C....",
            ".....CCC..CCC..CCC......",
            "......C....C....C.......",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, C: C.white },
    },
    fog: {
        grid: [
            "........................",
            "........................",
            "........................",
            "........................",
            "..BBBBBBBBBBBBBBBBBBBB..",
            "........................",
            "........................",
            "........................",
            "........................",
            "..AAAAAAAAAAAAAAAAAAAA..",
            "........................",
            "........................",
            "........................",
            "........................",
            "..BBBBBBBBBBBBBBBBBBBB..",
            "........................",
            "........................",
            "........................",
            "........................",
            "..AAAAAAAAAAAAAAAAAAAA..",
            "........................",
            "........................",
            "........................",
            "........................",
        ],
        colors: { A: C.dim, B: C.gray },
    },
    storm: {
        grid: [
            "......BBBBBBBBBBB.......",
            "....BBBBBBBBBBBBBB......",
            "....BBBBBBBBBBBBBBBB....",
            "...BBBBBBBBBBBBBBBBBB...",
            "...BBBBBBBBBBBBBBBBBB...",
            "....AAAAAAAAAAAAAAAAA...",
            "....AAAAAAAAAAAAAAAAA...",
            "......AAAAAAAAAAAAAA....",
            ".......BBBBBBBB.........",
            "........BBBBBB..........",
            ".........BBBB...........",
            "........................",
            "........................",
            "............C...........",
            "...........C.C..........",
            "........................",
            "..........C.C...........",
            "........................",
            ".........C.C............",
            "........................",
            "........C.C.............",
            "........................",
            ".........C..............",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, C: C.bolt },
    },
};

// Picks an icon key by matching keywords in the condition text
// (e.g. "Patchy rain possible", "Thundery outbreaks possible").
function weather_icon_key(desc) {
    let s = desc ?? "";
    if (match(s, /thunder/i))                    return "storm";
    if (match(s, /snow|sleet|blizzard|ice pellet/i)) return "snow";
    if (match(s, /rain|drizzle|shower/i))         return "rain";
    if (match(s, /fog|mist/i))                    return "fog";
    if (match(s, /cloud|overcast/i))
        return match(s, /partly/i) ? "partly" : "cloud";
    if (match(s, /sun|clear/i))                   return "sun";
    return "cloud";
}

// Dominant tone per icon — used only as a fallback and for the toast/
// splash colorization elsewhere in the file.
function weather_icon_color(key) {
    switch (key) {
    case "sun":    return C.sun_core;
    case "partly": return C.sun_core;
    case "rain":   return C.cyan;
    case "snow":   return C.white;
    case "storm":  return C.bolt;
    default:       return C.gray; // cloud, fog
    }
}

// Draws an icon grid using filled squares (cell px per grid cell).
// Each non-"." char is colored per that icon's `colors` map, giving
// shaded, multi-tone pictograms. color_override lets callers force a
// single flat tone (e.g. night-mode screensaver, low-color contexts).
function draw_weather_icon(x, y, desc, cell, color_override) {
    cell ??= 3; // grid is 24x24, so cell=3 keeps the old default footprint (~72px)
    let key = weather_icon_key(desc);
    let icon = WICONS[key];
    let grid = icon.grid;
    let cmap = icon.colors;
    for (let r = 0; r < length(grid); r++) {
        let row = grid[r];
        for (let c = 0; c < length(row); c++) {
            let ch = substr(row, c, 1);
            if (ch == ".") continue;
            let color = color_override ?? cmap[ch] ?? weather_icon_color(key);
            lcd_rect(x + c * cell, y + r * cell, cell, cell, color);
        }
    }
}


// =============================================
//  DRAWING: DASHBOARD
// =============================================

function draw_dashboard() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header();

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;
    
    // --- 1. WWAN ---
    let y1 = 28 + oy;
    lcd_rect(cx, y1, cw, 54, C.widget);
    lcd_rect(cx, y1, 4, 54, "#D2A8FF"); // Magenta accent
    lcd_text(cx + 16, y1 + 10, "WWAN IP (LTE)", C.gray, C.widget, 1);
    let wwan_ip = d?.lte?.ip ?? d?.uqmi?.ip ?? tr("Disconnected");
    lcd_text(cx + 16, y1 + 26, wwan_ip, (wwan_ip == tr("Disconnected") || wwan_ip == "") ? C.dim : C.white, C.widget, 2);

    // --- 2. WAN ---
    let y2 = y1 + 58;
    lcd_rect(cx, y2, cw, 54, C.widget);
    lcd_rect(cx, y2, 4, 54, C.cyan); // Blue accent
    lcd_text(cx + 16, y2 + 10, "WAN IP (ETH)", C.gray, C.widget, 1);
    // У кабеля своя формулировка: «нет связи» - это про радио, а тут просто
    // не воткнут провод.
    let wan_ip = d?.wan_ip ?? tr("Not connected");
    lcd_text(cx + 16, y2 + 26, wan_ip, (wan_ip == tr("Not connected") || wan_ip == "") ? C.dim : C.white, C.widget, 2);

    // --- 3. WIFI ---
    let y3 = y2 + 58;
    lcd_rect(cx, y3, cw, 54, C.widget);
    lcd_rect(cx, y3, 4, 54, C.green); // Green accent
    lcd_text(cx + 16, y3 + 10, tr("WI-FI STATUS"), C.gray, C.widget, 1);
    
    let w_clients = d?.wifi?.clients;
    let nc = type(w_clients) == "array" ? length(w_clients) : 0;
    let wifi_str = nc > 0
        ? (lang() == "ru" ? sprintf("Подключено: %d", nc)
                          : sprintf("%d Connected Client%s", nc, nc == 1 ? "" : "s"))
        : tr("No Clients");
    lcd_text(cx + 16, y3 + 26, wifi_str, nc > 0 ? C.white : C.dim, C.widget, 2);
    
    draw_back();
    lcd_flush();
}


// =============================================
//  DRAWING: MAIN MENU
// =============================================

// =============================================
//  SMS
// =============================================
//
// Читаем ящик тем же мостом, что и веб-морда 5gmodem: `smsbridge.sh recv`.
// Он ходит в модем по AT (~1 с), поэтому зовём его в фоне и только когда
// пользователь открыл страницу, а не по таймеру: AT-порт общий, дёргать его
// впустую нельзя. Непрочитанные приходят отдельным зеркалом (sms_new.json) -
// оттуда берём только пометку «новое».

let SMS_CACHE = "/tmp/lcd_sms.json";
let SMS_ROWS  = 4;
let SMS_COLS  = 46;   // (300 - 20) / 6 - знаков в строке текста
let SMS_LINES = 12;   // строк текста на экран

// Приводим текст к тому, что умеет рисовать шрифт 5x7: юникодной пунктуации
// (стрелки, ёлочки, длинные тире, неразрывные пробелы) в нём нет.
//
// Первые проходы - про битую кодировку моста: sms_tool -j экранировал мусор как
// \u00ffffffHH, и utf8_fix, искавший байтовый маркер, его не видел. В 5gmodem это
// починено (третий проход в utf8_fix), и на свежем мосте проходы вхолостую. Но
// пакет ставится и на роутеры со старым 5gmodem, поэтому оставляем их запасом.
function sms_clean(t) {
    if (!t) return "";
    t = replace(t, /\xff\xff+/g, "");
    t = replace(t, /ÿffffa0/g, " ");
    t = replace(t, /ÿffffab/g, "«");
    t = replace(t, /ÿffffbb/g, "»");
    t = replace(t, /ÿffff[0-9a-f][0-9a-f]/g, "");
    // Ёлочки, тире, стрелки и прочее теперь есть в шрифте - не трогаем.
    // Неразрывный пробел заменяем обязательно: он не только не рисуется, но и
    // не разделяет слова при переносе - строка резалась бы посреди слова.
    t = replace(t, /\u00a0/g, " ");
    t = replace(t, /\u202f/g, " ");
    return t;
}

function sms_refresh() {
    if (st.sms_wait) return;
    st.sms_wait = true;
    // Перенаправление вешаем на подоболочку целиком, иначе фоновый процесс
    // держит наши дескрипторы и ucode ждёт его завершения.
    system("(/usr/share/5gmodem/smsbridge.sh recv > " + SMS_CACHE + ".new 2>/dev/null" +
           " && mv " + SMS_CACHE + ".new " + SMS_CACHE + ") >/dev/null 2>&1 &");
}

// Отправитель: цифровой номер приводим к виду +7 (962) 699-90-32 - так же, как
// на «Входящих» в 5gmodem. Буквенные имена вроде «T-Mob» phone_fmt вернёт как
// есть, поэтому проверять тип отправителя отдельно не нужно.
function sms_from(raw) {
    let f = phone_short(raw);
    return f != "" ? f : (raw ?? "?");
}

// В карточке отметка времени делит ширину с отправителем, а формат номера
// съедает 18 знаков. Поэтому у сегодняшних показываем время, у остальных -
// дату: и то, и другое укладывается в пять знаков.
function sms_short_time(t) {
    t = t ?? "";
    let p = split(trim(t), " ");
    if (length(p) < 2) return t;
    let d = split(p[0], "-");
    if (length(d) < 3) return t;
    let now = localtime();
    if (now && int(+d[0]) == now.year && int(+d[1]) == now.mon &&
        int(+d[2]) == now.mday)
        return substr(p[1], 0, 5);
    return sprintf("%s.%s", d[2], d[1]);
}

function sms_unread() {
    let u = {};
    let l = st.data?.sms_list;
    if (type(l) == "array")
        for (let m in l) if (m?.key) u[m.key] = true;
    return u;
}

// Части мультипарта приходят отдельными записями с общим отправителем и
// временем - склеиваем их по этому ключу, как это делает newdump.
function sms_parse(raw) {
    let j;
    try { j = json(raw); } catch (e) { return []; }
    let msgs = j?.msg;
    if (type(msgs) != "array") return [];

    let by = {}, order = [];
    for (let m in msgs) {
        let k = (m?.sender ?? "?") + "|" + (m?.timestamp ?? "");
        if (!exists(by, k)) {
            by[k] = { sender: m?.sender ?? "?", time: m?.timestamp ?? "",
                      key: k, parts: [] };
            push(order, k);
        }
        push(by[k].parts, m);
    }

    let out = [];
    for (let k in order) {
        let e = by[k];
        sort(e.parts, function(x, y) {
            return int(+(x?.part ?? x?.index ?? 0)) - int(+(y?.part ?? y?.index ?? 0));
        });
        let txt = "";
        for (let p in e.parts) txt += (p?.content ?? "");
        push(out, { sender: e.sender, time: e.time, key: e.key,
                    text: sms_clean(txt) });
    }
    // Свежие сверху: модем отдаёт ящик от старых к новым.
    let rev = [];
    for (let i = length(out) - 1; i >= 0; i--) push(rev, out[i]);
    return rev;
}

function sms_list() {
    let st_ = fs.stat(SMS_CACHE);
    if (!st_) return st.sms;
    if (st.sms == null || st_.mtime != st.sms_ts) {
        let raw = fs.readfile(SMS_CACHE);
        if (raw) {
            st.sms = sms_parse(raw);
            st.sms_ts = st_.mtime;
            st.sms_wait = false;
        }
    }
    return st.sms;
}

// Перенос по словам с оглядкой на UTF-8: length() считает байты, поэтому
// длину меряем tlen(), а режем tcut().
function sms_wrap(txt, cols) {
    let out = [];
    for (let para in split(txt, "\n")) {
        let line = "";
        for (let w in split(para, " ")) {
            while (tlen(w) > cols) {
                if (line != "") { push(out, line); line = ""; }
                push(out, tcut(w, cols));
                w = substr(w, length(tcut(w, cols)));
            }
            if (line == "") line = w;
            else if (tlen(line) + 1 + tlen(w) <= cols) line += " " + w;
            else { push(out, line); line = w; }
        }
        push(out, line);
    }
    return out;
}

// Полоса «назад» со стрелками страниц. Стрелки рисуем только когда есть куда
// листать, иначе на них жмут вслепую.
function draw_back_pager(pg, pages) {
    lcd_rect(0, BACK_Y, LCD_W, 32, C.back);
    lcd_text(120, BACK_Y + 9, "< " + tr("BACK"), C.white, C.back, 2);
    if (pages > 1) {
        lcd_text(16, BACK_Y + 9, "<<", pg > 0 ? C.white : "#8B3A3A", C.back, 2);
        lcd_text(LCD_W - 40, BACK_Y + 9, ">>",
                 pg < pages - 1 ? C.white : "#8B3A3A", C.back, 2);
        // Счётчик прижимаем к левой стрелке: по центру он налезал на «НАЗАД».
        lcd_text(48, BACK_Y + 13, sprintf("%d/%d", pg + 1, pages),
                 C.white, C.back, 1);
    }
}

function pager_hit(tx, ty, pg, pages) {
    if (ty < BACK_Y - 4) return 0;
    if (pages > 1 && tx < 70) return pg > 0 ? -1 : 0;
    if (pages > 1 && tx > LCD_W - 70) return pg < pages - 1 ? 1 : 0;
    return 2;   // «назад»
}

function draw_sms_page() {
    lcd_clear(C.bg);
    draw_header(tr("SMS"));

    let list = sms_list();
    if (list == null) {
        lcd_text(20, 100, tr("Reading inbox..."), C.gray, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }
    if (length(list) == 0) {
        lcd_text(20, 100, tr("No messages"), C.dim, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }

    let unread = sms_unread();
    let pages = int((length(list) + SMS_ROWS - 1) / SMS_ROWS);
    if (st.sms_pg >= pages) st.sms_pg = pages - 1;

    for (let r = 0; r < SMS_ROWS; r++) {
        let idx = st.sms_pg * SMS_ROWS + r;
        if (idx >= length(list)) break;
        let m = list[idx];
        let y = 32 + r * 44;
        let neu = exists(unread, m.key);
        lcd_rect(10, y, 300, 40, C.widget);
        lcd_rect(10, y, 4, 40, neu ? C.green : C.dim);
        let from = sms_from(m.sender), when = sms_short_time(m.time);
        lcd_text(20, y + 5, tcut(from, 18), neu ? C.white : C.gray, C.widget, 2);
        lcd_text(310 - tlen(when) * 6 - 8, y + 8, when, C.dim, C.widget, 1);
        lcd_text(20, y + 25, tcut(replace(m.text, /\n/g, " "), 47),
                 neu ? C.white : C.gray, C.widget, 1);
    }

    draw_back_pager(st.sms_pg, pages);
    lcd_flush();
}

function draw_sms_one() {
    lcd_clear(C.bg);
    draw_header(tr("SMS"));

    let list = sms_list();
    let m = (type(list) == "array" && st.sms_i >= 0 && st.sms_i < length(list))
            ? list[st.sms_i] : null;
    if (!m) { st.page = "sms"; draw_sms_page(); return; }

    lcd_rect(10, 28, 300, 22, C.widget);
    lcd_text(20, 34, tcut(sms_from(m.sender), 24), C.white, C.widget, 1);
    lcd_text(310 - tlen(m.time) * 6 - 8, 34, m.time, C.dim, C.widget, 1);

    let lines = sms_wrap(m.text, SMS_COLS);
    let pages = int((length(lines) + SMS_LINES - 1) / SMS_LINES);
    if (pages < 1) pages = 1;
    if (st.sms_tp >= pages) st.sms_tp = pages - 1;

    for (let i = 0; i < SMS_LINES; i++) {
        let li = st.sms_tp * SMS_LINES + i;
        if (li >= length(lines)) break;
        lcd_text(16, 58 + i * 12, lines[li], C.white, C.bg, 1);
    }

    draw_back_pager(st.sms_tp, pages);
    lcd_flush();
}

function draw_menu() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header();

    if (st.mpg == 1) {
        // 1: Сеть
        draw_btn(1, tr("Network"), tr("IP & clients"), C.white, C.gray);

        // 2: WiFi
        let nc = type(d?.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
        draw_btn(2, tr("WiFi"),
            sprintf(tr("%d clients"), nc),
            C.white, C.gray);

        // 3: Modem
        draw_btn(3, tr("Modem"),
            modem_status(d?.lte),
            C.white, C.gray);

        // 4: Traffic
        let rx_last = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
        let tx_last = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
        draw_btn(4, tr("Traffic"),
            sprintf("R:%s T:%s", fmt_bytes(rx_last), fmt_bytes(tx_last)),
            C.white, C.gray);

        // 5: Info
        draw_btn(5, tr("Info"),
            fmt_uptime(d?.uptime),
            C.white, C.gray);

        // 6: MORE
        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, tr("MORE >>>"), C.white, C.hdr, 2);

    } else if (st.mpg == 2) {
        let ns = int(d?.sms_new ?? 0);
        draw_btn(1, tr("SMS"),
            ns > 0 ? sprintf(tr("%d new"), ns) : tr("inbox"),
            C.white, ns > 0 ? C.green : C.gray);
        draw_btn(2, tr("Services"), tr("check"), C.white, C.gray);
        draw_btn(3, tr("Weather"), tr("Update now"), C.white, C.gray);
        draw_btn(4, tr("Display"), saver_label(saver_cfg()), C.white, C.gray);
        draw_btn(5, tr("Modem Reset"), tr("LTE restart"), C.white, C.gray);

        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, tr("MORE >>>"), C.white, C.hdr, 2);

    } else {
        draw_btn(1, tr("Reboot"), tr("System"), C.white, C.gray);

        // 6: <<< BACK. Ровно одна ячейка: растянутая на две выглядела единой
        // кнопкой, а тач считал половины разными - нажатие слева уходило мимо.
        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, tr("<<< BACK"), C.white, C.hdr, 2);
    }

    lcd_flush();
}


// =============================================
//  DRAWING: SUB-PAGES
// =============================================

// ---- QR для подключения к Wi-Fi ----
//
// Матрицу считает qrencode: свой кодировщик писать незачем, а `-t ASCII`
// отдаёт готовую сетку - два символа на модуль. Результат кешируем: каждый
// вызов это запуск процесса, а страница перерисовывается каждые две секунды.

let qr_cache = {};

function sh_quote(v) {
    return "'" + replace(v ?? "", "'", "'\\''") + "'";
}

function qr_esc(v) {
    v = replace(v ?? "", "\\", "\\\\");
    v = replace(v, ";", "\\;");
    v = replace(v, ",", "\\,");
    v = replace(v, ":", "\\:");
    return replace(v, '"', '\\"');
}

function wifi_qr_rows(ssid, key) {
    if (!ssid || ssid == "" || ssid == "N/A") return null;
    let ck = ssid + "\x00" + (key ?? "");
    if (exists(qr_cache, ck)) return qr_cache[ck];

    let nopass = (key == null || key == "" || key == "N/A");
    let payload = sprintf("WIFI:T:%s;S:%s;P:%s;;",
        nopass ? "nopass" : "WPA", qr_esc(ssid), nopass ? "" : qr_esc(key));

    let rows = null;
    let p = fs.popen("qrencode -t ASCII -m 0 -l L -o - " + sh_quote(payload) + " 2>/dev/null", "r");
    if (p) {
        let out = p.read("all");
        p.close();
        if (out) {
            rows = [];
            for (let ln in split(trim(out), "\n"))
                if (length(ln) > 3) push(rows, ln);
            if (!length(rows)) rows = null;
        }
    }
    qr_cache[ck] = rows;
    return rows;
}

// Соседние модули склеиваем в один прямоугольник: команд рисования выходит
// в разы меньше, а кадр по GPIO и так стоит 75 мс.
function draw_qr(rows, x, y, scale, fg, bg) {
    if (!rows) return;
    let n = length(rows);
    lcd_rect(x - scale, y - scale, n * scale + scale * 2, n * scale + scale * 2, bg);
    for (let r = 0; r < n; r++) {
        let line = rows[r], c = 0;
        while (c < n) {
            if (substr(line, c * 2, 1) == "#") {
                let run = 1;
                while (c + run < n && substr(line, (c + run) * 2, 1) == "#") run++;
                lcd_rect(x + c * scale, y + r * scale, run * scale, scale, fg);
                c += run;
            } else {
                c++;
            }
        }
    }
}

function qr_box(y) {
    return { x: 10 + 300 - 68, y: y + 9, w: 62, h: 62 };
}

function draw_display_page() {
    lcd_clear(C.bg);
    draw_header(tr("Display"));

    // Таймаут: подпись по центру, значение в рамке, минус и плюс по бокам.
    let cur = saver_cfg();
    let lab = tr("SCREENSAVER AFTER");
    lcd_text(int((LCD_W - tlen(lab) * 6) / 2), 30, lab, C.gray, C.bg, 1);

    let a = saver_btn(-1), z = saver_btn(1), v = saver_val_box();
    lcd_rect(a.x, a.y, a.w, a.h, C.widget);
    lcd_text(a.x + 22, a.y + 3, "-", C.accent, C.widget, 3);
    lcd_rect(v.x, v.y, v.w, v.h, C.widget);
    let vs = saver_label(cur);
    lcd_text(v.x + int((v.w - tlen(vs) * 6) / 2), v.y + 11, vs, C.white, C.widget, 1);
    lcd_rect(z.x, z.y, z.w, z.h, C.widget);
    lcd_text(z.x + 22, z.y + 3, "+", C.accent, C.widget, 3);

    // Вид заставки
    let stl = saver_style();
    lcd_text(20, 82, tr("VIEW"), C.gray, C.bg, 1);
    for (let i = 0; i < length(SAVER_STYLES); i++) {
        let b = style_btn(i), sel = (SAVER_STYLES[i] == stl);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        let t = tr(SAVER_STYLES[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 8, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    // Ряд переключателей: гашение, сдвиг, ночь, язык.
    let bon = burnin_cfg(), non = night_cfg().on, ru = (lang() == "ru");
    let quads = [
        [ tr("Blank now"), C.dim,                  C.white ],
        [ tr("Shift") + " " + (bon ? tr("on") : tr("off")), bon ? C.green : C.dim, bon ? C.white : C.gray ],
        [ tr("Night") + " " + (non ? tr("on") : tr("off")), non ? C.green : C.dim, non ? C.white : C.gray ],
        [ ru ? "Ру / En" : "Ru / En",              C.cyan,                    C.white ],
    ];
    for (let i = 0; i < 4; i++) {
        let b = quad_btn(i), q = quads[i];
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, q[1]);
        lcd_text(b.x + int((b.w - tlen(q[0]) * 6) / 2) + 2, b.y + 9, q[0], q[2], C.widget, 1);
    }

    // Часы ночного режима.
    let c = night_cfg();
    let hcol = c.on ? C.white : C.dim;
    lcd_text(14, 146, tr("NIGHT FROM"), C.gray, C.bg, 1);
    lcd_text(166, 146, tr("NIGHT TO"), C.gray, C.bg, 1);
    for (let r = 0; r < 2; r++) {
        let m = hour_btn(r, -1), vb = hour_btn(r, 0), pl = hour_btn(r, 1);
        let hv = sprintf("%02d", r == 0 ? c.from : c.to);
        lcd_rect(m.x, m.y, m.w, m.h, C.widget);
        lcd_text(m.x + 14, m.y + 3, "-", C.accent, C.widget, 3);
        lcd_rect(vb.x, vb.y, vb.w, vb.h, C.widget);
        lcd_text(vb.x + int((vb.w - tlen(hv) * 12) / 2), vb.y + 8, hv, hcol, C.widget, 2);
        lcd_rect(pl.x, pl.y, pl.w, pl.h, C.widget);
        lcd_text(pl.x + 14, pl.y + 3, "+", C.accent, C.widget, 3);
    }

    draw_back();
    lcd_flush();
}

// Информация о соте - то же наполнение, что на одноимённой странице 5gmodem.
// Полей много, поэтому три листа со стрелками, как в выборе города.
let CELL_PAGES = 4;

function cell_arrow(dir) {
    return { x: dir < 0 ? 8 : 164, y: 176, w: 148, h: 26 };
}

function kv(x, y, k, v, vc) {
    lcd_text(x, y, k, C.gray, C.widget, 1);
    lcd_text(x + 74, y, (v == null || v == "" || v == "-") ? tr("no data") : v,
             vc ?? C.white, C.widget, 1);
}

function draw_cell_page() {
    let l = st.data?.lte ?? {};
    let c = l.cell ?? {};
    if (st.cpage == null || st.cpage >= CELL_PAGES) st.cpage = 0;

    lcd_clear(C.bg);
    draw_header(sprintf(tr("Cell %d/%d"), st.cpage + 1, CELL_PAGES));

    let cx = 10, cw = 300, y = 28;

    if (st.cpage == 0) {
        lcd_rect(cx, y, cw, 140, C.widget);
        lcd_rect(cx, y, 4, 140, C.cyan);
        lcd_text(cx + 10, y + 6, tr("IDENTITY"), C.gray, C.widget, 1);
        kv(cx + 10, y + 22, "PLMN", sprintf("%d-%02d", int(+(l.mcc ?? 0)), int(+(l.mnc ?? 0))));
        kv(cx + 10, y + 36, "LAC",  c.lac);
        kv(cx + 10, y + 50, "TAC",  c.tac);
        kv(cx + 10, y + 64, "CID",  sprintf("%d", int(+(l.cid ?? 0))));
        kv(cx + 10, y + 78, "CID hex", c.cid_hex);
        kv(cx + 10, y + 92, "eNB",  sprintf("%d", int(+(l.enbid ?? 0))));
        kv(cx + 10, y + 106, "PCI", sprintf("%d", int(+(l.pci ?? 0))));
        kv(cx + 10, y + 120, "EARFCN", sprintf("%d", int(+(l.earfcn ?? 0))));
    } else if (st.cpage == 1) {
        lcd_rect(cx, y, cw, 140, C.widget);
        lcd_rect(cx, y, 4, 140, C.green);
        lcd_text(cx + 10, y + 6, tr("RADIO"), C.gray, C.widget, 1);
        kv(cx + 10, y + 22, "Band", l.band);
        kv(cx + 10, y + 36, "BW",   c.bandwidth);
        kv(cx + 10, y + 50, "CQI",  c.cqi);
        kv(cx + 10, y + 64, "MIMO", c.mimo);
        kv(cx + 10, y + 78, "UE cat", c.uecat);
        kv(cx + 10, y + 92, "VoLTE", c.volte);
        kv(cx + 10, y + 106, "Pathloss", c.pathloss);
        kv(cx + 10, y + 120, "TX pwr", c.txpower);
    } else {
        lcd_rect(cx, y, cw, 84, C.widget);
        lcd_rect(cx, y, 4, 84, C.accent);
        lcd_text(cx + 10, y + 6, tr("CARRIERS"), C.gray, C.widget, 1);
        let row = 0;
        let cc = [ [ "PCC", l.band, int(+(l.pci ?? 0)), int(+(l.earfcn ?? 0)) ],
                   [ "SCC1", c.s1band, int(+(c.s1pci ?? 0)), int(+(c.s1earfcn ?? 0)) ],
                   [ "SCC2", c.s2band, int(+(c.s2pci ?? 0)), int(+(c.s2earfcn ?? 0)) ],
                   [ "SCC3", c.s3band, int(+(c.s3pci ?? 0)), int(+(c.s3earfcn ?? 0)) ] ];
        for (let e in cc) {
            if (e[1] == null || e[1] == "" || e[1] == "-") continue;
            lcd_text(cx + 10, y + 22 + row * 14, e[0], C.gray, C.widget, 1);
            lcd_text(cx + 50, y + 22 + row * 14, e[1], C.white, C.widget, 1);
            lcd_text(cx + 170, y + 22 + row * 14, sprintf("PCI %d", e[2]), C.gray, C.widget, 1);
            lcd_text(cx + 230, y + 22 + row * 14, sprintf("%d", e[3]), C.gray, C.widget, 1);
            row++;
        }
        if (row == 0)
            lcd_text(cx + 10, y + 22, tr("no aggregation"), C.dim, C.widget, 1);

        let y2 = y + 92;
        lcd_rect(cx, y2, cw, 48, C.widget);
        lcd_rect(cx, y2, 4, 48, "#D2A8FF");
        lcd_text(cx + 10, y2 + 6, tr("ANTENNA PORTS"), C.gray, C.widget, 1);
        let ap = c.antports ?? "";
        if (ap == "" || ap == "-") {
            lcd_text(cx + 10, y2 + 22, tr("no data"), C.dim, C.widget, 1);
        } else {
            let i = 0;
            for (let part in split(ap, " ")) {
                let f = split(part, ":");
                if (length(f) < 3 || i >= 2) continue;
                lcd_text(cx + 10 + i * 150, y2 + 22, sprintf("%s: %s / %s", f[0], f[1], f[2]),
                         C.white, C.widget, 1);
                i++;
            }
            let rd = c.rxdiv ?? "";
            if (rd != "" && rd != "-")
                lcd_text(cx + 10, y2 + 34, sprintf("RX div: %s", rd), C.gray, C.widget, 1);
        }
    }

    if (st.cpage == 3) {
        // Соседние соты столбиками: на 320x240 таблица из шести строк по пять
        // колонок нечитаема, а относительный уровень видно с одного взгляда.
        lcd_rect(cx, y, cw, 140, C.widget);
        lcd_rect(cx, y, 4, 140, C.green);

        // Своя сота отдельным блоком сверху: так не нужна пометка внутри
        // списка, а сравнивать соседей с текущей всё равно удобнее сверху вниз.
        let nb = c.neighbors;
        let own = null, others = [];
        if (type(nb) == "array")
            for (let e in nb)
                if (own == null && int(+(e?.serving ?? 0)) > 0) own = e;
                else push(others, e);

        let cell_row = function(e, yy, name_c) {
            let rsrp = int(+(e?.rsrp ?? 0));
            let col = LVC[MET.rsrp.lv(rsrp)];
            lcd_text(cx + 10, yy, sprintf("B%s", e?.band ?? "?"), name_c, C.widget, 1);
            lcd_text(cx + 40, yy, sprintf("%d", int(+(e?.pci ?? 0))), C.gray, C.widget, 1);
            lcd_text(cx + 74, yy, sprintf("%d", rsrp), col, C.widget, 1);
            let bx = cx + 110, bw = cw - 120;
            lcd_rect(bx, yy + 1, bw, 6, C.dim);
            let fill = int(bw * clampi(MET.rsrp.bar(rsrp), 0, 100) / 100);
            if (fill > 0) lcd_rect(bx, yy + 1, fill, 6, col);
        };

        lcd_text(cx + 10, y + 6, tr("OWN CELL"), C.gray, C.widget, 1);
        if (own) cell_row(own, y + 22, C.white);
        else lcd_text(cx + 10, y + 22, tr("no data"), C.dim, C.widget, 1);

        lcd_text(cx + 10, y + 44, tr("NEIGHBOURS"), C.gray, C.widget, 1);
        if (length(others) == 0) {
            lcd_text(cx + 10, y + 60, tr("no data"), C.dim, C.widget, 1);
        } else {
            let rows = length(others) > 4 ? 4 : length(others);
            for (let i = 0; i < rows; i++)
                cell_row(others[i], y + 60 + i * 19, C.gray);
        }
    }

    let a = cell_arrow(-1), z = cell_arrow(1);
    lcd_rect(a.x, a.y, a.w, a.h, C.widget);
    lcd_text(a.x + 60, a.y + 6, "<<", C.accent, C.widget, 2);
    lcd_rect(z.x, z.y, z.w, z.h, C.widget);
    lcd_text(z.x + 60, z.y + 6, ">>", C.accent, C.widget, 2);

    draw_back();
    lcd_flush();
}

// Карточки доступности сервисов. Пробу делает svcping.sh поверх netpri.sh
// (TLS/HTTP, а не ICMP - на мобильном интернете с белыми списками пинг молчит
// даже там, где сайт открывается). Шесть хостов занимают до полуминуты,
// поэтому экран только читает готовый файл, а проверку запускает фоном.
function svc_btn(i) {
    return { x: 8 + (i % 2) * 156, y: 28 + int(i / 2) * 48, w: 150, h: 44 };
}

function svc_hosts() {
    if (ucur) {
        let l = ucur.get("lcd", "services", "host");
        if (type(l) == "array" && length(l) > 0) return l;
    }
    return [ "ya.ru", "api.telegram.org", "youtube.com", "github.com" ];
}

// Нижний ряд: «проверить все» и «назад» рядом, во всю высоту полосы - по
// маленькой кнопке пальцем попадать неудобно.
// Габариты те же, что у кнопок меню: BTN_W x BTN_H с тем же отступом.
let SVC_BAR_Y = LCD_H - BTN_H;

function svc_refresh_btn() {
    return { x: BTN_PAD, y: SVC_BAR_Y, w: BTN_W, h: BTN_H };
}

function svc_back_btn() {
    return { x: BTN_PAD * 2 + BTN_W, y: SVC_BAR_Y, w: BTN_W, h: BTN_H };
}

function draw_services_page() {
    let res = st.data?.services;
    let hosts = svc_hosts();
    lcd_clear(C.bg);
    draw_header(tr("Services"));

    for (let i = 0; i < length(hosts) && i < 6; i++) {
        let b = svc_btn(i);
        // Результат ищем по имени хоста, а не по номеру: список в uci могли
        // поменять после последней проверки, и позиции разъехались бы.
        let r = null;
        if (type(res) == "array")
            for (let e in res)
                if (e?.host == hosts[i]) r = e?.r;

        // Не проверяли - карточка серая и без времени: пустое место читалось
        // бы как «сервис недоступен», а мы этого пока не знаем.
        let known = (r != null);
        let ok = known && int(+(r.ok ?? 0)) > 0;
        let col = !known ? C.dim : (ok ? C.green : C.red);

        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 4, b.h, col);
        lcd_rect(b.x + b.w - 14, b.y + 8, 8, 8, col);

        lcd_text(b.x + 12, b.y + 8, tcut(hosts[i], 18),
                 known ? C.white : C.gray, C.widget, 1);
        if (known)
            lcd_text(b.x + 12, b.y + 24,
                     ok ? sprintf("%d ms", int(+(r.ms ?? 0))) : tr("no answer"),
                     ok ? C.gray : C.red, C.widget, 1);
    }

    // «Пинг» - обычная карточка меню, «назад» - в точности как в меню:
    // своя заливка C.hdr, без нижней грани и с той же надписью.
    let rb = svc_refresh_btn(), bb = svc_back_btn();
    let lbl = tr("Ping");
    lcd_rect(rb.x, rb.y, rb.w, rb.h, C.btn);
    lcd_rect(rb.x, rb.y + rb.h - 3, rb.w, 3, C.border);
    lcd_text(rb.x + int((rb.w - tlen(lbl) * 12) / 2), rb.y + int((rb.h - 14) / 2),
             lbl, C.white, C.btn, 2);

    lcd_rect(bb.x, bb.y, bb.w, bb.h, C.hdr);
    lcd_text(bb.x + 20, bb.y + 20, tr("<<< BACK"), C.white, C.hdr, 2);

    lcd_flush();
}

function draw_qr_page() {
    let sec = st.qr_sec ?? "default_radio1";
    let ssid = ucur ? (ucur.get("wireless", sec, "ssid") ?? "N/A") : "N/A";
    let key  = ucur ? (ucur.get("wireless", sec, "key") ?? "") : "";
    let rows = wifi_qr_rows(ssid, key);

    lcd_clear(C.bg);
    draw_header(st.qr_band ?? "WiFi");
    lcd_text(10, 28, ssid, C.white, C.bg, 2);

    if (rows) {
        let n = length(rows);
        let scale = int((BACK_Y - 54) / n);
        if (scale > 6) scale = 6;
        if (scale < 1) scale = 1;
        let side = n * scale;
        draw_qr(rows, int((LCD_W - side) / 2), 50, scale, "#000000", "#FFFFFF");
    } else {
        lcd_text(10, 100, tr("QR unavailable"), C.red, C.bg, 2);
        lcd_text(10, 124, tr("install qrencode"), C.gray, C.bg, 1);
    }

    draw_back();
    lcd_flush();
}

function draw_wifi_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header("WiFi");

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;

    // Card 1: 2.4GHz WiFi (radio1)
    let y1 = 28 + oy;
    let disabled_2g_state = ucur ? wifi_is_disabled("radio1", "default_radio1") : true;
    lcd_rect(cx, y1, cw, 80, C.widget);
    lcd_rect(cx, y1, 4, 80, disabled_2g_state ? C.dim : C.green);
    lcd_text(cx + 10, y1 + 6, "2.4 GHz", C.gray, C.widget, 1);
    
    if (ucur) {
        let ssid_2g = ucur.get("wireless", "default_radio1", "ssid") ?? "N/A";
        let key_2g = ucur.get("wireless", "default_radio1", "key") ?? "N/A";
        let disabled_2g = wifi_is_disabled("radio1", "default_radio1");
        
        lcd_text(cx + 10, y1 + 20, sprintf("SSID: %s", ssid_2g), C.white, C.widget, 2);
        lcd_text(cx + 10, y1 + 38, sprintf(tr("Pass: %s"), key_2g), C.accent, C.widget, 2);
        
        // Count clients on 2.4GHz
        let clients_2g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "2G" || cl.band == "2.4G") clients_2g++;
            }
        }
        lcd_text(cx + 10, y1 + 56, sprintf(tr("Clients: %d"), clients_2g), C.cyan, C.widget, 2);
        
        let status_2g = disabled_2g ? "OFF" : "ON";
        let status_c_2g = disabled_2g ? C.gray : C.green;
        lcd_text(cx + 160, y1 + 56, status_2g, status_c_2g, C.widget, 2);
        if (!disabled_2g) {
            let qb = qr_box(y1);
            draw_qr(wifi_qr_rows(ssid_2g, key_2g), qb.x + 2, qb.y + 2, 2, "#000000", "#FFFFFF");
        }
    }

    // Card 2: 5GHz WiFi (radio0)
    let y2 = y1 + 86;
    let disabled_5g_state = ucur ? wifi_is_disabled("radio0", "default_radio0") : true;
    lcd_rect(cx, y2, cw, 80, C.widget);
    lcd_rect(cx, y2, 4, 80, disabled_5g_state ? C.dim : C.green);
    lcd_text(cx + 10, y2 + 6, "5 GHz", C.gray, C.widget, 1);
    
    if (ucur) {
        let ssid_5g = ucur.get("wireless", "default_radio0", "ssid") ?? "N/A";
        let key_5g = ucur.get("wireless", "default_radio0", "key") ?? "N/A";
        let disabled_5g = wifi_is_disabled("radio0", "default_radio0");
        
        lcd_text(cx + 10, y2 + 20, sprintf("SSID: %s", ssid_5g), C.white, C.widget, 2);
        lcd_text(cx + 10, y2 + 38, sprintf(tr("Pass: %s"), key_5g), C.accent, C.widget, 2);
        
        // Count clients on 5GHz
        let clients_5g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "5G" || cl.band == "5GHz") clients_5g++;
            }
        }
        lcd_text(cx + 10, y2 + 56, sprintf(tr("Clients: %d"), clients_5g), C.cyan, C.widget, 2);
        
        let status_5g = disabled_5g ? "OFF" : "ON";
        let status_c_5g = disabled_5g ? C.gray : C.green;
        lcd_text(cx + 160, y2 + 56, status_5g, status_c_5g, C.widget, 2);
        if (!disabled_5g) {
            let qb = qr_box(y2);
            draw_qr(wifi_qr_rows(ssid_5g, key_5g), qb.x + 2, qb.y + 2, 2, "#000000", "#FFFFFF");
        }
    }

    draw_back();
    lcd_flush();
}

function draw_info_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header(tr("System Info"));

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;
    let board = null;
    if (uconn)
        board = uconn.call("system", "board", {});

    let load = d?.cpu_load_raw ? sprintf("%.2f", d.cpu_load_raw / 65536.0)
             : (d?.cpu_load ?? "?");
    let bat = d?.battery;
    let braw = bat?.raw_hex ?? "??";
    let badc = int(+(bat?.adc ?? 0));
    let bpct = int(+(bat?.percent ?? 0));

    // Версия драйвера - дата сборки, отдаётся ioctl'ом через touch_poll.
    let drv_ver = "?";
    let p = fs.popen("touch_poll version 2>/dev/null", "r");
    if (p) {
        drv_ver = trim(p.read("all") ?? "?");
        p.close();
    }

    // Card 1: System
    let y1 = 28 + oy;
    lcd_rect(cx, y1, cw, 52, C.widget);
    lcd_rect(cx, y1, 4, 52, C.cyan);
    lcd_text(cx + 10, y1 + 6, tr("SYSTEM"), C.gray, C.widget, 1);
    let hw = uconn ? (uconn.call("system", "board", {})?.model ?? "") : "";
    lcd_text(cx + 10, y1 + 20, sprintf(tr("Model %s"), hw != "" ? hw : "?"), C.white, C.widget, 1);
    lcd_text(cx + 10, y1 + 32, sprintf(tr("Uptime %s"), fmt_uptime(d?.uptime)), C.white, C.widget, 1);
    lcd_text(cx + 150, y1 + 32, sprintf(tr("Mem %dM"), int(+(d?.mem_free_mb ?? 0))), C.green, C.widget, 1);
    lcd_text(cx + 10, y1 + 44, sprintf(tr("CPU %s"), load), C.accent, C.widget, 1);

    // Card 2: Power
    let y2 = y1 + 58;
    lcd_rect(cx, y2, cw, 52, C.widget);
    lcd_rect(cx, y2, 4, 52, bat?.no_battery ? C.dim : (bat?.valid ? C.green : C.red));
    lcd_text(cx + 10, y2 + 6, tr("POWER"), C.gray, C.widget, 1);
    if (bat?.no_battery) {
        lcd_text(cx + 10, y2 + 20, tr("Battery not installed"), C.dim, C.widget, 1);
        lcd_text(cx + 10, y2 + 32, sprintf(tr("ADC %d"), badc), C.dim, C.widget, 1);
    } else {
        let bat_state = bat?.charging ? tr("Charging") : tr("Battery");
        let bat_color = bat?.valid ? (bpct > 20 ? C.green : C.yellow) : C.red;
        lcd_text(cx + 10, y2 + 20, sprintf("%s %d%%", bat_state, bpct), bat_color, C.widget, 1);
        lcd_text(cx + 120, y2 + 20, sprintf(tr("ADC %d"), badc), C.white, C.widget, 1);
        lcd_text(cx + 10, y2 + 32, sprintf(tr("Raw %s"), braw), C.dim, C.widget, 1);
    }
    lcd_text(cx + 10, y2 + 44, bat?.valid ? tr("Status OK") : tr("Status invalid"), bat?.valid ? C.green : C.red, C.widget, 1);

    // Card 3: Software
    let y3 = y2 + 58;
    lcd_rect(cx, y3, cw, 52, C.widget);
    lcd_rect(cx, y3, 4, 52, "#D2A8FF");
    lcd_text(cx + 10, y3 + 6, tr("SOFTWARE"), C.gray, C.widget, 1);
    lcd_text(cx + 10, y3 + 20, sprintf("OpenWrt %s", board?.release?.version ?? "?"), C.white, C.widget, 1);
    lcd_text(cx + 10, y3 + 32, sprintf(tr("Kernel %s"), board?.kernel ?? "?"), C.dim, C.widget, 1);
    lcd_text(cx + 10, y3 + 44, sprintf("almond3s-lcd %s", drv_ver), C.accent, C.widget, 1);
    lcd_text(cx + cw - 10 - tlen(TG_LINK) * 6, y3 + 44, TG_LINK, C.dim, C.widget, 1);

    draw_back();
    lcd_flush();
}

let WCITY_DEFAULT = [ "Moscow", "Saint Petersburg", "Voronezh", "Novosibirsk",
                      "Yekaterinburg", "Kazan", "Nizhny Novgorod", "Samara",
                      "Rostov-on-Don", "Krasnoyarsk", "Sochi", "Khabarovsk",
                      "Vladivostok" ];
let WCITY_PER_PAGE = 8;

// В wttr.in уходит латинское имя (кириллицу он понимает хуже), а на экране
// показываем русское. Незнакомый город останется как записан.
let CITY_RU = {
    "Moscow": "Москва", "Saint Petersburg": "Петербург", "Voronezh": "Воронеж",
    "Novosibirsk": "Новосибирск", "Yekaterinburg": "Екатеринбург",
    "Kazan": "Казань", "Nizhny Novgorod": "Нижний Новгород",
    "Samara": "Самара", "Rostov-on-Don": "Ростов-на-Дону",
    "Krasnoyarsk": "Красноярск", "Sochi": "Сочи",
    "Khabarovsk": "Хабаровск", "Vladivostok": "Владивосток",
};

function city_name(v) {
    return lang() == "ru" ? (CITY_RU[v] ?? v) : v;
}

// wttr.in отдаёт ветер в км/ч, а у нас принято в метрах в секунду.
function wind_fmt(v) {
    v ??= "";
    let m = match(v, /([0-9]+)/);
    if (!m) return v;
    // wttr.in отдаёт направление стрелкой перед числом («↘15km/h»). Раньше её
    // выбрасывали вместе с остальным текстом - рисовать было нечем; теперь
    // стрелка есть в шрифте, и направление ветра видно.
    // Берём всё, что стоит до числа, а не класс символов: регулярки ucode
    // работают по байтам, и класс из многобайтовых стрелок выхватывал один
    // байт - на экран уходила битая последовательность, то есть пустое место.
    let dir = match(v, /^([^0-9]+)/);
    let arrow = dir ? trim(dir[1]) + " " : "";
    if (lang() != "ru") return arrow + v;
    let kmh = int(m[1]);
    return sprintf("%s%d м/с", arrow, int((kmh * 10 + 18) / 36));
}

// Список правится без пересборки: uci add_list lcd.weather.choices='Berlin'
function wcity_list() {
    if (ucur) {
        let l = ucur.get("lcd", "weather", "choices");
        if (type(l) == "array" && length(l) > 0) return l;
    }
    return WCITY_DEFAULT;
}

function wcity_pages() {
    let t = length(wcity_list());
    return t > 0 ? int((t + WCITY_PER_PAGE - 1) / WCITY_PER_PAGE) : 1;
}

function wcity_current() {
    return (ucur ? ucur.get("lcd", "weather", "city") : null) ?? "Moscow";
}

function wcity_btn(i) {
    return { x: 8 + (i % 2) * 156, y: 28 + int(i / 2) * 36, w: 148, h: 32 };
}

// Стрелки листания — только когда страниц больше одной.
function wcity_arrow(dir) {
    return { x: dir < 0 ? 8 : 164, y: 174, w: 148, h: 28 };
}

function draw_wcity_page() {
    lcd_clear(C.bg);
    let pages = wcity_pages();
    if (st.wpage == null || st.wpage >= pages) st.wpage = 0;
    draw_header(pages > 1 ? sprintf(tr("City %d/%d"), st.wpage + 1, pages) : "City");

    let cur = wcity_current();
    let list = wcity_list();
    let base = st.wpage * WCITY_PER_PAGE;

    for (let i = 0; i < WCITY_PER_PAGE; i++) {
        let idx = base + i;
        if (idx >= length(list)) break;
        let b = wcity_btn(i);
        let sel = (list[idx] == cur);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 4, b.h, sel ? "#D2A8FF" : C.border);
        lcd_text(b.x + 12, b.y + 10, city_name(list[idx]),
                 sel ? C.white : C.gray, C.widget, 1);
    }

    if (pages > 1) {
        let a = wcity_arrow(-1), z = wcity_arrow(1);
        lcd_rect(a.x, a.y, a.w, a.h, C.widget);
        lcd_text(a.x + 60, a.y + 8, "<<", C.accent, C.widget, 2);
        lcd_rect(z.x, z.y, z.w, z.h, C.widget);
        lcd_text(z.x + 60, z.y + 8, ">>", C.accent, C.widget, 2);
    }

    draw_back();
    lcd_flush();
}

function draw_weather_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header(tr("Weather"));

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;
    let w = d?.weather;

    let y1 = 28 + oy;
    let ch = BACK_Y - 4 - y1;   // до самой кнопки «назад», без пустой полосы
    lcd_rect(cx, y1, cw, ch, C.widget);
    lcd_rect(cx, y1, 4, ch, C.yellow);


    if (w) {
        let desc  = w.desc ?? "";
        let temp  = w.temp ?? "?";
        let feels = w.feels ?? "?";
        let hum   = w.humidity ?? "?";
        let wind  = w.wind ?? "?";

        draw_weather_icon(cx + cw - 90, y1 + 14, desc, 3, null); // 72x72 icon (24x24 grid)

        // temp/feels already include unit (e.g. "+13C") — degree sign was
        // stripped by weather_fetch.sh since the LCD font has no glyph for it
        lcd_text(cx + 16, y1 + 16, temp, C.white, C.widget, 4);
        // Город мельче и белым: голубым он сливался с описанием погоды.
        lcd_text(cx + 16, y1 + 52, city_name(w?.city) ?? "", C.white, C.widget, 1);
        // Ниже иконки (она занимает до y1+86), иначе длинное описание налезает.
        lcd_text(cx + 16, y1 + 90, desc, C.cyan, C.widget, 2);
        // Три величины в одну строку: мелким шрифтом это 40 знаков из 44,
        // которые влезают в карточку.
        lcd_text(cx + 16, y1 + 118,
                 sprintf(tr("Feels %s  Hum %s  Wind %s"), feels, hum, wind_fmt(wind)),
                 C.gray, C.widget, 1);
    } else {
        lcd_text(cx + 16, y1 + 60, tr("No data yet"), C.dim, C.widget, 2);
        lcd_text(cx + 16, y1 + 84, tr("Tap Weather in menu to fetch"), C.dim, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

function draw_ip_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header(tr("External IP"));
    let y = 30;

    let eip = d?.vpn?.external_ip ?? "unknown";
    lcd_text(4, y, tr("Exit IP:"), C.cyan, C.bg, 2);
    y += 22;
    lcd_text(4, y, eip, C.accent, C.bg, 3);
    y += 30;

    let vpn = d?.vpn?.active;
    lcd_text(4, y, vpn ? "via VPN (WireGuard)" : "Direct (no VPN)",
        vpn ? C.green : C.red, C.bg, 2);
    y += 24;

    let ping_g = int(+(d?.ping?.google_ms ?? -1));
    let ping_v = int(+(d?.vpn?.ping_ms ?? -1));
    let pg_s = ping_g < 0 ? "FAIL" : sprintf("%dms", ping_g);
    let pv_s = ping_v < 0 ? "FAIL" : sprintf("%dms", ping_v);
    lcd_text(4, y, sprintf("Google: %s  VPN: %s", pg_s, pv_s), C.white, C.bg, 1);
    y += 14;

    // LTE IP for reference
    let lip = d?.lte?.ip ?? "?";
    lcd_text(4, y, sprintf("LTE IP: %s", lip), C.gray, C.bg, 1);

    draw_back();
    lcd_flush();
}

function draw_metric_row(x, y, w, key, label, v) {
    let m = MET[key];
    let col = LVC[m.lv(v)];
    let bx = x + 86, bw = w - 86;
    lcd_text(x, y, label, C.gray, C.widget, 1);
    lcd_text(x + 42, y, sprintf("%d", v), col, C.widget, 1);
    lcd_rect(bx, y + 1, bw, 6, C.dim);
    let fill = int(bw * clampi(m.bar(v), 0, 100) / 100);
    if (fill > 0) lcd_rect(bx, y + 1, fill, 6, col);
}

function draw_lte_page() {
    let d = st.data;
    let l = d?.lte ?? {};
    let u = d?.uqmi;
    lcd_clear(C.bg);
    draw_header(tr("Modem"));

    let ox = st.ox, oy = st.oy;
    let cx = 10 + ox;
    let cw = 300;

    let csq  = int(+(l.csq ?? 0));
    let sigp = int(+(l.signal ?? 0));
    let rsrp = int(+(l.rsrp ?? 0));
    let sig  = sig_state();
    let sbars = sig.bars, scol = sig.color;
    let temp = int(+(l.temp ?? 0));
    let nca  = int(+(l.nca ?? 0));

    // Карточка 1: кто и как подключён. Сетка «подпись - значение» в две
    // колонки, как в карточке модема на дашборде: подписи выровнены по левому
    // краю колонки, значения - по своей. Уровня сигнала здесь нет намеренно:
    // лесенка уже в шапке, а цифры - в карточке «Сигнал» ниже.
    let y1 = 28 + oy;
    lcd_rect(cx, y1, cw, 46, C.widget);
    lcd_rect(cx, y1, 4, 46, C.green);

    let LX1 = cx + 10, VX1 = cx + 64;   // левая колонка: подпись, значение
    // Правая колонка - только значения, и они прижаты к правому краю карточки
    // с тем же отступом, что CSQ в «Сигнале»: длина у них разная, а край общий.
    let REDGE = cx + cw - 10;
    let rx = function(t) { return REDGE - tlen(t) * 6; };

    // Модель длиннее колонки обрезаем не как попало: сперва выбрасываем имя
    // вендора («Telit LM960A18-ENS» -> «LM960A18-ENS»), от него толку меньше,
    // чем от самой модели.
    let model = l.modem ?? "-";
    if (tlen(model) > 15) {
        let w = split(model, " ");
        if (length(w) > 1) model = join(" ", slice(w, 1));
    }
    lcd_text(LX1, y1 + 5, tr("Model"), C.gray, C.widget, 1);
    lcd_text(VX1, y1 + 5, tcut(model, 15), C.white, C.widget, 1);

    // Правая колонка идёт без подписей: «LTE», «45°C» и «SIM 1» говорят сами
    // за себя, а подписи только съедали ширину.
    let mode_s = l.mode ?? "-";
    if (nca > 1) mode_s += sprintf(" %dCA", nca);
    lcd_text(rx(mode_s), y1 + 5, mode_s, C.cyan, C.widget, 1);

    lcd_text(LX1, y1 + 19, tr("Band"), C.gray, C.widget, 1);
    lcd_text(VX1, y1 + 19, tcut(l.band ?? "-", 15), C.accent, C.widget, 1);

    if (temp > 0) {
        let tc = temp >= 70 ? C.red : (temp >= 55 ? C.yellow : C.white);
        let ts = sprintf("%d°C%s", temp, int(+(l.therm ?? 0)) > 0 ? " !" : "");
        lcd_text(rx(ts), y1 + 19, ts, tc, C.widget, 1);
    } else {
        lcd_text(rx("-"), y1 + 19, "-", C.dim, C.widget, 1);
    }

    // Номеру нужна вся ширина строки: с форматированием это 16 знаков, в
    // колонку он не влезал. Справа от него - слот и роуминг.
    let phone = phone_short(l.phone);
    lcd_text(LX1, y1 + 33, tr("Number"), C.gray, C.widget, 1);
    lcd_text(VX1, y1 + 33, phone != "" ? phone : "-",
             phone != "" ? C.white : C.dim, C.widget, 1);

    // Слот и роуминг прижимаем тем же краем, но цвета разные - поэтому считаем
    // ширину пары целиком, а рисуем двумя кусками.
    let slot = int(+(l.simslot ?? 0));
    let sim_s = slot > 0 ? sprintf(tr("SIM %d"), slot) : "";
    let roam_s = int(+(l.roaming ?? 0)) > 0 ? tr("ROAM") : "";
    let tail = roam_s != "" ? (sim_s != "" ? roam_s + " " + sim_s : roam_s) : sim_s;
    if (tail != "") {
        let tx0 = rx(tail);
        if (roam_s != "") {
            lcd_text(tx0, y1 + 33, roam_s, C.yellow, C.widget, 1);
            tx0 += (tlen(roam_s) + 1) * 6;
        }
        if (sim_s != "")
            lcd_text(tx0, y1 + 33, sim_s, C.gray, C.widget, 1);
    }

    // Card 2: radio metrics with the same scales as the web dashboard
    let y2 = y1 + 52;
    lcd_rect(cx, y2, cw, 64, C.widget);
    lcd_rect(cx, y2, 4, 64, C.cyan);
    lcd_text(cx + 10, y2 + 6, tr("SIGNAL"), C.gray, C.widget, 1);
    if (csq > 0)
        lcd_text(cx + cw - 10 - 9 * 6, y2 + 6, sprintf("CSQ %d/31", csq),
                 C.gray, C.widget, 1);
    draw_metric_row(cx + 10, y2 + 18, cw - 20, "rsrp", "RSRP", rsrp);
    draw_metric_row(cx + 10, y2 + 30, cw - 20, "rsrq", "RSRQ", int(+(l.rsrq ?? 0)));
    draw_metric_row(cx + 10, y2 + 42, cw - 20, "sinr", "SINR", int(+(l.sinr ?? 0)));
    draw_metric_row(cx + 10, y2 + 54, cw - 20, "rssi", "RSSI", int(+(l.rssi ?? 0)));

    // Card 3: serving cell + connection
    let y3 = y2 + 70;
    lcd_rect(cx, y3, cw, 58, C.widget);
    lcd_rect(cx, y3, 4, 58, "#D2A8FF");
    lcd_text(cx + 10, y3 + 6, tr("CELL / NETWORK"), C.gray, C.widget, 1);
    // Три колонки с общими краями: слева, по центру карточки и по правому краю
    // с тем же отступом, что и в карточках выше.
    // Ноль тут - это «модем не сказал», а не «нулевая сота»: SIM7100E, например,
    // PCI и EARFCN не отдаёт вовсе. Показываем прочерк, иначе выглядит как
    // настоящее значение.
    let cell_id = function(label, v) {
        let n = int(+(v ?? 0));
        return sprintf("%s %s", label, n > 0 ? sprintf("%d", n) : "-");
    };
    let enb_s = cell_id("eNB", u?.enb_id);
    let earf_s = cell_id("EARFCN", l.earfcn);
    lcd_text(cx + 10, y3 + 18, cell_id("PCI", u?.pci), C.white, C.widget, 1);
    lcd_text(cx + int((cw - tlen(enb_s) * 6) / 2), y3 + 18, enb_s, C.white, C.widget, 1);
    lcd_text(rx(earf_s), y3 + 18, earf_s, C.white, C.widget, 1);

    let mcc = int(+(u?.mcc ?? 0)), mnc = int(+(u?.mnc ?? 0));
    let plmn_name = get_plmn_name(mcc, mnc);
    lcd_text(cx + 10, y3 + 30, l.operator ?? "Unknown", C.white, C.widget, 1);
    if (mcc > 0) {
        let plmn_s = sprintf("%d-%02d%s", mcc, mnc, plmn_name ? " " + plmn_name : "");
        lcd_text(rx(plmn_s), y3 + 30, plmn_s, C.gray, C.widget, 1);
    }

    let conn_s = conn_fmt(l.conn_time);
    lcd_text(cx + 10, y3 + 42, l.ip ?? "-", C.green, C.widget, 1);
    lcd_text(rx(conn_s), y3 + 42, conn_s, C.gray, C.widget, 1);

    draw_back();
    lcd_flush();
}

function draw_traffic_page() {
    lcd_clear(C.bg);
    draw_header(tr("Traffic"));

    // Fixed coordinates here: avoid burn-in shifting artifacts
    let cx = 10;
    let cw = 300;

    // LTE / WWAN
    let rx_last = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
    let tx_last = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
    let y1 = 28;
    lcd_rect(cx, y1, cw, 72, C.widget);
    lcd_rect(cx, y1, 4, 72, C.cyan);
    lcd_text(cx + 10, y1 + 6, "MODEM - wwan0", C.gray, C.widget, 1);
    lcd_text(cx + 10, y1 + 20, "RX", C.green, C.widget, 1);
    lcd_text(cx + 32, y1 + 20, fmt_bytes(rx_last) + "/s", C.white, C.widget, 1);
    lcd_text(cx + 165, y1 + 20, "TX", C.red, C.widget, 1);
    lcd_text(cx + 187, y1 + 20, fmt_bytes(tx_last) + "/s", C.white, C.widget, 1);

    let rm = arr_minmax(hist.rx);
    let tm = arr_minmax(hist.tx);
    let mx1 = rm.max > tm.max ? rm.max : tm.max;
    if (mx1 < 10240) mx1 = 10240;
    draw_graph_compact(cx + 8, y1 + 34, cw - 16, 28, hist.rx, C.green, 0, mx1, true);
    let n = length(hist.tx);
    if (n >= 2) {
        let pts = n > HIST_LEN ? HIST_LEN : n;
        let start = n - pts;
        let step_x = ((cw - 16) - 2) / (pts - 1);
        let prev_px = -1, prev_py = -1;
        for (let i = 0; i < pts; i++) {
            let val = hist.tx[start + i];
            let px = cx + 9 + int(i * step_x);
            let py = y1 + 61 - int(log_frac(val, mx1) * 26 / 1000);
            if (py < y1 + 34) py = y1 + 34;
            if (py > y1 + 61) py = y1 + 61;
            let sw = int(step_x); if (sw < 1) sw = 1;
            lcd_rect(px, py, sw, 1, C.red);
            if (prev_px >= 0) {
                let dy = py - prev_py;
                let ys = dy > 0 ? prev_py : py;
                if (dy != 0) lcd_rect(px, ys, 1, (dy > 0 ? dy : -dy), C.red);
            }
            prev_px = px; prev_py = py;
        }
    }

    // WAN / Ethernet
    let wan_rx = length(hist.wan_rx) > 0 ? hist.wan_rx[length(hist.wan_rx) - 1] : 0;
    let wan_tx = length(hist.wan_tx) > 0 ? hist.wan_tx[length(hist.wan_tx) - 1] : 0;
    let y2 = y1 + 78;
    lcd_rect(cx, y2, cw, 72, C.widget);
    lcd_rect(cx, y2, 4, 72, C.yellow);
    lcd_text(cx + 10, y2 + 6, sprintf(tr("UPLINK - %s"), default_iface() ?? "none"), C.gray, C.widget, 1);
    lcd_text(cx + 10, y2 + 20, "RX", C.green, C.widget, 1);
    lcd_text(cx + 32, y2 + 20, fmt_bytes(wan_rx) + "/s", C.white, C.widget, 1);
    lcd_text(cx + 165, y2 + 20, "TX", C.red, C.widget, 1);
    lcd_text(cx + 187, y2 + 20, fmt_bytes(wan_tx) + "/s", C.white, C.widget, 1);

    let brm = arr_minmax(hist.wan_rx);
    let btm = arr_minmax(hist.wan_tx);
    let mx2 = brm.max > btm.max ? brm.max : btm.max;
    if (mx2 < 10240) mx2 = 10240;
    draw_graph_compact(cx + 8, y2 + 34, cw - 16, 28, hist.wan_rx, C.green, 0, mx2, true);
    let n2 = length(hist.wan_tx);
    if (n2 >= 2) {
        let pts = n2 > HIST_LEN ? HIST_LEN : n2;
        let start = n2 - pts;
        let step_x = ((cw - 16) - 2) / (pts - 1);
        let prev_px = -1, prev_py = -1;
        for (let i = 0; i < pts; i++) {
            let val = hist.wan_tx[start + i];
            let px = cx + 9 + int(i * step_x);
            let py = y2 + 61 - int(log_frac(val, mx2) * 26 / 1000);
            if (py < y2 + 34) py = y2 + 34;
            if (py > y2 + 61) py = y2 + 61;
            let sw = int(step_x); if (sw < 1) sw = 1;
            lcd_rect(px, py, sw, 1, C.red);
            if (prev_px >= 0) {
                let dy = py - prev_py;
                let ys = dy > 0 ? prev_py : py;
                if (dy != 0) lcd_rect(px, ys, 1, (dy > 0 ? dy : -dy), C.red);
            }
            prev_px = px; prev_py = py;
        }
    }

    draw_back();
    lcd_flush();
}


// =============================================
//  PAGE DRAWING DISPATCH
// =============================================

function draw_current() {
    switch (st.page) {
    case "dashboard": draw_dashboard(); break;
    case "menu":      draw_menu(); break;
    case "wifi":      draw_wifi_page(); break;
    case "info":      draw_info_page(); break;
    case "weather":   draw_weather_page(); break;
    case "wcity":     draw_wcity_page(); break;
    case "qr":        draw_qr_page(); break;
    case "display":   draw_display_page(); break;
    case "cell":      draw_cell_page(); break;
    case "services":  draw_services_page(); break;
    case "ip":        draw_ip_page(); break;
    case "lte":       draw_lte_page(); break;
    case "traffic":   draw_traffic_page(); break;
    case "sms":       draw_sms_page(); break;
    case "sms1":      draw_sms_one(); break;
    }
}


// =============================================
//  SCREENSAVER
// =============================================

function draw_screensaver() {
    let t = localtime();
    let night = night_now();
    let bg = night ? "#000000" : C.bg;
    let primary = night ? "#1F6F3D" : C.white;
    let secondary = night ? "#1F6F3D" : C.gray;
    let accent = night ? "#1F6F3D" : C.accent;

    lcd_clear(bg);

    let d = st.data;
    let ts = clock_str();
    let ds = date_str();
    let style = saver_style();
    let bat = d?.battery;
    let bpct = int(+(bat?.percent ?? 0));
    let bchg = bat?.charging && !bat?.no_battery;

    // Режим «строка»: одна полоса как в шапке, по центру экрана.
    if (style == "line") {
        let sig = sig_state();
        let bstr = bat?.no_battery ? "--" : sprintf("%d%%", bpct);
        let op = tcut(d?.lte?.operator ?? "", 9);
        let y0 = int(LCD_H / 2) - 8;
        let x = 10;

        lcd_text(x, y0, ts, primary, bg, 2);
        x += tlen(ts) * 12 + 10;
        draw_sigbars(x, y0 - 1, sig.bars, night ? primary : sig.color,
                     night ? "#0A2A16" : C.dim);
        x += 5 * 8 + 8;
        if (op != "") {
            lcd_text(x, y0, op, primary, bg, 2);
            x += tlen(op) * 12 + 10;
        }
        draw_batt_icon(x, y0 - 1, 32, 16, bg, bpct, bat?.no_battery,
                       night ? primary : null, bchg, night ? "#0A2A16" : C.dim);
        lcd_text(x + 40, y0, bstr, primary, bg, 2);

        lcd_flush();
        return;
    }

    // В режиме «часы» экран занят только ими, поэтому вдвое крупнее.
    // Ширина знакоместа - ровно 6*масштаб, иначе центрирование врёт.
    let clk_sz = (style == "clock") ? 8 : 5;
    let clk_w = tlen(ts) * 6 * clk_sz;

    // Дата не должна быть шире часов, иначе строка снизу перевешивает.
    // Берём самый крупный масштаб, который в эту ширину укладывается, а
    // если и двойной не влезает - сокращаем месяц, но масштаб не роняем:
    // «12 авг 2026» вторым читается лучше, чем «12 августа, 2026» первым.
    let date_sz = 0;
    for (let z = 4; z >= 2; z--) {
        if (tlen(ds) * 6 * z <= clk_w) { date_sz = z; break; }
    }
    if (date_sz == 0) {
        ds = date_str(true);
        date_sz = (tlen(ds) * 6 * 2 <= clk_w) ? 2 : 1;
    }
    let date_w = tlen(ds) * 6 * date_sz;
    let date_gap = 10;

    // В режиме «часы» центрируем по вертикали пару целиком - часы и дату.
    let blk_h = 7 * clk_sz + date_gap + 7 * date_sz;
    let clk_y = (style == "clock") ? int((LCD_H - blk_h) / 2) : 12;
    let clk_x = int((LCD_W - clk_w) / 2);
    lcd_text(clk_x, clk_y, ts, primary, bg, clk_sz);

    // В полном режиме дата стоит на своём прежнем месте под часами.
    let date_y = (style == "clock") ? clk_y + 7 * clk_sz + date_gap : 54;
    lcd_text(int((LCD_W - date_w) / 2), date_y, ds, secondary, bg, date_sz);

    // Уровень сигнала слева, вровень с батареей справа. Имя оператора не
    // показываем: на заставке важен сам факт связи, а не чей это оператор.
    {
        let sig = sig_state();
        draw_sigbars(14, 10, sig.bars, night ? primary : sig.color,
                     night ? "#0A2A16" : C.dim);
        if (int(d?.sms_new ?? 0) > 0) {
            let ex = 14 + 5 * 8 + 4;
            if (clk_y < 32 && ex + ENV_W + 6 > clk_x)
                ex = clk_x - ENV_W - 6;
            draw_env_icon(ex, 10, 1,
                          night ? "#0A2A16" : null, night ? primary : null);
        }
    }

    // --- Battery: compact phone-style icon, top-right corner ---
    let b_w = 32, b_h = 16, b_y = 10;
    let bx = LCD_W - b_w - 16;

    draw_batt_icon(bx, b_y, b_w, b_h, bg, bpct, bat?.no_battery,
                   night ? primary : null, bchg, night ? "#0A2A16" : C.dim);

    // Погоду рисуем только в полном режиме.
    if (style != "full") { lcd_flush(); return; }

    // --- Weather card: big icon + info, sized to fill the remaining space ---
    let w = d?.weather;
    let wy = 72;
    let wbox_h = 152;
    let tx0 = 16, tw = 288;


    if (w) {
        let desc  = w.desc ?? "";
        let temp  = w.temp ?? "?";
        let feels = w.feels ?? "?";
        let hum   = w.humidity ?? "?";
        let wind  = w.wind ?? "?";

        // Big icon (72x72), in night mode use the single monochrome tone
        draw_weather_icon(tx0 + tw - 96, wy + 10, desc, 3, night ? primary : null); // 72x72 icon (24x24 grid)

        lcd_text(tx0 + 12, wy + 16, temp, primary, bg, 4);
        lcd_text(tx0 + 12, wy + 52, city_name(w?.city) ?? "", primary, bg, 1);
        lcd_text(tx0 + 12, wy + 90, desc, accent, bg, 2);
        lcd_text(tx0 + 12, wy + 118,
                 sprintf(tr("Feels %s  Hum %s  Wind %s"), feels, hum, wind_fmt(wind)),
                 secondary, bg, 1);
    } else {
        lcd_text(tx0 + 12, wy + 60, tr("No data yet"), secondary, bg, 2);
        lcd_text(tx0 + 12, wy + 86, tr("Open menu > Weather to fetch"), secondary, bg, 1);
    }

    if (night)
        lcd_text(50, 226, "Wake up, Neo...The Matrix has you...", secondary, bg, 1);

    lcd_flush();
}


// =============================================
//  TOUCH HANDLING
// =============================================

// Run shell script from SCRIPTS dir (non-blocking with &)
let SCREEN_REQ = "/tmp/lcd_screen_req";

// Подсветка - это GPIO 31, он же светодиод из DTS. Гасим именно через него, а
// не через ioctl(4) драйвера: оба дёргают тот же пин, но при ioctl ядро остаётся
// с прежним значением brightness, и любая перезагрузка триггеров светодиода
// вернёт подсветку сама по себе. ioctl оставлен запасным путём - на случай, если
// светодиода в DTS нет.
// Имя светодиода собирается ядром из color и function, поэтому оно зависит от
// DTS: без цвета получается «:power», с белым - «white:power». Ищем маской,
// чтобы не переписывать список при каждой правке дерева.
let BL_GLOBS = [ "/sys/class/leds/*power/brightness",
                 "/sys/class/leds/*power*/brightness" ];
let bl_path = null;

function backlight_path() {
    if (bl_path != null) return bl_path;
    for (let g in BL_GLOBS) {
        let m = fs.glob(g);
        if (length(m) > 0) { bl_path = m[0]; return bl_path; }
    }
    bl_path = "";
    return bl_path;
}

function backlight_write(on) {
    let p = backlight_path();
    if (p != "")
        system(sprintf("echo %d > %s", on ? 1 : 0, p));
    else
        system(sprintf("touch_poll b %d >/dev/null 2>&1", on ? 1 : 0));
}

// Тач работает независимо от подсветки, поэтому разбудить экран можно пальцем.
function set_blank(on) {
    if (st.blank == on) return;
    st.blank = on;
    backlight_write(!on);
}

function run_script(name, bg) {
    let cmd = SCRIPTS + "/" + name;
    if (bg) cmd += " &";
    system(cmd);
}

function go_page(p) {
    st.page = p;
    draw_current();
}

// Toast notification — overlay message with auto-dismiss
function toast(msg, color, bg_color, wait_sec) {
    color ??= C.white;
    bg_color ??= "#1082";
    wait_sec ??= 0;

    // Draw toast bar at bottom
    lcd_rect(0, LCD_H - 36, LCD_W, 36, bg_color);
    lcd_rect(0, LCD_H - 37, LCD_W, 1, color);  // top border
    lcd_text(10, LCD_H - 30, msg, color, bg_color, 2);
    lcd_flush();

    if (wait_sec > 0)
        system(sprintf("sleep %d", wait_sec));
}

// Full-screen action splash with progress dots
function action_splash(title, subtitle, color) {
    color ??= C.accent;
    lcd_clear(C.bg);
    lcd_rect(0, 0, LCD_W, HDR_H, C.hdr);
    lcd_text(4, 2, title, C.white, C.hdr, 2);
    lcd_text(LCD_W - 60, 2, clock_str(), C.cyan, C.hdr, 2);

    // Подзаголовок в три знакоместа шириной: "Перезапуск модема..." не влезал
    // в 320 пикселей и уезжал за край. Переносим по словам.
    {
        let sz = 3, cw2 = 6 * sz;
        let words = split(subtitle ?? "", " ");
        let lines = [], cur = "";
        for (let w in words) {
            let t = cur == "" ? w : cur + " " + w;
            if (tlen(t) * cw2 > LCD_W - 40 && cur != "") { push(lines, cur); cur = w; }
            else cur = t;
        }
        if (cur != "") push(lines, cur);
        let y0 = 90 - (length(lines) - 1) * 13;
        for (let i = 0; i < length(lines); i++)
            lcd_text(int((LCD_W - tlen(lines[i]) * cw2) / 2), y0 + i * 26, lines[i], color, C.bg, sz);
    }

    lcd_flush();
}

// Button press animation — invert colors briefly
function flash_btn(bx, by, bw, bh, label) {
    lcd_rect(bx, by, bw, bh, C.accent);
    lcd_text(bx + 8, by + 8, label ?? "", C.bg, C.accent, 2);
    lcd_flush();
}

function handle_touch(tx, ty) {
    // Dashboard → Menu on any touch
    if (st.page == "dashboard") {
        go_page("menu");
        return;
    }

    // У сервисов внизу две кнопки, поэтому общее правило «низ - назад» для
    // этой страницы не годится: левая половина запускает проверку.
    if (st.page == "services" && ty >= SVC_BAR_Y - 6) {
        if (tx >= svc_back_btn().x) {
            go_page("menu");
            return;
        }
        action_splash(tr("Services"), tr("Checking..."), C.cyan);
        system("/etc/lcd/scripts/svcping.sh >/dev/null 2>&1 &");
        sock_poll(1500);
        refresh_data();
        draw_services_page();
        return;
    }

    // Конвертик в шапке - быстрый вход в SMS с любой страницы.
    if (ty < HDR_H && int(st.data?.sms_new ?? 0) > 0 &&
        st.page != "sms" && st.page != "sms1") {
        let ex = 4 + tlen(clock_str()) * 12 + 10 + 5 * 8 + 8;
        if (in_rect(tx, ty, ex - 4, 0, ENV_W + 8, HDR_H)) {
            st.sms_pg = 0;
            st.sms_i = -1;
            sms_refresh();
            go_page("sms");
            return;
        }
    }

    // Back button (all sub-pages except menu). Страницы со своей листалкой сюда
    // не попадают: у них нижняя полоса поделена на стрелки и «назад», а общее
    // правило «низ - это назад» съедало нажатия по стрелкам целиком.
    if (st.page != "menu" && st.page != "sms" && st.page != "sms1" &&
        ty >= BACK_Y - 10) {
        go_page("menu");
        return;
    }

    // Menu button detection
    if (st.page == "sms") {
        let list = sms_list();
        let n = type(list) == "array" ? length(list) : 0;
        let pages = n > 0 ? int((n + SMS_ROWS - 1) / SMS_ROWS) : 1;
        let hit = pager_hit(tx, ty, st.sms_pg, pages);
        if (hit == 2) { go_page("menu"); return; }
        if (hit != 0) { st.sms_pg += hit; draw_sms_page(); return; }
        for (let r = 0; r < SMS_ROWS; r++) {
            let idx = st.sms_pg * SMS_ROWS + r;
            if (idx >= n) break;
            let y = 32 + r * 44;
            if (in_rect(tx, ty, 10, y, 300, 40)) {
                st.sms_i = idx;
                st.sms_tp = 0;
                go_page("sms1");
                return;
            }
        }
        return;
    }

    if (st.page == "sms1") {
        let list = sms_list();
        let m = (type(list) == "array" && st.sms_i >= 0 && st.sms_i < length(list))
                ? list[st.sms_i] : null;
        let lines = m ? sms_wrap(m.text, SMS_COLS) : [];
        let pages = int((length(lines) + SMS_LINES - 1) / SMS_LINES);
        if (pages < 1) pages = 1;
        let hit = pager_hit(tx, ty, st.sms_tp, pages);
        if (hit == 2) { go_page("sms"); return; }
        if (hit != 0) { st.sms_tp += hit; draw_sms_one(); return; }
        return;
    }

    if (st.page == "menu") {
        for (let i = 1; i <= 6; i++) {
            let b = btn_pos(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                // Flash button with label
                let labels = st.mpg == 1
                    ? [ tr("Network"), tr("WiFi"), tr("Modem"),
                        tr("Traffic"), tr("Info"), ">>>" ]
                    : (st.mpg == 2
                        ? [ tr("SMS"), tr("Services"), tr("Weather"),
                            tr("Display"), tr("Modem Reset"), ">>>" ]
                        : [ tr("Reboot"), "", "", "", "", tr("<<< BACK") ]);
                flash_btn(b.x, b.y, b.w, b.h, labels[i - 1] ?? "");
                sock_poll(150);

                if (st.mpg == 1) {
                    switch (i) {
                    case 1: go_page("dashboard"); return;
                    case 2: go_page("wifi"); return;
                    case 3: go_page("lte"); return;
                    case 4: go_page("traffic"); return;
                    case 5: go_page("info"); return;
                    case 6: st.mpg = 2; draw_menu(); return;
                    }
                } else if (st.mpg == 3) {
                    switch (i) {
                    case 1:
                        // Reboot with confirmation dialog
                        lcd_clear("#200000");
                        lcd_rect(30, 60, 260, 120, "#300000");
                        lcd_rect(30, 60, 260, 1, C.red);
                        lcd_text(80, 75, tr("REBOOT?"), C.red, "#300000", 3);
                        lcd_rect(50, 120, 100, 35, C.red);
                        lcd_text(62, 128, tr("YES"), C.white, C.red, 2);
                        lcd_rect(170, 120, 100, 35, "#0841");
                        lcd_text(190, 128, tr("NO"), C.white, "#0841", 2);
                        // Countdown
                        for (let sec = 5; sec > 0; sec--) {
                            lcd_rect(120, 165, 80, 16, "#200000");
                            lcd_text(120, 165, sprintf("(%ds)", sec), C.gray, "#200000", 2);
                            lcd_flush();
                            system("sleep 1");
                            let ct = read_touch();
                            if (ct) {
                                if (ct.x < 160) {
                                    // YES
                                    action_splash(tr("System"), tr("Rebooting..."), C.red);
                                    lcd_flush();
                                    run_script("reboot.sh");
                                    return;
                                } else {
                                    // NO
                                    toast(tr("Cancelled"), C.gray, "#1082", 1);
                                    draw_menu();
                                    return;
                                }
                            }
                        }
                        toast(tr("Cancelled (timeout)"), C.gray, "#1082", 1);
                        draw_menu();
                        return;
                    case 6: st.mpg = 1; draw_menu(); return;
                    }
                } else if (st.mpg == 2) {
                    switch (i) {
                    case 1:
                        st.sms_pg = 0;
                        st.sms_i = -1;
                        sms_refresh();
                        go_page("sms");
                        return;

                    case 2:
                        go_page("services");
                        return;

                    case 3:
                        // Weather: fetch fresh data synchronously, then show the weather page
                        action_splash(tr("Weather"), tr("Updating forecast..."), C.cyan);
                        run_script("weather_fetch.sh");
                        refresh_data();
                        go_page("weather");
                        return;

                    case 4:
                        go_page("display");
                        return;
                    case 5:
                        // Перезапуск модема. Своего скрипта у нас нет, а у
                        // 5gmodem есть отлаженная лестница: питание слота по
                        // GPIO (modem_power/modem_reset/4g/5g1/5g2), затем
                        // деавторизация USB-порта, затем unbind/bind драйвера.
                        // Дублировать её незачем - зовём её же.
                        action_splash("LTE", tr("Resetting modem..."), C.yellow);
                        if (fs.stat("/usr/share/5gmodem/reboot_modem.sh"))
                            system("/usr/share/5gmodem/reboot_modem.sh power >/dev/null 2>&1 &");
                        else
                            run_script("lte_reset.sh");
                        // Wait for script completion (~14 sec)
                        for (let step = 0; step < 7; step++) {
                            system("sleep 2");
                            let msgs = lang() == "ru"
                                ? [ "Отключаю...", "Сброс по GPIO...", "Жду...",
                                    "Поднимаю...", "Жду...", "Проверяю...", "Готово" ]
                                : [ "Disconnecting...", "GPIO reset...", "Waiting...",
                                    "Reconnecting...", "Waiting...", "Checking...", "Done" ];
                            lcd_rect(20, 140, 280, 20, C.bg);
                            lcd_text(20, 140, msgs[step], C.gray, C.bg, 2);
                            lcd_flush();
                        }
                        refresh_data();
                        draw_menu();
                        let u = st.data?.uqmi;
                        let rsrp = int(+(u?.rsrp ?? 0));
                        toast(rsrp < 0 ? sprintf("LTE OK  RSRP:%d", rsrp) : "LTE: no signal",
                              rsrp < 0 ? C.green : C.red,
                              rsrp < 0 ? "#002000" : "#200000", 2);
                        draw_menu();
                        return;
                    case 6:
                        st.mpg = 3;
                        draw_menu();
                        return;
                    }
                }
                draw_menu();
                return;
            }
        }
        return;
    }

    // WiFi page - card touch handling
    // Тап по карточке погоды -> выбор города
    if (st.page == "lte") {
        // Карточка «СИГНАЛ» - вход в подробности о соте.
        let cx = 10 + st.ox, cw = 300, y2 = 28 + st.oy + 52;
        if (in_rect(tx, ty, cx, y2, cw, 64)) {
            st.cpage = 0;
            go_page("cell");
        }
        return;
    }

    if (st.page == "services") {
        // Тап по карточке - проба только этого хоста. Живой отвечает за
        // полсекунды, мёртвый упирается в таймаут, поэтому сначала помечаем
        // карточку жёлтым и показываем это, и только потом ждём результат.
        let hosts = svc_hosts();
        for (let i = 0; i < length(hosts) && i < 6; i++) {
            let b = svc_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                lcd_rect(b.x, b.y, 4, b.h, C.yellow);
                lcd_rect(b.x + b.w - 14, b.y + 8, 8, 8, C.yellow);
                lcd_flush();
                system("/etc/lcd/scripts/svcping.sh " + sh_quote(hosts[i]) + " >/dev/null 2>&1");
                refresh_data();
                draw_services_page();
                return;
            }
        }

        return;
    }

    if (st.page == "cell") {
        let a = cell_arrow(-1), z = cell_arrow(1);
        if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) {
            st.cpage = (st.cpage + CELL_PAGES - 1) % CELL_PAGES;
            draw_cell_page();
            return;
        }
        if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) {
            st.cpage = (st.cpage + 1) % CELL_PAGES;
            draw_cell_page();
            return;
        }
        return;
    }

    if (st.page == "weather") {
        let cx = 10 + st.ox, cw = 300, y1 = 28 + st.oy;
        if (in_rect(tx, ty, cx, y1, cw, 150)) {
            st.wpage = 0;
            go_page("wcity");
        }
        return;
    }

    if (st.page == "display") {
        let cur = saver_cfg();
        let idx = 0;
        for (let i = 0; i < length(SAVER_STEPS); i++)
            if (SAVER_STEPS[i] == cur) idx = i;

        let a = saver_btn(-1), z = saver_btn(1);
        if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) {
            saver_set(SAVER_STEPS[(idx + length(SAVER_STEPS) - 1) % length(SAVER_STEPS)]);
            draw_display_page();
            return;
        }
        if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) {
            saver_set(SAVER_STEPS[(idx + 1) % length(SAVER_STEPS)]);
            draw_display_page();
            return;
        }

        for (let i = 0; i < length(SAVER_STYLES); i++) {
            let sb = style_btn(i);
            if (in_rect(tx, ty, sb.x, sb.y, sb.w, sb.h)) {
                saver_style_set(SAVER_STYLES[i]);
                draw_display_page();
                return;
            }
        }

        for (let i = 0; i < 4; i++) {
            let b = quad_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            switch (i) {
            case 0:
                st.screen = "screensaver";
                st.saver_frame = 0;
                set_blank(true);
                return;
            case 1: burnin_set(!burnin_cfg()); break;
            case 2: night_set("night", night_cfg().on ? "0" : "1"); break;
            case 3: lang_set(lang() == "ru" ? "en" : "ru"); break;
            }
            draw_display_page();
            return;
        }

        let c = night_cfg();
        for (let r = 0; r < 2; r++) {
            let key = r == 0 ? "night_from" : "night_to";
            let val = r == 0 ? c.from : c.to;
            let m = hour_btn(r, -1), pl = hour_btn(r, 1);
            if (in_rect(tx, ty, m.x, m.y, m.w, m.h)) {
                night_set(key, (val + 23) % 24);
                draw_display_page();
                return;
            }
            if (in_rect(tx, ty, pl.x, pl.y, pl.w, pl.h)) {
                night_set(key, (val + 1) % 24);
                draw_display_page();
                return;
            }
        }
        return;
    }

    if (st.page == "wcity") {
        let list = wcity_list();
        let pages = wcity_pages();
        let base = (st.wpage ?? 0) * WCITY_PER_PAGE;
        if (pages > 1) {
            let a = wcity_arrow(-1), z = wcity_arrow(1);
            if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) {
                st.wpage = (st.wpage + pages - 1) % pages;
                draw_wcity_page();
                return;
            }
            if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) {
                st.wpage = (st.wpage + 1) % pages;
                draw_wcity_page();
                return;
            }
        }
        for (let i = 0; i < WCITY_PER_PAGE; i++) {
            let idx = base + i;
            if (idx >= length(list)) break;
            let b = wcity_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                if (!ucur) { toast(tr("uci unavailable"), C.red, "#200000", 2); return; }
                flash_btn(b.x, b.y, b.w, b.h, city_name(list[idx]));
                ucur.set("lcd", "weather", "city", list[idx]);
                ucur.commit("lcd");
                action_splash(tr("Weather"), sprintf(tr("Fetching %s..."), city_name(list[idx])), C.yellow);
                system("/etc/lcd/scripts/weather_fetch.sh >/dev/null 2>&1");
                refresh_data();
                go_page("weather");
                return;
            }
        }
        return;
    }

    if (st.page == "wifi") {
        let ox = st.ox, oy = st.oy;
        let cx = 10 + ox;
        let cw = 300;
        
        // Card 1: 2.4GHz (radio1) (y: 28-108)
        let y1 = 28 + oy;
        let q1 = qr_box(y1);
        if (in_rect(tx, ty, q1.x, q1.y, q1.w, q1.h)
            && ucur && !wifi_is_disabled("radio1", "default_radio1")) {
            st.qr_sec = "default_radio1"; st.qr_band = "2.4 GHz";
            go_page("qr");
            return;
        }
        if (in_rect(tx, ty, cx, y1, cw, 80)) {
            if (ucur) {
                let disabled = wifi_is_disabled("radio1", "default_radio1");
                let new_state = disabled ? "0" : "1";
                
                action_splash("WiFi 2.4GHz", new_state == "0" ? "Enabling..." : "Disabling...", C.green);
                ucur.set("wireless", "radio1", "disabled", new_state);
                ucur.set("wireless", "default_radio1", "disabled", new_state);
                ucur.commit("wireless");
                system("wifi reload");
                system("sleep 3");
                refresh_data();
                toast(new_state == "0" ? "2.4GHz ON" : "2.4GHz OFF", 
                      new_state == "0" ? C.green : C.red,
                      new_state == "0" ? "#002000" : "#200000", 2);
                draw_wifi_page();
            }
            return;
        }
        
        // Card 2: 5GHz (radio0) (y: 114-194)
        let y2 = y1 + 86;
        let q2 = qr_box(y2);
        if (in_rect(tx, ty, q2.x, q2.y, q2.w, q2.h)
            && ucur && !wifi_is_disabled("radio0", "default_radio0")) {
            st.qr_sec = "default_radio0"; st.qr_band = "5 GHz";
            go_page("qr");
            return;
        }
        if (in_rect(tx, ty, cx, y2, cw, 80)) {
            if (ucur) {
                let disabled = wifi_is_disabled("radio0", "default_radio0");
                let new_state = disabled ? "0" : "1";
                
                action_splash("WiFi 5GHz", new_state == "0" ? "Enabling..." : "Disabling...", C.cyan);
                ucur.set("wireless", "radio0", "disabled", new_state);
                ucur.set("wireless", "default_radio0", "disabled", new_state);
                ucur.commit("wireless");
                system("wifi reload");
                system("sleep 3");
                refresh_data();
                toast(new_state == "0" ? "5GHz ON" : "5GHz OFF", 
                      new_state == "0" ? C.green : C.red,
                      new_state == "0" ? "#002000" : "#200000", 2);
                draw_wifi_page();
            }
            return;
        }
    }
}


// =============================================
//  SCREEN STATE MACHINE
// =============================================

function set_screen(s) {
    if (s == st.screen) return;
    st.screen = s;

    if (s == "active") {
        set_blank(false);
        // Из заставки просыпаемся на страницу модема: на неё смотрят чаще
        // всего, а «Сеть» доступна одним тапом из меню.
        st.page = "lte";
        st.mpg = 1;
        refresh_data();
        draw_current();
    } else if (s == "screensaver") {
        st.saver_frame = 0;
        if (saver_style() == "off")
            set_blank(true);
        else
            draw_screensaver();
    }
}

// Запрос от screen.sh (кнопка). Гасим не «на месте», а переводя экран в то же
// состояние, что и заставка «выкл», - иначе перерисовка продолжит долбить шину,
// а тап не разбудит.
function screen_req() {
    let r = fs.readfile(SCREEN_REQ);
    if (!r) return;
    fs.unlink(SCREEN_REQ);
    r = trim(r);
    let off = (r == "off") || (r == "toggle" && !st.blank);
    if (off) {
        st.screen = "screensaver";
        st.saver_frame = 0;
        set_blank(true);
    } else {
        st.ltch = time();
        set_screen("active");
    }
}


// =============================================
//  MAIN
// =============================================

function main() {
    warn(sprintf("lcd_ui: starting (ucode) ubus=%s uci=%s uloop=%s\n",
        uconn ? "OK" : "NO",
        ucur  ? "OK" : "NO",
        uloop_mod ? "OK" : "NO"));

    // Wait for lcd_drv splash logo
    system("sleep 3");

    // Подсветку включаем безусловно и ИМЕННО через светодиод: если демон
    // перезапустили с погашенным экраном, st.blank начнётся с false и сама она
    // уже не включится. Сначала 0, потом 1 - нужен настоящий переход: пин мог
    // остаться поднятым ioctl'ом мимо светодиода (так было до этой правки), и
    // тогда запись того же значения в brightness ничего бы не сделала, а экран
    // «горел и горел» - гашение по таймауту молча превращалось в no-op.
    backlight_write(false);
    backlight_write(true);

    // Stop splash: ioctl(0) via flush
    system("printf '\\0' > /dev/lcd 2>/dev/null");

    // Initial data + draw
    refresh_data();
    draw_dashboard();

    // === uloop event-driven mode ===
    if (uloop_mod) {
        uloop_mod.init();

        // Data refresh + redraw (every 2s)
        let data_t;
        data_t = uloop_mod.timer(T.data * 1000, function() {
            refresh_data();
            if (st.screen == "active")
                draw_current();
            else if (st.screen == "screensaver" && !st.blank)
                draw_screensaver();
            data_t.set(T.data * 1000);
        });

        // Touch polling (every 100ms)
        let touch_t;
        touch_t = uloop_mod.timer(100, function() {
            screen_req();
            let t = read_touch();
            if (t) {
                st.ltch = time();
                if (st.screen != "active")
                    set_screen("active");
                else
                    handle_touch(t.x, t.y);
            }
            // Poll slower when screen is off
            touch_t.set(st.screen == "off" ? 500 : 100);
        });

        // Idle check (every 1s)
        let idle_t;
        idle_t = uloop_mod.timer(1000, function() {
            let idle = time() - st.ltch;
            if (st.screen == "active" && idle >= saver_timeout())
                set_screen("screensaver");
            idle_t.set(1000);
        });

        // Anti-burn-in shift (every 30s)
        let burnin_t;
        burnin_t = uloop_mod.timer(T.burnin * 1000, function() {
            if (burnin_cfg()) {
                st.ox = (st.frame % 3) - 1;
                st.oy = (int(st.frame / 3) % 3) - 1;
                st.frame++;
            } else {
                st.ox = 0; st.oy = 0;
            }
            burnin_t.set(T.burnin * 1000);
        });

        warn("lcd_ui: uloop running\n");
        uloop_mod.run();

    // === Fallback: poll loop ===
    } else {
        warn("lcd_ui: fallback poll loop (no uloop)\n");
        let last_data = 0;
        let last_burnin = time();

        while (true) {
            let now = time();

            // Data refresh
            if (now - last_data >= T.data) {
                refresh_data();
                last_data = now;
            }

            // Touch
            let t = read_touch();
            if (t) {
                st.ltch = now;
                if (st.screen != "active")
                    set_screen("active");
                else
                    handle_touch(t.x, t.y);
            }

            // Idle
            let idle = now - st.ltch;
            if (st.screen == "active" && idle >= saver_timeout())
                set_screen("screensaver");

            // Burn-in
            if (now - last_burnin >= T.burnin) {
                if (burnin_cfg()) {
                    st.ox = (st.frame % 3) - 1;
                    st.oy = (int(st.frame / 3) % 3) - 1;
                    st.frame++;
                } else {
                    st.ox = 0; st.oy = 0;
                }
                last_burnin = now;
            }

            // Redraw
            if (st.screen == "active" && now - st.ldraw >= T.data) {
                draw_current();
                st.ldraw = now;
            } else if (st.screen == "screensaver") {
                draw_screensaver();
            }

            sock_poll(st.screen == "off" ? 500 : 100);
        }
    }
}

// Single run — procd handles respawn on crash
main();
