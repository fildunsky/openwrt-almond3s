#!/usr/bin/ucode
//
// lcd_ui.uc V260401 by Sublimity
//
// Архитектура: uloop (event loop) + ubus (system data) + uci (config)
// Данные: /tmp/lcd_data.json (от сборщика)
// Рендер: JSON через постоянный unix-сокет → рендерер
// Тач: ioctl /dev/lcd (kernel lcd_drv touch thread)
//
// Ставится пакетом в /usr/libexec/almond3s/ui.uc, запускается службой
// /etc/init.d/almond3s-lcd. Вручную: ucode /usr/libexec/almond3s/ui.uc
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
let SCRIPTS = "/etc/almond3s/scripts";  // каталог вспомогательных скриптов

// Цвета (рендерер принимает #RRGGBB, #XXXX в RGB565 и имена)
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
// Фаза анимации зарядки. Объявлена здесь, до всех рисующих функций: в ucode
// функция не видит того, что объявлено ниже неё.
let anim_phase = 0;

// Плавное «докатывание» полосок метрик. Для каждой держим показанную длину и
// подтягиваем её к настоящей: за тик проходим треть остатка, но не меньше
// пикселя, иначе последние доли не доедут никогда.
let bar_disp = {};
let bar_moving = false;

function bar_ease(key, target) {
    let cur = bar_disp[key];
    if (cur == null) { bar_disp[key] = target; return target; }
    if (cur == target) return target;
    let d = target - cur;
    let step = int(d / 3);
    if (step == 0) step = d > 0 ? 1 : -1;
    bar_disp[key] = cur + step;
    bar_moving = true;
    return bar_disp[key];
}

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
    data:   {},        // данные от сборщика
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
    saver_sig: "",     // что нарисовано на заставке (чтобы не перерисовывать зря)
    page_sig:  "",     // то же для обычных страниц
};

// --- Connections ---
let uconn = null;
if (ubus_mod) {
    uconn = ubus_mod.connect();
    if (!uconn) warn("almond3s-lcd: ubus connect failed\n");
}

let ucur = null;
if (uci_mod) ucur = uci_mod.cursor();

// Режим шрифта интерфейса: std - встроенный 5x7, flipper - haxrcorp4089
// из Flipper Zero. Рендер переключается командой fontmode; кэшируем
// значение и шлём его в каждом кадре первой командой - render мог
// перезапуститься и забыть режим.
let FONT_MODE = 0;
function font_load() {
    let v = ucur ? ucur.get("almond3s", "display", "font") : null;
    FONT_MODE = (v == "flipper") ? 1 : 0;
}
font_load();

// ---- Язык интерфейса ----
//
// Ключ словаря - английская строка, значение - русская. Незнакомая строка
// возвращается как есть, поэтому забытый перевод не ломает экран, а просто
// остаётся по-английски. Переводим только то, что видит пользователь:
// форматы чисел, ключи JSON и служебные сообщения в логи - не трогаем.

let LANG = null;

function lang() {
    if (LANG == null)
        LANG = (ucur ? (ucur.get("almond3s", "display", "lang") ?? "ru") : "ru");
    return LANG;
}

function lang_set(v) {
    LANG = v;
    if (ucur) {
        ucur.set("almond3s", "display", "lang", v);
        ucur.commit("almond3s");
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
    "Modem Reset": "Сброс",
    "LTE restart": "модема",
    "Resetting modem...": "Перезапуск модема...",
    "Reboot": "Перезапуск",
    "LED": "Диод",
    "Sound": "Звук",
    "Forget network?": "Забыть сеть?",
    "connecting...": "подключение...",
    "Find network": "Поиск сети",
    "Scanning...": "Сканирую...",
    "No networks found": "Сети не найдены",
    "Tap BACK and retry": "Назад и повторить",
    "+ Find Wi-Fi network": "Подключиться к Wi-Fi",
    "enter password": "введите пароль",
    "space": "пробел",
    "Password": "Пароль",
    "STORAGE AND NETWORK": "ХРАНИЛИЩЕ И СЕТЬ",
    "Flash %.1f of %.1f MB free": "Флеш: свободно %.1f из %.1f МБ",
    "Flash: no data": "Флеш: нет данных",
    "ON": "Вкл",
    "OFF": "Выкл",
    "Screensaver": "Заставка",
    "Date": "Дата",
    "Signal level": "Уровень сигнала",
    "SMS envelope": "Конверт SMS",
    "Clock wander": "Блуждание часов",
    "Clock size": "Размер часов",
    "left ~%dh %02dm": "осталось ~%dч %02dм",
    "drain %.1f ADC/min": "расход %.1f АЦП/мин",
    "drain: measuring": "расход: измеряется",
    "MEASURED LIMITS": "ИЗМЕРЕННЫЕ ПРЕДЕЛЫ",
    "To full charge": "До полного заряда",
    "Time left": "Осталось",
    "estimating": "оцениваю",
    "drain": "расход",
    "ADC/min": "АЦП/мин",
    "measuring": "измеряется",
    "shutdown at %d ADC": "выключение на %d АЦП",
    "discharges in %s": "разрядится за %s",
    "cutoff %d ADC": "отсечка %d АЦП",
    "full %d ADC": "полный %d АЦП",
    "full discharge %dh %02dm": "полный разряд %dч %02dм",
    "Cycle stats will appear here": "Здесь появится статистика циклов",
    "Not joined to any network": "Ни к какой сети не подключён",
    "Modern software needs EZSP 8+": "Современному софту нужен EZSP 8+",
    "UPGRADE PATH": "ПУТЬ ОБНОВЛЕНИЯ",
    "Flash EmberZNet 6.7.10 over SWD": "Прошить EmberZNet 6.7.10 по SWD",
    "header J5705, see ZIGBEE.md": "колодка J5705, детали в ZIGBEE.md",
    "build %s.%s.%s": "сборка %s.%s.%s",
    "build %s": "сборка %s",
    "free RAM %d/%dM": "Свободно ОЗУ %d/%dМБ",
    "free RAM %dM": "Свободно ОЗУ %dМБ",
    ", %d threads": ", %d потока",
    "to full %s": "до полного %s",
    "charging": "идёт зарядка",
    "Plugged in": "Питание от сети",
    "charge complete": "заряд завершён",
    "left %s, %.1f/min": "осталось %s, расход %.1f/мин",
    "drain %.1f/min": "расход %.1f/мин",
    "measuring drain rate": "меряю скорость разряда",
    "raw %s, cutoff %d": "байты %s, отсечка %d",
    "buzzer test": "проверка бипера",
    "Factory tones and volume from stock firmware": "Тоны и громкость из заводской прошивки",
    "Blink on SMS": "Мигать при SMS",
    "above the screen": "над экраном",
    "while unread remain": "пока есть непрочитанные",
    "blinking": "мигает",
    "Blinking: unread SMS": "Мигает: есть непрочитанные SMS",
    "System": "роутера",
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
    "Internet": "Интернет",
    "Reading uplinks...": "Читаю аплинки...",
    "No uplinks": "Аплинков нет",
    "Switching...": "Переключаю...",
    "VIEW": "ВИД",
    "Saver": "Заставка",
    "Night mode": "НОЧНОЙ РЕЖИМ",
    "FONT FLIPPER": "ШРИФТ: FLIPPER",
    "FONT STD": "ШРИФТ: СТАНДАРТ",
    "LIGHT": "ЯРКОСТЬ",
    "Shift": "Сдвиг",
    "Night": "Ночь",
    "NIGHT MODE": "НОЧНОЙ РЕЖИМ",
    "From": "С",
    "To": "ДО",
    "Weather": "Погода",
    "Clock": "Часы",
    "Line": "Строка",
    "Off": "Выкл",
    "Screensaver dims to green at night": "Ночью заставка светится тускло-зелёным",
    "Model": "Модель",
    "Band": "Диапазон",
    "Number": "Номер",
    "SMS": "СМС",
    "inbox": "входящие",
    "%d new": "новых: %d",
    "Reading inbox...": "Читаю ящик...",
    "No messages": "Сообщений нет",
    "BACK": "НАЗАД",
    "Blank": "Погасить",
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
    unshift(cmds, sprintf('{"cmd":"fontmode","mode":%d}', FONT_MODE));
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
// Носик у батарейки слева: значок стоит правее процентов, и так он «смотрит»
// на них, а не в край экрана.
function draw_batt_icon(x, y, w, h, bg, pct, nobat, mono, chg, empty) {
    // Рамка серая; на завершённом заряде - зелёная: это единственный знак,
    // что кабель подключён, когда мигать уже нечему.
    let full_chg = chg && pct >= 100;
    let frame = mono ?? (full_chg ? C.green : C.gray);
    lcd_rect(x, y, w, h, frame);
    lcd_rect(x + 1, y + 1, w - 2, h - 2, bg);
    lcd_rect(x - 2, y + 5, 2, h - 10, frame);
    if (nobat) return;
    let sections = pct > 75 ? 4 : (pct > 50 ? 3 : (pct > 25 ? 2 : (pct > 0 ? 1 : 0)));

    // Зарядка - как у телефонов: набранные деления горят постоянно, а то,
    // которое наполняется сейчас, мигает. Носик слева, поэтому набранные
    // жмутся к правому краю, а наполняемое - первое слева от них.
    let blink_idx = -1;
    if (chg && pct < 100) {
        let full = pct >= 75 ? 3 : (pct >= 50 ? 2 : (pct >= 25 ? 1 : 0));
        sections = full + 1;      // цвет - по наполняемому делению
        blink_idx = 3 - full;
    }

    let sc = mono ?? (sections == 1 ? C.red : (sections == 2 ? C.yellow : C.green));
    let pitch = int((w - 4) / 4);
    let ec = empty ?? C.dim;
    for (let i = 0; i < 4; i++) {
        let on = i >= 4 - sections;
        if (i == blink_idx && (anim_phase % 2) == 1) on = false;
        lcd_rect(x + 3 + i * pitch, y + 2, pitch - 2, h - 4, on ? sc : ec);
    }
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

// ---- Диод над экраном ----
//
// Он не на GPIO, а на PIC: порт E, бит 4. Команды 0x32 (зажечь), 0x31
// (погасить) и 0x30 (мигание) шлёт almond3s-lcd. Мигание живёт в самом
// микроконтроллере, поэтому его достаточно включить один раз.

let led_blinking = false;


function led_cfg() {
    let st_ = ucur ? ucur.get("almond3s", "led", "state") : null;
    let sm = ucur ? ucur.get("almond3s", "led", "sms_blink") : null;
    return {
        on:  (st_ == null || st_ == "") ? true : (st_ == "1"),
        sms: (sm == "1"),
    };
}

// Секции может не быть: /etc/config/lcd - защищённый файл, и на роутерах,
// обновлённых с прежней версии пакета, он остаётся старым. Создаём на месте.
function led_set(key, v) {
    if (!ucur) return;
    if (ucur.get("almond3s", "led") == null)
        ucur.set("almond3s", "led", "led");
    ucur.set("almond3s", "led", key, sprintf("%s", v));
    ucur.commit("almond3s");
}

function led_write(mode) {
    system(sprintf("almond3s-lcd led %s >/dev/null 2>&1", mode));
}

function led_apply() {
    let c = led_cfg();
    led_blinking = false;
    led_write(c.on ? "on" : "off");
}

// Мигание перебивает обычное состояние: уведомление важнее того, что диод
// выключен. Когда непрочитанных не остаётся, возвращаем состояние из настроек.
function led_sms_sync(n) {
    let c = led_cfg();
    if (!c.sms) {
        if (led_blinking) { led_blinking = false; led_write(c.on ? "on" : "off"); }
        return;
    }
    if (n > 0 && !led_blinking) {
        led_blinking = true;
        led_write("blink");
    } else if (n < 1 && led_blinking) {
        led_blinking = false;
        led_write(c.on ? "on" : "off");
    }
}

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
    // Основной источник: JSON от сборщика
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
            led_sms_sync(d.sms_new);
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
            warn(sprintf("almond3s-lcd: weather parse failed: %s\n", e));
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
    // Method 1: read touch file если запущен демон almond3s-lcd (старый путь)
    let raw = fs.readfile(TOUCH_PATH);
    if (raw) {
        fs.unlink(TOUCH_PATH);
        let m = match(trim(raw), /^(\d+)\s+(\d+)/);
        if (m) return { x: +m[1], y: +m[2] };
    }
    // Poll /dev/lcd via the C touch helper
    if (touch_read_ok == null)
        touch_read_ok = (fs.stat("/tmp/almond3s_touch_read") != null);
    if (!touch_read_ok) return null;
    let p = fs.popen("/tmp/almond3s_touch_read 2>/dev/null", "r");
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
// Телефонный ярлык технологии - тот же, что в 5gmodem (mutil.js: ratLabel):
// LTE-A -> 4G+, LTE -> 4G, HSPA -> H+ и так далее. Порядок правил важен:
// «LTE-A» должно проверяться раньше «LTE», иначе останется «4G-A».
let RAT_LABELS = [
    [ /^5G[ -]?SA\b/,  "5G"  ],
    [ /^5G[ -]?NSA\b/, "5G"  ],
    [ /^5G\b/,         "5G"  ],
    [ /^LTE-A\b/,      "4G+" ],
    [ /^LTE\b/,        "4G"  ],
    [ /^HSPA\+/,       "H+"  ],
    [ /^HSPA\b/,       "H+"  ],
    [ /^HSDPA\b/,      "H"   ],
    [ /^HSUPA\b/,      "H"   ],
    [ /^UMTS\b/,       "3G"  ],
    [ /^WCDMA\b/,      "3G"  ],
    [ /^EDGE\b/,       "E"   ],
    [ /^GPRS\b/,       "2G"  ],
    [ /^GSM\b/,        "2G"  ],
];

function rat_label(mv) {
    mv = trim(mv ?? "");
    if (mv == "") return mv;
    for (let r in RAT_LABELS)
        if (match(mv, r[0]))
            return replace(mv, r[0], r[1]);
    return mv;
}

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

// Длительность словами, без сокращений и без «0ч»: «58 минут»,
// «1 час 20 минут». acc - винительный падеж для «за 21 минуту».
function plural_ru(n, one, few, many) {
    let d = n % 100;
    if (d >= 11 && d <= 19) return many;
    d = n % 10;
    if (d == 1) return one;
    if (d >= 2 && d <= 4) return few;
    return many;
}

function fmt_dur(min, acc) {
    let h = int(min / 60), m = min % 60;
    let parts = [];
    if (lang() == "ru") {
        if (h > 0)
            push(parts, sprintf("%d %s", h, plural_ru(h, "час", "часа", "часов")));
        if (m > 0 || h == 0)
            push(parts, sprintf("%d %s", m,
                 plural_ru(m, acc ? "минуту" : "минута", "минуты", "минут")));
    } else {
        if (h > 0)
            push(parts, sprintf("%d %s", h, h == 1 ? "hour" : "hours"));
        if (m > 0 || h == 0)
            push(parts, sprintf("%d %s", m, m == 1 ? "minute" : "minutes"));
    }
    return join(" ", parts);
}

// 5gmodem отдаёт время связи как «0d, 00:17:15». Нулевые старшие разряды
// не показываем, дни пишем словами: «28:52», «3:05:12», «2 дня, 3:05:12».
function conn_fmt(v) {
    v = trim(v ?? "");
    if (v == "" || v == "-") return "";
    let m = match(v, /^([0-9]+)d,\s*([0-9]+):([0-9]+):([0-9]+)/);
    if (!m) return v;
    let d = +m[1], hh = +m[2], mm = +m[3], ss = +m[4];
    let clock = hh > 0 ? sprintf("%d:%02d:%02d", hh, mm, ss)
                       : sprintf("%d:%02d", mm, ss);
    if (d > 0) {
        let w = lang() == "ru" ? plural_ru(d, "день", "дня", "дней")
                               : (d == 1 ? "day" : "days");
        return sprintf("%d %s, %s", d, w, clock);
    }
    return clock;
}

function fmt_uptime(s) {
    s = int(+(s ?? 0));
    let d = int(s / 86400);
    let h = int((s % 86400) / 3600);
    let m = int((s % 3600) / 60);
    if (lang() == "ru") {
        if (d > 0) return sprintf("%d %s %dч %dм", d,
                                  plural_ru(d, "день", "дня", "дней"), h, m);
        if (h > 0) return sprintf("%dч %dм", h, m);
        return sprintf("%dм", m);
    }
    if (d > 0) return sprintf("%d %s %dh %dm", d, d == 1 ? "day" : "days", h, m);
    if (h > 0) return sprintf("%dh %dm", h, m);
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
    let v = ucur ? ucur.get("almond3s", "display", "saver") : null;
    v = (v == null || v == "") ? 300 : int(+v);
    if (v < 0) v = 300;
    return v;
}

function saver_set(v) {
    if (!ucur) return;
    ucur.set("almond3s", "display", "saver", sprintf("%d", v));
    ucur.commit("almond3s");
}

// Сдвиг против выгорания. Раз в 30 секунд на два пикселя было заметно, а
// применяется он не ко всему экрану, а только к тем блокам, что читают
// st.ox/st.oy - поэтому части картинки ползали относительно друг друга.
// Теперь раз в пять минут и на пиксель, и это можно выключить.
// Вид заставки: full - как раньше (часы, дата, погода), clock - только часы
// с уровнем и батареей, line - одна строка как в шапке.
let SAVER_STYLES = [ "full", "clock", "line", "off" ];

function saver_style() {
    let v = ucur ? ucur.get("almond3s", "display", "saver_style") : null;
    for (let x in SAVER_STYLES) if (x == v) return v;
    return "full";
}

// Ночной режим: заставка светится тускло-зелёным, чтобы не бить по глазам в
// темноте. Достался от zipfo жёстко зашитым на 22:00-06:00; теперь это
// настройка - можно выключить или сдвинуть часы.
// Яркость в процентах. Пин один, и владеть им должен драйвер: там живёт ШИМ,
// поэтому и включение, и гашение, и уровень идут одним путём - ioctl'ом через
// almond3s-lcd, а не записью в класс светодиодов.
// Шкала неравномерная нарочно: внизу шаги мельче, потому что там разница
// заметнее глазу, а к максимуму - крупнее.
let BRIGHT_STEPS = [ 10, 20, 30, 50, 70, 85, 100 ];

function bright_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "brightness") : null;
    v = (v == null || v == "") ? 100 : int(+v);
    return clampi(v, 5, 100);
}

function bright_set(pct) {
    if (!ucur) return;
    ucur.set("almond3s", "display", "brightness", sprintf("%d", pct));
    ucur.commit("almond3s");
}

// Разворот экрана на 180: регистр панели MADCTL в драйвере, тач зеркалится
// там же. Здесь только хранение и применение.
function rot_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "rotate") : null;
    return (v == "1");
}

function rot_set(on) {
    if (!ucur) return;
    ucur.set("almond3s", "display", "rotate", on ? "1" : "0");
    ucur.commit("almond3s");
}

function rot_apply() {
    system(sprintf("almond3s-lcd rotate %d >/dev/null 2>&1", rot_cfg() ? 1 : 0));
}

function rot_btn() {
    return { x: 10, y: 36, w: 56, h: 32 };
}

// Круговые стрелки рисуем кольцом с двумя разрывами и стрелками на концах:
// свой глиф в шрифт заводить ради одной кнопки незачем.
function draw_rot_icon(ox, oy, col) {
    // Кольцо с двумя разрывами: сверху справа и снизу слева.
    for (let dy = -7; dy <= 7; dy++)
        for (let dx = -7; dx <= 7; dx++) {
            let d = dx * dx + dy * dy;
            if (d > 45 || d < 24) continue;
            if (dx > 1 && dy < -1) continue;
            if (dx < -1 && dy > 1) continue;
            lcd_rect(ox + 7 + dx, oy + 7 + dy, 1, 1, col);
        }
    // Стрелки: сплошные треугольники в семь пикселей основанием, иначе на
    // такой мелочи они читаются как заусенцы.
    for (let k = 0; k < 4; k++) {
        lcd_rect(ox + 8 + k, oy + 0 + k, 7 - 2 * k, 1, col);       // верх, остриём вниз
        lcd_rect(ox + k, oy + 14 - k, 7 - 2 * k, 1, col);          // низ, остриём вверх
    }
}

// Элементы заставки: что показывать. По умолчанию всё включено.
function svflags() {
    let g = function(k, dflt) {
        let v = ucur ? ucur.get("almond3s", "display", k) : null;
        return (v == null || v == "") ? dflt : (v == "1");
    };
    let sz = ucur ? ucur.get("almond3s", "display", "clock_size") : null;
    return {
        date:   g("sv_date", true),
        sig:    g("sv_signal", true),
        batt:   g("sv_batt", true),
        env:    g("sv_env", true),
        wander: g("sv_wander", false),
        size:   (sz == "s" || sz == "l") ? sz : "m",
    };
}

function svflag_set(key, v) {
    if (!ucur) return;
    ucur.set("almond3s", "display", key, v);
    ucur.commit("almond3s");
}

function night_cfg() {
    let on = ucur ? ucur.get("almond3s", "display", "night") : null;
    let f  = ucur ? ucur.get("almond3s", "display", "night_from") : null;
    let t  = ucur ? ucur.get("almond3s", "display", "night_to") : null;
    return {
        on:   (on == null || on == "") ? true : (on == "1"),
        from: clampi(int(+(f ?? 22)), 0, 23),
        to:   clampi(int(+(t ?? 6)), 0, 23),
    };
}

function night_set(key, v) {
    if (!ucur) return;
    ucur.set("almond3s", "display", key, sprintf("%s", v));
    ucur.commit("almond3s");
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
    ucur.set("almond3s", "display", "saver_style", v);
    ucur.commit("almond3s");
}

function style_btn(i) {
    return { x: 10 + i * 76, y: 96, w: 72, h: 30 };
}

function burnin_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "burnin") : null;
    return (v == null || v == "") ? true : (v == "1");
}

function burnin_set(on) {
    if (!ucur) return;
    ucur.set("almond3s", "display", "burnin", on ? "1" : "0");
    ucur.commit("almond3s");
    if (!on) { st.ox = 0; st.oy = 0; }
}

function saver_timeout() {
    let v = saver_cfg();
    return v > 0 ? v : 999999999;
}

function style_label(v) {
    if (v == "full")  return tr("Weather");
    if (v == "clock") return tr("Clock");
    if (v == "line")  return tr("Line");
    return tr("Off");
}

function saver_label(v) {
    if (v == 0) return "Never";
    if (v < 60) return sprintf(tr("%d sec"), v);
    return sprintf(tr("%d min"), int(v / 60));
}

// Страница «Экран»: карточка таймаута и кнопки шага - три равных блока в ряд.
function saver_box() {
    return { x: 10, y: 32, w: 96, h: 42 };
}

function saver_btn(which) {
    return which > 0 ? { x: 112, y: 32, w: 96, h: 42 }
                     : { x: 214, y: 32, w: 96, h: 42 };
}

function svshift_btn() {
    return { x: 10, y: 150, w: 130, h: 36 };
}

function svnight_btn() {
    return { x: 150, y: 150, w: 160, h: 36 };
}

// Язык - одной кнопкой в правом верхнем углу: флаг и код языка.
function lang_btn() {
    return { x: 236, y: 36, w: 74, h: 32 };
}

function font_btn() {
    return { x: 74, y: 36, w: 154, h: 32 };
}

// Переключатели: гашение, сдвиг, ночь. Состояние показывает цвет полоски,
// поэтому слова «вкл/выкл» на кнопках не нужны.
// Семь шагов в ряд: ряд занимает всю ширину, подпись уезжает строкой выше -
// иначе на кнопку остаётся 28 пикселей, это уже уже пальца.
function bright_btn(i) {
    return { x: 10 + i * 44, y: 118, w: 42, h: 48 };
}

function tog_btn(i) {
    if (i == 0) return { x: 10, y: 64, w: 148, h: 38 };
    return { x: 166, y: 64, w: 144, h: 38 };
}

// Часы «с» и «до» живут на своей странице: две группы «минус - значение - плюс».
function hour_btn(row, which) {
    let y = row == 0 ? 74 : 130;
    if (which < 0) return { x: 96, y: y, w: 52, h: 40 };
    if (which > 0) return { x: 214, y: y, w: 52, h: 40 };
    return { x: 154, y: y, w: 54, h: 40 };
}

function night_btn() {
    return { x: 200, y: 28, w: 110, h: 28 };
}

// Флажок 14x10: у RU три полосы, у EN синее поле с крестом. Рисуем
// прямоугольниками - в шрифте таких символов нет и не будет.
function draw_flag(x, y, code) {
    if (code == "ru") {
        lcd_rect(x, y,     14, 3, "#FFFFFF");
        lcd_rect(x, y + 3, 14, 4, "#0039A6");
        lcd_rect(x, y + 7, 14, 3, "#D52B1E");
    } else {
        lcd_rect(x, y, 14, 10, "#012169");
        lcd_rect(x, y + 4, 14, 2, "#FFFFFF");
        lcd_rect(x + 6, y, 2, 10, "#FFFFFF");
        lcd_rect(x, y + 4, 14, 1, "#C8102E");
        lcd_rect(x + 6, y, 1, 10, "#C8102E");
    }
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

// ОДНА статусная полоса на все экраны. Раньше шапка и заставки рисовали её
// каждая по-своему, и они разъезжались при любой правке. Теперь различия - это
// параметры: на заставке «часы» не нужны время и проценты (часы и так во весь
// экран), в ночном режиме всё рисуется одним зелёным тоном.
function draw_status_row(y, o) {
    let d = st.data;
    let sig = sig_state();
    let bg = o?.bg ?? C.hdr;
    let mono = o?.mono;            /* ночной цвет или null */
    let empty = o?.empty ?? C.dim;

    if (!o?.no_sig) {
        draw_sigbars(4, y, sig.bars, mono ?? sig.color, empty);
        let rat = tcut(rat_label(d?.lte?.mode ?? ""), 4);
        if (rat != "" && rat != "-")
            lcd_text(50, y + 1, rat, mono ?? C.cyan, bg, 2);
    }
    let rat = o?.no_sig ? "" : tcut(rat_label(d?.lte?.mode ?? ""), 4);
    let rat_x = 50;

    let tstr = clock_str();
    let t_x = int((LCD_W - tlen(tstr) * 12) / 2);

    // Конвертик встаёт сразу за ярлыком технологии, поэтому его место зависит
    // от длины ярлыка: «4G» короче, чем «4G+» при агрегации. К часам ближе чем
    // на 8 пикселей не подходит.
    if (!o?.no_env && int(d?.sms_new ?? 0) > 0) {
        let ex = (o?.no_sig ? 4 : rat_x) +
                 (rat == "" || rat == "-" ? 0 : tlen(rat) * 12 + 8);
        if (o?.time && ex + ENV_W + 8 > t_x) ex = t_x - ENV_W - 8;
        draw_env_icon(ex, y, 1, mono ? "#0A2A16" : null, mono);
    }

    if (o?.time)
        lcd_text(t_x, y + 1, tstr, o?.time_color ?? C.white, bg, 2);

    let bat = d?.battery;
    let bchg = bat?.charging && !bat?.no_battery;
    let bpct = int(+(bat?.percent ?? 0));
    let b_w = 32, b_h = 16;
    let bat_x = LCD_W - 4 - b_w;

    if (o?.pct) {
        let bstr = (bat?.no_battery || bpct < 0) ? "" : sprintf("%d", bpct);
        // Последние проценты - красным: предупреждение важнее стиля страницы,
        // поэтому цвет перебивает и ночную заставку.
        let pcol = (bpct <= 5 && !bchg && !bat?.no_battery)
                 ? C.red : (o?.time_color ?? C.white);
        lcd_text(bat_x - 6 - tlen(bstr) * 12, y + 1, bstr, pcol, bg, 2);
    }
    if (!o?.no_batt)
        draw_batt_icon(bat_x, y, b_w, b_h, bg, bpct, bat?.no_battery, mono, bchg, empty);
}

function draw_header(title, bg_c) {
    bg_c ??= C.hdr;
    lcd_rect(0, 0, LCD_W, HDR_H, bg_c);
    draw_status_row(3, { bg: bg_c, time: true, pct: true });
}

function draw_back() {
    lcd_rect(0, BACK_Y, LCD_W, 32, C.back);
    lcd_rect(0, BACK_Y, LCD_W, 2, "#D32F2F"); // top highlight
    lcd_text(120, BACK_Y + 9, tr("< BACK"), C.white, C.back, 2);
}

function draw_btn(idx, title, subtitle, title_c, sub_c, bg_c, middle) {
    let b = btn_pos(idx);
    let bg = bg_c ?? C.btn;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    lcd_rect(b.x, b.y + b.h - 3, b.w, 3, C.border); // internal shadow element
    lcd_text(b.x + 8, b.y + 8, title, title_c ?? C.white, bg, 2);
    if (middle)
        lcd_text(b.x + 8, b.y + 27, tcut(middle, 24), C.white, bg, 1);
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

// =============================================
//  ПРИОРИТЕТ ИНТЕРНЕТА
// =============================================
//
// Своей логики тут нет и не нужно: в 5gmodem есть netpri.sh, который знает про
// базу метрик (100 по умолчанию, 10 при совместимости с mwan3), про зону wan и
// про живое применение маршрутов. Мы только показываем его список и просим
// `set <iface>` по тапу.
//
// Список стоит дорого (обход всех интерфейсов), поэтому зовём его в фоне и
// читаем готовый файл - как со списком SMS.

let NETPRI_CACHE = "/tmp/lcd_netpri.json";
let NETPRI_SH = "/usr/share/5gmodem/netpri.sh";

function netpri_refresh() {
    if (!fs.stat(NETPRI_SH)) return;
    system("(" + NETPRI_SH + " list > " + NETPRI_CACHE + ".new 2>/dev/null" +
           " && mv " + NETPRI_CACHE + ".new " + NETPRI_CACHE + ") >/dev/null 2>&1 &");
}

function netpri_list() {
    let raw = fs.readfile(NETPRI_CACHE);
    if (!raw) return null;
    let j;
    try { j = json(raw); } catch (e) { return null; }
    if (type(j) != "array") return [];
    let out = [];
    for (let e in j)
        if (e?.iface) push(out, e);       /* в хвосте бывает объект события */
    sort(out, function(a, b) {
        return int(+(a.metric ?? 999)) - int(+(b.metric ?? 999));
    });
    return out;
}

function netpri_primary() {
    let l = netpri_list();
    if (type(l) != "array" || length(l) == 0) return "";
    return l[0].label ?? l[0].iface ?? "";
}

// === Wi-Fi STA: скан, выбор сети, подключение ===
//
// Готовый STA-интерфейс уже есть (его настроил 5gmodem как аплинк) - меняем
// в нём ssid/key, а не создаём с нуля. Скан штатный: ubus iwinfo scan. Он
// длится секунды, поэтому запускаем фоном в файл и опрашиваем, а не зовём
// синхронно - иначе интерфейс замрёт.

// Состояние мастера подключения к Wi-Fi. Объявлено до всех рисующих
// функций: в ucode функция не видит того, что объявлено ниже неё.
let sta = { nets: null, sel: -1, pass: "", shift: false, layer: 0, band: 5 };
// Сеть, которую только что попросили подключить: рисуется пунктирной
// карточкой, пока netpri не подхватит реальный аплинк.
let sta_pending = { ssid: null, since: 0 };

let SCAN_OUT = "/tmp/almond3s_scan.json";
let SCAN_DONE = "/tmp/.almond3s_scan_done";
let STA_SECTION = "wifinet2";   // секция STA в /etc/config/wireless

// Беспроводные интерфейсы для скана: по одному «живому» на каждый phy.
function wifi_ifaces() {
    let out = [];
    if (!uconn) return out;
    let st_ = uconn.call("network.wireless", "status", {});
    if (!st_) return out;
    let seen = {};
    for (let dev in st_) {
        let ii = st_[dev]?.interfaces;
        if (type(ii) != "array") continue;
        for (let itf in ii) {
            let ifn = itf?.ifname;
            if (ifn && !exists(seen, dev)) { seen[dev] = true; push(out, ifn); }
        }
    }
    return out;
}

// Радио для диапазона ищем по band в конфиге, а не по имени: на разных
// платах MT7621 radio0 бывает и 5, и 2.4 ГГц - порядок зависит от DTS.
function radio_for_band(band) {
    let want = band == 5 ? "5g" : "2g";
    let dev = null;
    if (ucur)
        ucur.foreach("wireless", "wifi-device", function(sec) {
            if (sec.band == want && dev == null) dev = sec[".name"];
        });
    return dev ?? (band == 5 ? "radio0" : "radio1");
}

function wifi_iface_for(band) {
    if (!uconn) return null;
    let st_ = uconn.call("network.wireless", "status", {});
    let dev = radio_for_band(band);
    let ii = st_?.[dev]?.interfaces;
    if (type(ii) != "array" || length(ii) == 0) return null;
    return ii[0]?.ifname;
}

function wifi_scan_start(band) {
    fs.unlink(SCAN_DONE);
    fs.unlink(SCAN_OUT);
    let one = band ? wifi_iface_for(band) : null;
    let ifs = one ? [ one ] : wifi_ifaces();
    if (length(ifs) == 0) return;
    // Оборачиваем сканы каждого радио в валидный JSON-массив, чтобы прочитать
    // одним json(). Просто конкатенация двух корней даёт невалидный JSON.
    let cmd = sprintf("( echo '{\"scans\":[' > %s.t; ", SCAN_OUT);
    for (let i = 0; i < length(ifs); i++) {
        if (i > 0) cmd += sprintf("echo ',' >> %s.t; ", SCAN_OUT);
        cmd += sprintf("ubus call iwinfo scan '{\"device\":\"%s\"}' >> %s.t 2>/dev/null; ",
                       ifs[i], SCAN_OUT);
    }
    cmd += sprintf("echo ']}' >> %s.t; mv %s.t %s; touch %s ) &",
                   SCAN_OUT, SCAN_OUT, SCAN_OUT, SCAN_DONE);
    system(cmd);
}

// Читает результат скана, если он готов. Возвращает null пока идёт скан,
// иначе массив сетей, отсортированный по сигналу, без дублей и без своей сети.
function wifi_scan_read() {
    if (!fs.stat(SCAN_DONE)) return null;
    let raw = fs.readfile(SCAN_OUT);
    if (!raw) return [];
    let my = ucur ? (ucur.get("wireless", "default_radio0", "ssid") ?? "") : "";
    let best = {};
    let doc;
    try { doc = json(raw); } catch (e) { return []; }
    let scans = doc?.scans;
    if (type(scans) != "array") return [];
    for (let sc in scans) {
        let res = sc?.results;
        if (type(res) != "array") continue;
        for (let n in res) {
            let ss = n?.ssid ?? "";
            if (ss == "" || ss == my) continue;
            let sig = int(+(n?.signal ?? -100));
            if (!exists(best, ss) || sig > best[ss].signal)
                best[ss] = { ssid: ss, signal: sig,
                             band: int(+(n?.band ?? 2)),
                             enc: (n?.encryption?.enabled) ? 1 : 0 };
        }
    }
    let arr = [];
    for (let k in best) push(arr, best[k]);
    // сортировка по сигналу убыванием
    for (let i = 0; i < length(arr); i++)
        for (let jx = i + 1; jx < length(arr); jx++)
            if (arr[jx].signal > arr[i].signal) {
                let t = arr[i]; arr[i] = arr[jx]; arr[jx] = t;
            }
    return arr;
}

// Применяет STA-сеть: пишет ssid/key/шифрование в готовую секцию, ставит
// нужное радио по диапазону и перезагружает сеть.
function sta_apply(ssid, key, band) {
    if (!ucur) return;
    let dev = radio_for_band(band);
    // Секции может не быть: на свежей прошивке STA никто не создавал.
    // uci set в несуществующую секцию молча теряется - создаём сами.
    if (ucur.get("wireless", STA_SECTION) == null)
        ucur.set("wireless", STA_SECTION, "wifi-iface");
    // Интерфейс wwan для STA: без него сеть поднимется, но адреса не получит.
    if (ucur.get("network", "wwan") == null) {
        ucur.set("network", "wwan", "interface");
        ucur.set("network", "wwan", "proto", "dhcp");
        ucur.set("network", "wwan", "metric", "100");
        ucur.commit("network");
    }
    ucur.set("wireless", STA_SECTION, "device", dev);
    ucur.set("wireless", STA_SECTION, "ssid", ssid);
    ucur.set("wireless", STA_SECTION, "mode", "sta");
    ucur.set("wireless", STA_SECTION, "network", "wwan");
    if (key != "") {
        ucur.set("wireless", STA_SECTION, "encryption", "psk2");
        ucur.set("wireless", STA_SECTION, "key", key);
    } else {
        ucur.set("wireless", STA_SECTION, "encryption", "none");
        ucur.delete("wireless", STA_SECTION, "key");
    }
    ucur.set("wireless", STA_SECTION, "disabled", "0");
    ucur.commit("wireless");
    system("ubus call network reload >/dev/null 2>&1 &");
}

function netpri_btn(i) {
    return { x: 10, y: 32 + i * 44, w: 300, h: 40 };
}


function draw_dashboard() {
    lcd_clear(C.bg);
    draw_header(tr("Network"));

    let l = netpri_list();

    // Без 5gmodem списка аплинков взять неоткуда - показываем то же, что и
    // раньше: свой адрес по модему и по кабелю.
    if (!fs.stat(NETPRI_SH)) {
        let d = st.data;
        let rows = [
            [ "WWAN IP (LTE)", d?.lte?.ip ?? d?.uqmi?.ip ?? tr("Disconnected"), "#D2A8FF" ],
            [ "WAN IP (ETH)",  d?.wan_ip ?? tr("Not connected"), C.cyan ],
        ];
        for (let i = 0; i < 2; i++) {
            let b = netpri_btn(i);
            lcd_rect(b.x, b.y, b.w, b.h, C.widget);
            lcd_rect(b.x, b.y, 4, b.h, rows[i][2]);
            lcd_text(b.x + 12, b.y + 6, rows[i][0], C.gray, C.widget, 1);
            lcd_text(b.x + 12, b.y + 20, rows[i][1], C.white, C.widget, 2);
        }
        draw_back();
        lcd_flush();
        return;
    }

    if (l == null) {
        lcd_text(20, 100, tr("Reading uplinks..."), C.gray, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }
    if (length(l) == 0) {
        lcd_text(20, 100, tr("No uplinks"), C.dim, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }

    // Карточка на аплинк: слева цветная полоска (зелёная у основного), имя,
    // тип, справа метрика и адрес. Тап делает аплинк основным.
    for (let i = 0; i < length(l) && i < 3; i++) {
        let e = l[i], b = netpri_btn(i);
        let up = (e.health ?? "") == "up";
        let col = i == 0 ? C.green : (up ? C.cyan : C.dim);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 4, b.h, col);
        lcd_text(b.x + 12, b.y + 5, tcut(e.label ?? e.iface ?? "?", 16),
                 up ? C.white : C.gray, C.widget, 2);
        lcd_text(b.x + 12, b.y + 25, tcut(e.sub ?? e.type ?? "", 24),
                 C.gray, C.widget, 1);
        // У Wi-Fi-аплинка справа зона «забыть сеть»: минус за разделителем.
        // Отступ метрики и адреса одинаковый у всех карточек, чтобы колонка
        // не прыгала между строками.
        let wifi_card = (e.type ?? "") == "wifi";
        let roff = 34;
        if (wifi_card) {
            lcd_rect(b.x + b.w - 34, b.y + 4, 1, b.h - 8, C.border);
            lcd_text(b.x + b.w - 24, b.y + 10, "-", C.red, C.widget, 3);
        }
        let ip = e.ip ?? "";
        if (ip != "")
            lcd_text(b.x + b.w - 10 - roff - tlen(ip) * 6, b.y + 25, ip, C.green, C.widget, 1);
        let m = sprintf("%d", int(+(e.metric ?? 0)));
        lcd_text(b.x + b.w - 10 - roff - tlen(m) * 12, b.y + 5, m,
                 i == 0 ? C.green : C.gray, C.widget, 2);
    }

    // Пунктирная карточка ожидания: сеть подключается, но в netpri ещё не
    // появилась. Гаснет, когда её ssid виден среди аплинков, или через 20 с.
    if (sta_pending.ssid != null) {
        let seen = false;
        if (type(l) == "array")
            for (let e in l)
                if ((e.label ?? "") == sta_pending.ssid || (e.sub ?? "") == sta_pending.ssid)
                    seen = true;
        if (seen || (time() - sta_pending.since) > 20) {
            sta_pending.ssid = null;
        } else {
            let cnt = (type(l) == "array") ? (length(l) < 3 ? length(l) : 3) : 0;
            let py = 32 + cnt * 44;
            if (py + 44 < BACK_Y - 36) {
                // пунктирная рамка
                for (let dx = 0; dx < 300; dx += 6) {
                    lcd_rect(10 + dx, py, 3, 1, C.dim);
                    lcd_rect(10 + dx, py + 39, 3, 1, C.dim);
                }
                for (let dy = 0; dy < 40; dy += 6) {
                    lcd_rect(10, py + dy, 1, 3, C.dim);
                    lcd_rect(309, py + dy, 1, 3, C.dim);
                }
                lcd_text(22, py + 6, tcut(sta_pending.ssid, 18), C.gray, C.bg, 2);
                lcd_text(22, py + 26, tr("connecting..."), C.dim, C.bg, 1);
            }
        }
    }

    // Две кнопки скана - по диапазону, на фиксированном месте над «Назад»,
    // чтобы их положение не зависело от числа аплинков.
    let ny = BACK_Y - 36;
    lcd_rect(10, ny, 145, 30, C.widget);
    lcd_rect(10, ny, 4, 30, C.accent);
    lcd_text(24, ny + 11, "+ Wi-Fi 2.4GHz", C.accent, C.widget, 1);
    lcd_rect(165, ny, 145, 30, C.widget);
    lcd_rect(165, ny, 4, 30, C.accent);
    lcd_text(185, ny + 11, "+ Wi-Fi 5GHz", C.accent, C.widget, 1);

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

// «Открыл - значит прочитал»: ровно так делает страница «Входящие» в 5gmodem
// (readsms.js, обработчик клика по карточке). Учёт общий - тот же seen-add, что
// у страницы и у Telegram-бота, поэтому конвертик гаснет сразу и одинаково
// везде. SMS_MODEM обязателен: у каждого модема свой файл прочитанных.
function sms_mark_read(m) {
    if (!m?.key || !fs.stat("/usr/share/5gmodem/smsbridge.sh")) return;
    let q = function(v) { return "'" + replace(v ?? "", "'", "'\\''") + "'"; };
    system(sprintf("SMS_MODEM=%s /usr/share/5gmodem/smsbridge.sh seen-add %s >/dev/null 2>&1 &",
                   q(m.modem ?? ""), q(m.key)));
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
    let f = phone_fmt(raw);
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
        draw_btn(1, tr("Network"), netpri_primary(), C.white, C.gray);

        // 2: WiFi
        let nc = type(d?.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
        draw_btn(2, tr("WiFi"),
            sprintf(tr("%d clients"), nc),
            C.white, C.gray);

        // 3: Modem
        draw_btn(3, tr("Modem"),
            modem_status(d?.lte),
            C.white, C.gray, null, d?.lte?.operator);

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
        draw_btn(4, tr("Display"), sprintf("%d%%", bright_cfg()), C.white, C.gray);
        draw_btn(5, tr("Saver"), saver_label(saver_cfg()), C.white, C.gray);

        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, tr("MORE >>>"), C.white, C.hdr, 2);

    } else if (st.mpg == 3) {
        let lc = led_cfg();
        draw_btn(1, tr("LED"),
            led_blinking ? tr("blinking") : (lc.on ? tr("on") : tr("off")),
            C.white, (lc.on || led_blinking) ? C.green : C.gray);
        draw_btn(2, tr("Sound"), tr("buzzer test"), C.white, C.gray);
        let bt = st.data?.battery;
        let bp = int(+(bt?.percent ?? -1));
        draw_btn(3, tr("Battery"), bp >= 0 ? sprintf("%d%%", bp) : "--",
                 C.white, bt?.charging ? C.green : C.gray);
        draw_btn(4, "Zigbee", "EM357", C.white, C.gray);

        let b = btn_pos(6);
        lcd_rect(b.x, b.y, b.w, b.h, C.hdr);
        lcd_text(b.x + 20, b.y + 20, tr("MORE >>>"), C.white, C.hdr, 2);

    } else {
        // Последняя страница - только опасные действия: их сложнее
        // нажать случайно по дороге к обычным пунктам.
        draw_btn(1, tr("Modem Reset"), tr("LTE restart"), C.white, "#E8C27A", "#6B4A0F");
        let mb = btn_pos(1);
        lcd_rect(mb.x, mb.y, mb.w, 2, C.yellow);
        draw_btn(2, tr("Reboot"), tr("System"), C.white, "#F0B0B8", C.back);
        let rb = btn_pos(2);
        lcd_rect(rb.x, rb.y, rb.w, 2, "#D32F2F");

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

    // Язык - одной кнопкой сверху справа: флажок и код.
    let rb = rot_btn();
    lcd_rect(rb.x, rb.y, rb.w, rb.h, C.widget);
    draw_rot_icon(rb.x + 21, rb.y + 9, rot_cfg() ? C.green : C.gray);

    let ru = (lang() == "ru");
    let lb = lang_btn();
    lcd_rect(lb.x, lb.y, lb.w, lb.h, C.widget);
    draw_flag(lb.x + 10, lb.y + 11, ru ? "ru" : "en");
    lcd_text(lb.x + 34, lb.y + 9, ru ? "RU" : "EN", C.white, C.widget, 2);

    // Шрифт интерфейса: тап переключает Flipper <-> стандартный.
    let fb = font_btn(), ff = (FONT_MODE == 1);
    lcd_rect(fb.x, fb.y, fb.w, fb.h, C.widget);
    lcd_rect(fb.x, fb.y, 4, fb.h, ff ? C.green : C.border);
    let flab = ff ? tr("FONT FLIPPER") : tr("FONT STD");
    lcd_text(fb.x + int((fb.w - tlen(flab) * 6) / 2) + 2, fb.y + 13, flab,
             ff ? C.white : C.gray, C.widget, 1);

    // Яркость: семь шагов, выбранный подсвечен.
    let bp = bright_cfg();
    lcd_text(12, 102, tr("LIGHT"), C.gray, C.bg, 1);
    for (let i = 0; i < length(BRIGHT_STEPS); i++) {
        let b = bright_btn(i), sel = (BRIGHT_STEPS[i] == bp);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", BRIGHT_STEPS[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 18, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

// Страница «Заставка»: таймаут, вид, сдвиг против выгорания. Тап по виду
// открывает состав элементов и размер часов.
function draw_saver_page() {
    lcd_clear(C.bg);
    draw_header(tr("Screensaver"));

    let sb = saver_box(), a = saver_btn(-1), z = saver_btn(1);
    lcd_rect(sb.x, sb.y, sb.w, sb.h, C.widget);
    lcd_rect(sb.x, sb.y, 4, sb.h, C.cyan);
    lcd_text(sb.x + 10, sb.y + 8, tr("SCREENSAVER AFTER"), C.gray, C.widget, 1);
    lcd_text(sb.x + 10, sb.y + 22, saver_label(saver_cfg()), C.white, C.widget, 2);
    lcd_rect(a.x, a.y, a.w, a.h, C.widget);
    lcd_text(a.x + int(a.w / 2) - 7, a.y + 8, "-", C.accent, C.widget, 4);
    lcd_rect(z.x, z.y, z.w, z.h, C.widget);
    lcd_text(z.x + int(z.w / 2) - 7, z.y + 8, "+", C.accent, C.widget, 4);

    let stl = saver_style();
    lcd_text(12, 84, tr("VIEW"), C.gray, C.bg, 1);
    for (let i = 0; i < length(SAVER_STYLES); i++) {
        let b = style_btn(i), sel = (SAVER_STYLES[i] == stl);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        let t = style_label(SAVER_STYLES[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 11, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    let hb = svshift_btn(), on = burnin_cfg();
    lcd_rect(hb.x, hb.y, hb.w, hb.h, C.widget);
    lcd_rect(hb.x, hb.y, 4, hb.h, on ? C.green : C.dim);
    let ht = tr("Shift");
    lcd_text(hb.x + int((hb.w - tlen(ht) * 12) / 2) + 2, hb.y + 12, ht,
             C.white, C.widget, 2);

    // Ночной режим: зелёная тусклая заставка по расписанию. Тап открывает
    // часы и включает, если был выключен.
    let nb = svnight_btn(), non = night_cfg().on;
    lcd_rect(nb.x, nb.y, nb.w, nb.h, C.widget);
    lcd_rect(nb.x, nb.y, 4, nb.h, non ? C.green : C.dim);
    let nt = tr("Night mode");
    lcd_text(nb.x + int((nb.w - tlen(nt) * 6) / 2) + 2, nb.y + 15, nt,
             C.white, C.widget, 1);

    draw_back();
    lcd_flush();
}

// Часы ночного режима - отдельной страницей: открывается тапом по «Ночь».
function led_row(i) {
    return { x: 20, y: 44 + i * 56, w: 280, h: 44 };
}

// Звуки бипера. Каждый - список пар «частота длительность», их играет
// almond3s-lcd: загрузка таблицы в PIC занимает около секунды, поэтому зовём
// его фоном, иначе интерфейс замирал бы на каждое нажатие.
let SOUNDS = [
    { label: "звонок",  name: "bell",  args: "" },
    { label: "скорая",  name: "ambulance", args: "" },
    { label: "полиция", name: "police", args: "" },
    { label: "мелодия", name: "melody", args: "" },
    { label: "марш",    name: "tone",
      args: "440 500 440 500 440 500 349 375 523 125 440 500 349 375 523 125 440 650" },
    { label: "сирена",  name: "siren", args: "" },
    { label: "гр 1",    name: "vol", args: "1" },
    { label: "гр 2",    name: "vol", args: "2" },
    { label: "гр 3",    name: "vol", args: "3" },
    { label: "звонок-",  name: "tone", args: "988 130 988 267 838 130 838 535" },
    { label: "звонок--", name: "tone", args: "494 130 494 267 419 130 419 535" },
    { label: "стоп",    name: "tone", args: "0 1" },
];

// Выбранный уровень громкости запоминается и подставляется следующему звуку:
// сама команда 0x34 не переживает сброса шины в начале последовательности.
let snd_vol = 1;

function snd_btn(i) {
    return { x: 6 + (i % 3) * 104, y: 30 + int(i / 3) * 44, w: 100, h: 40 };
}

function snd_play(i) {
    let e = SOUNDS[i];
    if (e.name == "vol") {
        snd_vol = int(e.args);
        return;
    }
    let v = snd_vol > 0 ? sprintf(" -v %d", snd_vol) : "";
    let a = e.args != "" ? " " + e.args : "";
    system(sprintf("almond3s-lcd %s%s%s >/dev/null 2>&1 &", e.name, v, a));
}

function draw_sound_page() {
    lcd_clear(C.bg);
    draw_header(tr("Sound"));
    for (let i = 0; i < length(SOUNDS); i++) {
        let b = snd_btn(i), last = (i == length(SOUNDS) - 1);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        let vol_sel = (SOUNDS[i].name == "vol" && int(SOUNDS[i].args) == snd_vol);
        lcd_rect(b.x, b.y, 4, b.h,
                 last ? C.red
                      : (SOUNDS[i].name == "vol" ? (vol_sel ? C.green : C.yellow)
                                                 : (i < 6 ? C.cyan : C.gray)));
        let t = SOUNDS[i].label;
        lcd_text(b.x + int((b.w - tlen(t) * 12) / 2), b.y + 12, t, C.white, C.widget, 2);
    }
    lcd_text(10, 214, tr("Factory tones and volume from stock firmware"), C.dim, C.bg, 1);
    draw_back();
    lcd_flush();
}

let SAVERCFG_ROWS = [
    { key: "sv_date",   label: "Date" },
    { key: "sv_signal", label: "Signal level" },
    { key: "sv_batt",   label: "Battery" },
    { key: "sv_env",    label: "SMS envelope" },
    { key: "sv_wander", label: "Clock wander" },
];

function savercfg_row(i) {
    return { x: 10, y: 30 + i * 30, w: 300, h: 26 };
}

function savercfg_size_btn(i) {
    return { x: 118 + i * 68, y: 30 + 5 * 30, w: 60, h: 26 };
}

// Показываем только то, что в выбранном стиле вообще есть: у «строки» нет
// даты, блуждание и размер - только у «часов».
function savercfg_rows_for_style() {
    let stl = saver_style();
    let rows = [];
    for (let r in SAVERCFG_ROWS) {
        if (r.key == "sv_date" && stl == "line") continue;
        if (r.key == "sv_wander" && stl != "clock") continue;
        push(rows, r);
    }
    return rows;
}

function draw_savercfg_page() {
    lcd_clear(C.bg);
    draw_header(sprintf("%s: %s", tr("Screensaver"), style_label(saver_style())));
    let fl = svflags();
    let v = { sv_date: fl.date, sv_signal: fl.sig, sv_batt: fl.batt,
              sv_env: fl.env, sv_wander: fl.wander };
    let rows = savercfg_rows_for_style();
    for (let i = 0; i < length(rows); i++) {
        let b = savercfg_row(i);
        let on = v[rows[i].key];
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 4, b.h, on ? C.green : C.dim);
        lcd_text(b.x + 12, b.y + 7, tr(rows[i].label), C.white, C.widget, 1);
        lcd_text(b.x + b.w - 40, b.y + 7, on ? tr("on") : tr("off"),
                 on ? C.green : C.gray, C.widget, 1);
    }
    if (saver_style() == "clock") {
        let yb = 30 + length(rows) * 30;
        lcd_text(10, yb + 7, tr("Clock size"), C.gray, C.bg, 1);
        let names = [ "S", "M", "L" ], keys = [ "s", "m", "l" ];
        for (let i = 0; i < 3; i++) {
            let b = savercfg_size_btn(i), sel = fl.size == keys[i];
            b.y = yb;
            lcd_rect(b.x, b.y, b.w, b.h, C.widget);
            lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
            lcd_text(b.x + int(b.w / 2) - 6, b.y + 5, names[i],
                     sel ? C.white : C.gray, C.widget, 2);
        }
    }
    draw_back();
    lcd_flush();
}


function stascan_row(i) {
    return { x: 10, y: 30 + i * 30, w: 300, h: 26 };
}

function draw_stascan_page() {
    lcd_clear(C.bg);
    draw_header(sprintf("%s %s", tr("Find network"), sta.band == 5 ? "5GHz" : "2.4GHz"));

    let nets = sta.nets;
    if (nets == null) {
        lcd_text(20, 100, tr("Scanning..."), C.gray, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }
    if (length(nets) == 0) {
        lcd_text(20, 100, tr("No networks found"), C.dim, C.bg, 2);
        lcd_text(20, 124, tr("Tap BACK and retry"), C.dim, C.bg, 1);
        draw_back();
        lcd_flush();
        return;
    }
    // До шести сетей на экран, самые сильные сверху.
    for (let i = 0; i < length(nets) && i < 6; i++) {
        let n = nets[i], b = stascan_row(i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        let bars = n.signal > -55 ? 3 : (n.signal > -70 ? 2 : 1);
        let bc = bars == 3 ? C.green : (bars == 2 ? C.yellow : C.red);
        lcd_rect(b.x, b.y, 4, b.h, bc);
        lcd_text(b.x + 12, b.y + 7, tcut(n.ssid, 22), C.white, C.widget, 1);
        let tag = sprintf("%dG%s", n.band, n.enc ? " *" : "");
        lcd_text(b.x + b.w - 12 - tlen(tag) * 6, b.y + 7, tag,
                 n.enc ? C.gray : C.cyan, C.widget, 1);
    }
    draw_back();
    lcd_flush();
}

// QWERTY: три слоя (буквы/цифры/символы), Shift для регистра. Пароли Wi-Fi
// бывают любыми, поэтому нужен полный набор.
let KBD = [
    [ "qwertyuiop", "asdfghjkl", "zxcvbnm" ],
    [ "1234567890", "-_.@!#%&*", "+=/:;,?~" ],
];

function kbd_key(r, c, cols) {
    let kw = int((LCD_W - 8) / 10);
    let x = 4 + c * kw;
    let y = 92 + r * 28;
    return { x: x, y: y, w: kw - 2, h: 26 };
}

function draw_kbd_page() {
    lcd_clear(C.bg);
    let n = sta.sel >= 0 ? sta.nets[sta.sel] : null;
    draw_header(tcut(n ? n.ssid : tr("Password"), 24));

    // Поле ввода: показываем пароль точками, последний символ открыт.
    lcd_rect(10, 30, 300, 30, C.widget);
    let shown = "";
    let pl = length(sta.pass);
    for (let i = 0; i < pl; i++)
        shown += (i == pl - 1) ? substr(sta.pass, i, 1) : "*";
    lcd_text(18, 38, shown != "" ? shown : tr("enter password"),
             shown != "" ? C.white : C.dim, C.widget, 2);

    let rows = KBD[sta.layer];
    for (let r = 0; r < length(rows); r++) {
        let chars = rows[r];
        let ncols = length(chars);
        let off = int((10 - ncols) / 2);
        for (let c = 0; c < ncols; c++) {
            let b = kbd_key(r, off + c, ncols);
            let ch = substr(chars, c, 1);
            if (sta.shift && sta.layer == 0) ch = uc(ch);
            lcd_rect(b.x, b.y, b.w, b.h, C.widget);
            lcd_text(b.x + int(b.w / 2) - 3, b.y + 6, ch, C.white, C.widget, 2);
        }
    }
    // Нижний ряд: Shift/слой, пробел, стереть, готово.
    let by = 92 + 3 * 28;
    let specs = [
        { l: sta.layer == 0 ? "123" : "abc", k: "layer", w: 44, c: C.cyan },
        { l: sta.shift ? "ABC" : "abc", k: "shift", w: 44, c: sta.shift ? C.green : C.gray },
        { l: tr("space"), k: "space", w: 96, c: C.gray },
        { l: "<-", k: "del", w: 44, c: C.yellow },
        { l: "OK", k: "ok", w: 60, c: C.green },
    ];
    let sx = 4;
    for (let i = 0; i < length(specs); i++) {
        let sp = specs[i];
        lcd_rect(sx, by, sp.w, 26, C.widget);
        lcd_rect(sx, by, 3, 26, sp.c);
        lcd_text(sx + 8, by + 6, sp.l, C.white, C.widget, 1);
        sp.x = sx;
        sx += sp.w + 2;
    }
    sta.specs = specs;
    sta.spec_y = by;
    lcd_flush();
}

function draw_battery_page() {
    let bat = st.data?.battery ?? {};
    lcd_clear(C.bg);
    draw_header(tr("Battery"));

    let cx = 10, cw = 300;
    let pct = int(+(bat?.percent ?? -1));
    let adc = int(+(bat?.adc ?? 0));
    let chg = bat?.charging && !bat?.no_battery;
    let full = chg && pct >= 100;
    // Состояние: уровень крупно слева, статус и АЦП по правому краю.
    let y1 = 28;
    lcd_rect(cx, y1, cw, 50, C.widget);
    let pcol = pct < 0 ? C.dim : (pct <= 5 && !chg ? C.red : (pct <= 25 ? C.yellow : C.green));
    lcd_rect(cx, y1, 4, 50, pcol);
    lcd_text(cx + 12, y1 + 10, pct < 0 ? "--" : sprintf("%d%%", pct), pcol, C.widget, 3);
    let st_s = bat?.no_battery ? tr("Battery not installed")
             : (full ? tr("Plugged in") : (chg ? tr("Charging") : tr("Battery")));
    lcd_text(cx + cw - 12 - tlen(st_s) * 6, y1 + 10, st_s, C.white, C.widget, 1);
    let adc_s = sprintf(tr("ADC %d"), adc);
    lcd_text(cx + cw - 12 - tlen(adc_s) * 6, y1 + 26, adc_s, C.gray, C.widget, 1);

    // Прогноз: слева подпись и время, справа расход.
    let y2 = y1 + 56;
    lcd_rect(cx, y2, cw, 40, C.widget);
    lcd_rect(cx, y2, 4, 40, C.cyan);
    let cap = full ? tr("charge complete")
            : (chg ? tr("To full charge") : tr("Time left"));
    let rmin = int(+(bat?.remain_min ?? -1));
    let tstr = full ? "" : (rmin > 0 ? fmt_dur(rmin, false) : tr("estimating"));
    lcd_text(cx + 12, y2 + 8, cap, C.white, C.widget, 1);
    if (tstr != "")
        lcd_text(cx + 12, y2 + 22, tstr, C.gray, C.widget, 1);
    let drain = +(bat?.drain_rate ?? 0);
    let d1 = tr("drain");
    let d2 = drain > 0 ? sprintf("%.1f %s", drain, tr("ADC/min")) : tr("measuring");
    lcd_text(cx + cw - 12 - tlen(d1) * 6, y2 + 8, d1, C.white, C.widget, 1);
    lcd_text(cx + cw - 12 - tlen(d2) * 6, y2 + 22, d2, C.gray, C.widget, 1);

    // Пределы этой платы, измеренные на живых циклах.
    let y3 = y2 + 46;
    lcd_rect(cx, y3, cw, 52, C.widget);
    lcd_rect(cx, y3, 4, 52, C.gray);
    lcd_text(cx + 12, y3 + 6, tr("MEASURED LIMITS"), C.gray, C.widget, 1);
    lcd_text(cx + 12, y3 + 20, sprintf(tr("shutdown at %d ADC"), int(+(bat?.cutoff ?? 512))), C.white, C.widget, 1);
    let f_s = sprintf(tr("full %d ADC"), 726);
    lcd_text(cx + cw - 12 - tlen(f_s) * 6, y3 + 20, f_s, C.white, C.widget, 1);
    lcd_text(cx + 12, y3 + 34, sprintf(tr("discharges in %s"), fmt_dur(263, true)), C.white, C.widget, 1);

    lcd_text(cx + 2, y3 + 62, tr("Cycle stats will appear here"), C.dim, C.bg, 1);

    draw_back();
    lcd_flush();
}

function draw_zigbee_page() {
    lcd_clear(C.bg);
    draw_header("Zigbee");

    let cx = 10, cw = 300;
    let y1 = 28;
    lcd_rect(cx, y1, cw, 50, C.widget);
    lcd_rect(cx, y1, 4, 50, C.accent);
    lcd_text(cx + 12, y1 + 6, "Silicon Labs EM357", C.white, C.widget, 1);
    lcd_text(cx + 12, y1 + 20, "EZSP v4, EmberZNet 5.1.0", C.gray, C.widget, 1);
    lcd_text(cx + 12, y1 + 34, "/dev/ttyS2, 57600 8N1", C.gray, C.widget, 1);

    let y2 = y1 + 56;
    lcd_rect(cx, y2, cw, 40, C.widget);
    lcd_rect(cx, y2, 4, 40, C.yellow);
    lcd_text(cx + 12, y2 + 8, tr("Not joined to any network"), C.white, C.widget, 1);
    lcd_text(cx + 12, y2 + 22, tr("Modern software needs EZSP 8+"), C.gray, C.widget, 1);

    let y3 = y2 + 46;
    lcd_rect(cx, y3, cw, 52, C.widget);
    lcd_rect(cx, y3, 4, 52, C.gray);
    lcd_text(cx + 12, y3 + 6, tr("UPGRADE PATH"), C.gray, C.widget, 1);
    lcd_text(cx + 12, y3 + 20, tr("Flash EmberZNet 6.7.10 over SWD"), C.white, C.widget, 1);
    lcd_text(cx + 12, y3 + 34, tr("header J5705, see ZIGBEE.md"), C.gray, C.widget, 1);

    draw_back();
    lcd_flush();
}

function draw_led_page() {
    lcd_clear(C.bg);
    draw_header(tr("LED"));

    let c = led_cfg();
    let rows = [
        { label: tr("LED"),          on: c.on,  hint: tr("above the screen") },
        { label: tr("Blink on SMS"), on: c.sms, hint: tr("while unread remain") },
    ];
    for (let i = 0; i < length(rows); i++) {
        let r = rows[i], b = led_row(i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 4, b.h, r.on ? C.green : C.dim);
        lcd_text(b.x + 16, b.y + 6, r.label, C.white, C.widget, 2);
        lcd_text(b.x + 16, b.y + 28, r.hint, C.dim, C.widget, 1);
        lcd_text(b.x + b.w - 46, b.y + 14, r.on ? tr("on") : tr("off"),
                 r.on ? C.green : C.gray, C.widget, 2);
    }

    if (led_blinking)
        lcd_text(20, 168, tr("Blinking: unread SMS"), C.green, C.bg, 1);

    draw_back();
    lcd_flush();
}

function draw_night_page() {
    lcd_clear(C.bg);
    draw_header(tr("Display"));

    let c = night_cfg();
    lcd_text(20, 36, tr("NIGHT MODE"), C.gray, C.bg, 1);
    let nb = night_btn();
    lcd_rect(nb.x, nb.y, nb.w, nb.h, C.widget);
    lcd_rect(nb.x, nb.y, 4, nb.h, c.on ? C.green : C.dim);
    lcd_text(nb.x + 30, nb.y + 6, c.on ? tr("on") : tr("off"),
             c.on ? C.white : C.gray, C.widget, 2);

    let hcol = c.on ? C.white : C.dim;
    for (let r = 0; r < 2; r++) {
        let m = hour_btn(r, -1), vb = hour_btn(r, 0), pl = hour_btn(r, 1);
        let hv = sprintf("%02d", r == 0 ? c.from : c.to);
        lcd_text(24, vb.y + 16, r == 0 ? tr("From") : tr("To"), C.gray, C.bg, 2);
        lcd_rect(m.x, m.y, m.w, m.h, C.widget);
        lcd_text(m.x + 18, m.y + 10, "-", C.accent, C.widget, 4);
        lcd_rect(vb.x, vb.y, vb.w, vb.h, C.widget);
        lcd_text(vb.x + int((vb.w - tlen(hv) * 18) / 2), vb.y + 8, hv, hcol, C.widget, 3);
        lcd_rect(pl.x, pl.y, pl.w, pl.h, C.widget);
        lcd_text(pl.x + 18, pl.y + 10, "+", C.accent, C.widget, 4);
    }

    lcd_text(20, 184, tr("Screensaver dims to green at night"), C.dim, C.bg, 1);

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
        let l = ucur.get("almond3s", "services", "host");
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
        
        // Пароль на экране не показываем: длинный ключ не помещается, а
        // для подключения есть QR - он и есть пароль.
        lcd_text(cx + 10, y1 + 22, tcut(ssid_2g, 20), C.white, C.widget, 2);
        
        // Count clients on 2.4GHz
        let clients_2g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "2G" || cl.band == "2.4G") clients_2g++;
            }
        }
        lcd_text(cx + 10, y1 + 48, sprintf(tr("Clients: %d"), clients_2g), C.cyan, C.widget, 2);
        
        let status_2g = disabled_2g ? tr("OFF") : tr("ON");
        let status_c_2g = disabled_2g ? C.gray : C.green;
        lcd_text(cx + 160, y1 + 48, status_2g, status_c_2g, C.widget, 2);
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
        
        lcd_text(cx + 10, y2 + 22, tcut(ssid_5g, 20), C.white, C.widget, 2);
        
        // Count clients on 5GHz
        let clients_5g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "5G" || cl.band == "5GHz") clients_5g++;
            }
        }
        lcd_text(cx + 10, y2 + 48, sprintf(tr("Clients: %d"), clients_5g), C.cyan, C.widget, 2);
        
        let status_5g = disabled_5g ? tr("OFF") : tr("ON");
        let status_c_5g = disabled_5g ? C.gray : C.green;
        lcd_text(cx + 160, y2 + 48, status_5g, status_c_5g, C.widget, 2);
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

    // Версия драйвера - дата сборки, отдаётся ioctl'ом через almond3s-lcd.
    let drv_ver = "?";
    let p = fs.popen("almond3s-lcd version 2>/dev/null", "r");
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
    lcd_text(cx + 10, y1 + 20, hw != "" ? hw : "?", C.white, C.widget, 1);
    // Заряд одной строкой: подробности на странице «Батарея», но общий
    // взгляд на роутер без процентов был бы слепым.
    if (!bat?.no_battery && bpct >= 0) {
        let b1 = sprintf("%d%%", bpct);   // зарядку выдаёт зелёный цвет: молнии в шрифте нет
        let b1c = bpct <= 5 && !bat?.charging ? C.red : (bat?.charging ? C.green : C.white);
        lcd_text(cx + cw - 10 - tlen(b1) * 6, y1 + 20, b1, b1c, C.widget, 1);
    }
    lcd_text(cx + 10, y1 + 32, sprintf(tr("Uptime %s"), fmt_uptime(d?.uptime)), C.white, C.widget, 1);

    // Свободную память прижимаем к правому краю карточки: строка длинная,
    // а слева уже стоит время работы.
    let mfree = int(+(d?.mem_free_mb ?? 0));
    let mtot  = int(+(d?.mem_total_mb ?? 0));
    let mstr = mtot > 0 ? sprintf(tr("free RAM %d/%dM"), mfree, mtot)
                        : sprintf(tr("free RAM %dM"), mfree);
    lcd_text(cx + cw - 10 - tlen(mstr) * 6, y1 + 32, mstr, C.green, C.widget, 1);

    let busy = int(+(d?.cpu_busy ?? -1));
    let cores = int(+(d?.cpu_cores ?? 0));
    let cstr = sprintf(tr("CPU %s"), load);
    if (busy >= 0) cstr += sprintf(", %d%%", busy);
    if (cores > 0) cstr += sprintf(tr(", %d threads"), cores);
    lcd_text(cx + 10, y1 + 44, cstr, C.accent, C.widget, 1);

    // Card 2: Power
    let y2 = y1 + 58;
    lcd_rect(cx, y2, cw, 52, C.widget);
    lcd_rect(cx, y2, 4, 52, C.cyan);
    lcd_text(cx + 10, y2 + 6, tr("STORAGE AND NETWORK"), C.gray, C.widget, 1);

    // Флеш: свободно из всего, с полосой занятости справа.
    let so = d?.storage;
    let s_free = int(+(so?.free_kb ?? 0)), s_tot = int(+(so?.total_kb ?? 0));
    if (s_tot > 0) {
        lcd_text(cx + 10, y2 + 20,
                 sprintf(tr("Flash %.1f of %.1f MB free"), s_free / 1024.0, s_tot / 1024.0),
                 C.white, C.widget, 1);
        let bw = 56, bx = cx + cw - 10 - bw;
        let used = int(bw * (s_tot - s_free) / s_tot);
        lcd_rect(bx, y2 + 20, bw, 7, C.dim);
        if (used > 0)
            lcd_rect(bx, y2 + 20, used, 7,
                     used > bw * 8 / 10 ? C.red : C.green);
    } else {
        lcd_text(cx + 10, y2 + 20, tr("Flash: no data"), C.dim, C.widget, 1);
    }

    let lan = d?.lan;
    lcd_text(cx + 10, y2 + 34, sprintf("LAN %s", lan?.ip ?? "?"), C.accent, C.widget, 1);
    let mac_s = uc(lan?.mac ?? "");
    if (mac_s != "")
        lcd_text(cx + cw - 10 - tlen(mac_s) * 6, y2 + 34, mac_s, C.gray, C.widget, 1);

    // Card 3: Software
    let y3 = y2 + 58;
    lcd_rect(cx, y3, cw, 52, C.widget);
    lcd_rect(cx, y3, 4, 52, "#D2A8FF");
    lcd_text(cx + 10, y3 + 6, tr("SOFTWARE"), C.gray, C.widget, 1);
    lcd_text(cx + 10, y3 + 20, sprintf("OpenWrt %s", board?.release?.version ?? "?"), C.white, C.widget, 1);
    let kstr = sprintf(tr("Kernel %s"), board?.kernel ?? "?");
    lcd_text(cx + cw - 10 - tlen(kstr) * 6, y3 + 20, kstr, C.dim, C.widget, 1);

    // Драйвер отдаёт дату сборки как 2026-08-13 - показываем по-русски.
    let dv = drv_ver;
    let dm = match(dv, /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/);
    dv = dm ? sprintf(tr("build %s.%s.%s"), dm[3], dm[2], dm[1]) : sprintf(tr("build %s"), dv);
    // Имя драйвера слева цветом, дата сборки - в правый серый столбец
    // между ядром и ссылкой.
    lcd_text(cx + 10, y3 + 32, "kmod-lcd-almond3s", C.accent, C.widget, 1);
    lcd_text(cx + cw - 10 - tlen(dv) * 6, y3 + 32, dv, C.dim, C.widget, 1);
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
        let l = ucur.get("almond3s", "weather", "choices");
        if (type(l) == "array" && length(l) > 0) return l;
    }
    return WCITY_DEFAULT;
}

function wcity_pages() {
    let t = length(wcity_list());
    return t > 0 ? int((t + WCITY_PER_PAGE - 1) / WCITY_PER_PAGE) : 1;
}

function wcity_current() {
    return (ucur ? ucur.get("almond3s", "weather", "city") : null) ?? "Moscow";
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
    let fill = bar_ease(key, int(bw * clampi(m.bar(v), 0, 100) / 100));
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
    let mode_s = rat_label(l.mode ?? "-");
    if (nca > 1) mode_s += sprintf(" %dCA", nca);
    lcd_text(rx(mode_s), y1 + 5, mode_s, C.cyan, C.widget, 1);

    lcd_text(LX1, y1 + 19, tr("Band"), C.gray, C.widget, 1);
    let band = l.band ?? "";
    if (band != "" && band != "-")     /* модем не сказал - оставляем пусто */
        lcd_text(VX1, y1 + 19, tcut(band, 15), C.accent, C.widget, 1);

    if (temp > 0) {
        let tc = temp >= 70 ? C.red : (temp >= 55 ? C.yellow : C.white);
        let ts = sprintf("%d°C%s", temp, int(+(l.therm ?? 0)) > 0 ? " !" : "");
        lcd_text(rx(ts), y1 + 19, ts, tc, C.widget, 1);
    } else {
        lcd_text(rx("-"), y1 + 19, "-", C.dim, C.widget, 1);
    }

    // Третья строка без подписей: слева оператор, справа номер симки. Обоим
    // подпись не нужна - и так понятно, что это.
    let phone = phone_fmt(l.phone);
    let oper = l.operator ?? "";
    if (oper != "" && oper != "-")
        lcd_text(LX1, y1 + 33, tcut(oper, 16), C.white, C.widget, 1);
    if (phone != "")
        lcd_text(rx(phone), y1 + 33, phone, C.white, C.widget, 1);

    // Слот и роуминг прижимаем тем же краем, но цвета разные - поэтому считаем
    // ширину пары целиком, а рисуем двумя кусками.
    // Слот и роуминг переезжают к диапазону: третью строку занял номер.
    let slot = int(+(l.simslot ?? 0));
    let sim_s = slot > 0 ? sprintf(tr("SIM %d"), slot) : "";
    let roam_s = int(+(l.roaming ?? 0)) > 0 ? tr("ROAM") : "";
    if (roam_s != "") {
        lcd_text(VX1 + 96, y1 + 19, roam_s, C.yellow, C.widget, 1);
    } else if (sim_s != "") {
        lcd_text(VX1 + 96, y1 + 19, sim_s, C.gray, C.widget, 1);
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
    // Вверху опознаватели соты, внизу параметры радио - по два значения в
    // строке, слева и справа.
    lcd_text(cx + 10, y3 + 18, cell_id("PCI", u?.pci), C.white, C.widget, 1);
    lcd_text(rx(enb_s), y3 + 18, enb_s, C.white, C.widget, 1);
    lcd_text(cx + 10, y3 + 30, earf_s, C.white, C.widget, 1);

    let mcc = int(+(u?.mcc ?? 0)), mnc = int(+(u?.mnc ?? 0));
    let plmn_name = get_plmn_name(mcc, mnc);
    // Оператора не повторяем - он уже в верхней карточке. Имя из таблицы
    // PLMN дописываем только если модем рапортует другое: у виртуальных
    // операторов имя сети и владелец частот не совпадают, и вот это уже
    // стоит показать.
    if (mcc > 0) {
        let oper = lc(trim(l.operator ?? ""));
        let plmn_s = sprintf("%d-%02d", mcc, mnc);
        if (plmn_name && lc(plmn_name) != oper)
            plmn_s += " " + plmn_name;
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

// Подпись того, что СЕЙЧАС показано на странице. Если она не изменилась,
// перерисовывать нечего: кадр уйдёт байт в байт такой же, а это лишняя работа
// интерфейса, лишние 150 КБ в драйвер и лишний повод мигнуть подсветкой.
// Незнакомая страница возвращает уникальную подпись - значит рисуем всегда.
function page_sig() {
    let d = st.data ?? {}, l = d.lte ?? {}, u = d.uqmi ?? {};
    let nc = type(d.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
    let base = sprintf("%s|%d|%s|%d", st.page, st.mpg, clock_str(),
                       int(+(d.sms_new ?? 0)));
    switch (st.page) {
    case "dashboard":
        return base + sprintf("|%J|%s|%s", netpri_list(), l.ip ?? "", d.wan_ip ?? "");
    case "menu":
        return base + sprintf("|%s|%d|%s|%s", modem_status(l), nc,
                              fmt_uptime(d.uptime), saver_label(saver_cfg()));
    case "lte":
    case "cell":
        return base + sprintf("|%J|%J", l, u);
    case "info":
        return base + sprintf("|%s|%s|%d|%J", fmt_uptime(d.uptime),
                              d.cpu_load_raw ?? "", int(+(d.mem_free_mb ?? 0)),
                              d.battery);
    case "wifi":
        return base + sprintf("|%d|%J", nc, d.wifi?.ssid);
    case "traffic":
        return base + sprintf("|%J|%J", hist.rx, hist.tx);
    case "weather":
        return base + sprintf("|%J", d.weather);
    case "services":
        return base + sprintf("|%J", d.services);
    case "sms":
    case "sms1":
        return base + sprintf("|%d|%d|%d", st.sms_pg, st.sms_i, st.sms_ts);
    case "netpri":
        return base + sprintf("|%J", netpri_list());
    case "battery":
        return base + sprintf("|%J|%d", st.data?.battery, anim_phase);
    case "stascan":
        return base + sprintf("|%d", sta.nets == null ? -1 : length(sta.nets));
    case "kbd":
        return base + sprintf("|%s|%d|%d", sta.pass, sta.layer, sta.shift ? 1 : 0);
    case "display":
    case "night":
        return base + sprintf("|%d|%s|%d|%d|%J", saver_cfg(), saver_style(),
                              bright_cfg(), burnin_cfg() ? 1 : 0, night_cfg());
    }
    return base + sprintf("|%d", st.frame);
}

function draw_current() {
    // Пока на экране заставка, страницы не рисуем. Иначе длинная операция
    // (переключение аплинка занимает секунды) заканчивалась уже под заставкой
    // и дорисовывала страницу поверх неё - на экране получалась каша.
    if (st.screen != "active") return;

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
    case "night":     draw_night_page(); break;
    case "led":       draw_led_page(); break;
    case "battery":   draw_battery_page(); break;
    case "savercfg":  draw_savercfg_page(); break;
    case "saver":     draw_saver_page(); break;
    case "zigbee":    draw_zigbee_page(); break;
    case "sound":     draw_sound_page(); break;
    case "stascan":   draw_stascan_page(); break;
    case "kbd":       draw_kbd_page(); break;
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
    let fl = svflags();
    let row_o = { bg: bg, mono: night ? primary : null,
                  empty: night ? "#0A2A16" : C.dim,
                  no_sig: !fl.sig, no_batt: !fl.batt, no_env: !fl.env };

    // Режим «строка»: та самая шапка, прижатая к верху экрана. Часы белые.
    if (style == "line") {
        row_o.time = true;
        row_o.pct = fl.batt;
        row_o.time_color = primary;
        draw_status_row(3, row_o);
        lcd_flush();
        return;
    }


    // Полный режим: часы слева, ниже температура и картинка погоды в одну
    // строку. Раньше часы стояли по центру верха, и ярлык технологии («4G+»)
    // упирался в них - теперь верхняя полоса свободна.
    if (style == "full") {
        draw_status_row(3, row_o);

        lcd_text(14, 34, ts, primary, bg, 5);
        if (fl.date)
            lcd_text(14, 76, ds, secondary, bg, 2);

        let w2 = d?.weather;
        if (w2) {
            draw_weather_icon(LCD_W - 14 - 72, 100, w2.desc ?? "", 3,
                              night ? primary : null);
            lcd_text(14, 104, w2.temp ?? "?", primary, bg, 4);
            lcd_text(14, 140, city_name(w2.city) ?? "", secondary, bg, 1);
            lcd_text(14, 162, tcut(w2.desc ?? "", 26), accent, bg, 2);
            lcd_text(14, 190,
                     sprintf(tr("Feels %s  Hum %s  Wind %s"),
                             w2.feels ?? "?", w2.humidity ?? "?",
                             wind_fmt(w2.wind ?? "")),
                     secondary, bg, 1);
        } else {
            lcd_text(14, 120, tr("No data yet"), secondary, bg, 2);
            lcd_text(14, 146, tr("Open menu > Weather to fetch"), secondary, bg, 1);
        }

        if (night)
            lcd_text(50, 226, "Wake up, Neo...The Matrix has you...", secondary, bg, 1);

        lcd_flush();
        return;
    }

    // В режиме «часы» экран занят только ими, поэтому вдвое крупнее.
    // Ширина знакоместа - ровно 6*масштаб, иначе центрирование врёт.
    let clk_sz = (style == "clock")
               ? (fl.size == "s" ? 6 : (fl.size == "l" ? 10 : 8)) : 5;
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
    if (!fl.date) { date_sz = 0; date_gap = 0; }
    let blk_h = 7 * clk_sz + date_gap + 7 * date_sz;
    let clk_y = (style == "clock") ? int((LCD_H - blk_h) / 2) : 12;
    let clk_x = int((LCD_W - clk_w) / 2);

    // Антивыгорание: раз в минуту часы встают в новое место. Псевдослучай
    // от номера минуты - позиция стабильна внутри минуты и не требует
    // датчика случайных чисел.
    if (style == "clock" && fl.wander) {
        let seed = (t ? t.hour * 60 + t.min : 0) * 2654435761;
        let max_x = LCD_W - clk_w - 16;
        let max_y = LCD_H - blk_h - 30 - 26;
        if (max_x > 8)  clk_x = 8 + (seed % 100000) % max_x;
        if (max_y > 0)  clk_y = 26 + int(seed / 7) % max_y;
    }
    lcd_text(clk_x, clk_y, ts, primary, bg, clk_sz);

    // В полном режиме дата стоит на своём прежнем месте под часами.
    if (fl.date) {
        let date_y = (style == "clock") ? clk_y + 7 * clk_sz + date_gap : 54;
        let dx = (style == "clock" && fl.wander)
               ? clk_x + int((clk_w - date_w) / 2) : int((LCD_W - date_w) / 2);
        lcd_text(dx, date_y, ds, secondary, bg, date_sz);
    }

    // Та же статусная полоса, что и в шапке, но без времени и процентов:
    // часы тут и так во весь экран, а проценты дублировали бы значок.
    draw_status_row(3, row_o);

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

// Ночью гасим заставку до трети яркости: зелёный цвет от zipfo экономил глаза
// только по цвету, а панель светила в полную силу. Активный экран не трогаем -
// если человек подошёл и ткнул, ему нужно видеть.
function night_dim(lvl) {
    if (!night_now() || st.screen != "screensaver") return lvl;
    let d = int(lvl * 35 / 100);
    return d < 10 ? 10 : d;
}

function backlight_write(on) {
    // Яркость крутим ШИМом по подсветке - это настоящая темнота, а не серая
    // картинка. Цифровое затемнение (gray) снято совсем: оно давало не
    // темноту, а блёклость, что особенно заметно ночью.
    //
    // Мерцание, из-за которого мы от ШИМа отказывались утром, ушло вместе с
    // полной перерисовкой кадра: теперь на панель уходят только изменившиеся
    // строки, а в покое - ноль строк, и переливать нечего.
    let lvl = on ? night_dim(int(bright_cfg() * 255 / 100)) : 0;
    if (lvl > 255) lvl = 255;
    if (lvl < 8 && on) lvl = 8;   // ниже уже неразличимо, но экран не гасим

    // Гибрид: ШИМ не опускаем ниже 30% - на глубокой скважности окно света
    // такое короткое, что его рвёт любая передача кадра, и это видно как
    // мерцание. Остаток затемнения добираем цифрой: свет физически убавлен
    // ШИМом, поэтому картинка тёмная, а не серая, как при чистой цифре.
    // Порог 20%: ниже него окно света такое короткое, что передачи кадра
    // его рвут. На 20% окно 0.8 мс - уже устойчиво, а серости от цифровой
    // добавки вдвое меньше, чем при пороге 30%.
    let pwm = lvl, gray = 255;
    if (on && lvl < 51) {
        pwm = 51;
        gray = int(lvl * 255 / 51);
    }
    system(sprintf("almond3s-lcd gray %d >/dev/null 2>&1", gray));
    system(sprintf("almond3s-lcd dim %d >/dev/null 2>&1", on ? pwm : 0));
    // Классу светодиодов оставляем согласованное состояние, чтобы очередная
    // перезагрузка триггеров не зажгла панель мимо нас.
    let p = backlight_path();
    if (p != "")
        system(sprintf("echo %d > %s", on ? 1 : 0, p));
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
    st.page_sig = "";   /* смена страницы - подпись заведомо другая */
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
// Подсветка нажатия: перекрашиваем карточку и рисуем ТУ ЖЕ надпись на том же
// месте. Раньше текст рисовался по своим координатам и своим кеглем, из-за
// чего у «ЕЩЁ >>>» и «<<< НАЗАД» он подпрыгивал и менялся - выглядело как сбой.
function flash_btn(bx, by, bw, bh, label, nav) {
    lcd_rect(bx, by, bw, bh, C.accent);
    if (label && label != "")
        lcd_text(bx + (nav ? 20 : 8), by + (nav ? 20 : 8), label, C.bg, C.accent, 2);
    lcd_flush();
}

function handle_touch(tx, ty) {
    // Кнопка скана Wi-Fi на «Сети» - раньше общих правил, иначе полоса «низ -
    // назад» съедала её нижний край.
    if (st.page == "dashboard" && fs.stat(NETPRI_SH) &&
        in_rect(tx, ty, 10, BACK_Y - 36, 300, 30)) {
        sta.band = tx < 160 ? 2 : 5;
        sta.nets = null;
        wifi_scan_start(sta.band);
        go_page("stascan");
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
        system("/etc/almond3s/scripts/svcping.sh >/dev/null 2>&1 &");
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
                sms_mark_read(list[idx]);
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
                        tr("Traffic"), tr("Info"), tr("MORE >>>") ]
                    : (st.mpg == 2
                        ? [ tr("SMS"), tr("Services"), tr("Weather"),
                            tr("Display"), tr("Saver"), tr("MORE >>>") ]
                        : (st.mpg == 3
                            ? [ tr("LED"), tr("Sound"), tr("Battery"),
                                "Zigbee", "", tr("MORE >>>") ]
                            : [ tr("Modem Reset"), tr("Reboot"), "",
                                "", "", tr("<<< BACK") ]));
                flash_btn(b.x, b.y, b.w, b.h, labels[i - 1] ?? "", i == 6);
                sock_poll(150);

                if (st.mpg == 1) {
                    switch (i) {
                    case 1: netpri_refresh(); go_page("dashboard"); return;
                    case 2: go_page("wifi"); return;
                    case 3: go_page("lte"); return;
                    case 4: go_page("traffic"); return;
                    case 5: go_page("info"); return;
                    case 6: st.mpg = 2; draw_menu(); return;
                    }
                } else if (st.mpg == 3) {
                    switch (i) {
                    case 1: go_page("led"); return;
                    case 2: go_page("sound"); return;
                    case 3: go_page("battery"); return;
                    case 4: go_page("zigbee"); return;
                    case 6: st.mpg = 4; draw_menu(); return;
                    }
                } else if (st.mpg == 4) {
                    switch (i) {
                    case 1:
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
                    case 2:
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
                                    action_splash(tr("Reboot"), tr("Rebooting..."), C.red);
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
                    case 5: go_page("saver"); return;
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
                system("/etc/almond3s/scripts/svcping.sh " + sh_quote(hosts[i]) + " >/dev/null 2>&1");
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

    if (st.page == "dashboard") {
        let l = netpri_list();
        if (type(l) == "array") {
            for (let i = 0; i < length(l) && i < 4; i++) {
                let b = netpri_btn(i);
                if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
                // Минус на Wi-Fi-карточке: забыть сеть, с подтверждением.
                if ((l[i].type ?? "") == "wifi" && tx >= b.x + b.w - 34) {
                    lcd_clear("#200000");
                    lcd_rect(30, 60, 260, 120, "#300000");
                    lcd_rect(30, 60, 260, 1, C.red);
                    lcd_text(46, 75, tr("Forget network?"), C.red, "#300000", 2);
                    lcd_text(46, 95, tcut(l[i].label ?? "", 20), C.white, "#300000", 2);
                    lcd_rect(50, 125, 100, 35, C.red);
                    lcd_text(72, 133, tr("YES"), C.white, C.red, 2);
                    lcd_rect(170, 125, 100, 35, "#0841");
                    lcd_text(196, 133, tr("NO"), C.white, "#0841", 2);
                    lcd_flush();
                    for (let sec = 8; sec > 0; sec--) {
                        system("sleep 1");
                        let ct = read_touch();
                        if (!ct) continue;
                        if (ct.x < 160 && ct.y > 110) {
                            if (ucur) {
                                // Убираем всё, что создавал мастер: и STA, и
                                // netifd-интерфейс - иначе в LuCI остаётся
                                // интерфейс-сирота со знаком вопроса.
                                ucur.delete("wireless", STA_SECTION);
                                ucur.commit("wireless");
                                ucur.delete("network", "wwan");
                                ucur.commit("network");
                            }
                            system("ubus call network reload >/dev/null 2>&1");
                            netpri_refresh();
                            sock_poll(2000);
                        }
                        break;
                    }
                    go_page("dashboard");
                    return;
                }
                if (i == 0) return;          /* уже основной */
                let ifn = l[i].iface ?? "";
                if (ifn == "") return;
                action_splash(tr("Internet"), tr("Switching..."), C.cyan);
                system(sprintf("%s set %s >/dev/null 2>&1", NETPRI_SH, ifn));
                netpri_refresh();
                sock_poll(2500);
                draw_current();
                return;
            }
        }
        // Зону кнопки скана считаем так же, как в draw_dashboard, не полагаясь
        // на st.stabtn: он мог не установиться, если аплинки в тот момент ещё
        // читались.
        return;
    }

    if (st.page == "sound") {
        for (let i = 0; i < length(SOUNDS); i++) {
            let b = snd_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            flash_btn(b.x, b.y, b.w, b.h, SOUNDS[i].label, false);
            snd_play(i);
            draw_sound_page();
            return;
        }
        return;
    }

    if (st.page == "stascan") {
        let nets = sta.nets;
        if (type(nets) != "array") return;
        for (let i = 0; i < length(nets) && i < 6; i++) {
            let b = stascan_row(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            sta.sel = i;
            if (nets[i].enc) {
                // Защищённая сеть - вводим пароль.
                sta.pass = ""; sta.layer = 0; sta.shift = false;
                go_page("kbd");
            } else {
                // Открытая - подключаемся сразу.
                action_splash(tr("Wi-Fi"), tr("Connecting..."), C.cyan);
                sta_apply(nets[i].ssid, "", nets[i].band);
                sta_pending = { ssid: nets[i].ssid, since: time() };
                sock_poll(2500);
                netpri_refresh();
                go_page("dashboard");
            }
            return;
        }
        return;
    }

    if (st.page == "kbd") {
        // спецкнопки нижнего ряда
        if (type(sta.specs) == "array" && ty >= sta.spec_y && ty < sta.spec_y + 26) {
            for (let sp in sta.specs) {
                if (tx < sp.x || tx >= sp.x + sp.w) continue;
                if (sp.k == "layer") sta.layer = (sta.layer + 1) % 2;
                else if (sp.k == "shift") sta.shift = !sta.shift;
                else if (sp.k == "space") sta.pass += " ";
                else if (sp.k == "del") sta.pass = substr(sta.pass, 0, length(sta.pass) - 1);
                else if (sp.k == "ok") {
                    let n = sta.nets[sta.sel];
                    action_splash(tr("Wi-Fi"), tr("Connecting..."), C.cyan);
                    sta_apply(n.ssid, sta.pass, n.band);
                    sta_pending = { ssid: n.ssid, since: time() };
                    sock_poll(2500);
                    netpri_refresh();
                    go_page("dashboard");
                    return;
                }
                draw_kbd_page();
                return;
            }
        }
        // символьные клавиши
        let rows = KBD[sta.layer];
        for (let r = 0; r < length(rows); r++) {
            let chars = rows[r], ncols = length(chars);
            let off = int((10 - ncols) / 2);
            for (let c = 0; c < ncols; c++) {
                let b = kbd_key(r, off + c, ncols);
                if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
                let ch = substr(chars, c, 1);
                if (sta.shift && sta.layer == 0) ch = uc(ch);
                sta.pass += ch;
                draw_kbd_page();
                return;
            }
        }
        return;
    }

    if (st.page == "savercfg") {
        let fl = svflags();
        let v = { sv_date: fl.date, sv_signal: fl.sig, sv_batt: fl.batt,
                  sv_env: fl.env, sv_wander: fl.wander };
        let rows = savercfg_rows_for_style();
        for (let i = 0; i < length(rows); i++) {
            let b = savercfg_row(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                svflag_set(rows[i].key, v[rows[i].key] ? "0" : "1");
                draw_savercfg_page();
                return;
            }
        }
        if (saver_style() == "clock") {
            let keys = [ "s", "m", "l" ];
            let yb = 30 + length(rows) * 30;
            for (let i = 0; i < 3; i++) {
                let b = savercfg_size_btn(i);
                b.y = yb;
                if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                    svflag_set("clock_size", keys[i]);
                    draw_savercfg_page();
                    return;
                }
            }
        }
        return;
    }

    if (st.page == "led") {
        let c = led_cfg();
        let b0 = led_row(0), b1 = led_row(1);
        if (in_rect(tx, ty, b0.x, b0.y, b0.w, b0.h)) {
            led_set("state", c.on ? "0" : "1");
            led_apply();
            draw_led_page();
            return;
        }
        if (in_rect(tx, ty, b1.x, b1.y, b1.w, b1.h)) {
            led_set("sms_blink", c.sms ? "0" : "1");
            led_sms_sync(int(st.data?.sms_new ?? 0));
            draw_led_page();
            return;
        }
        return;
    }

    if (st.page == "night") {
        let c = night_cfg();
        let nb = night_btn();
        if (in_rect(tx, ty, nb.x, nb.y, nb.w, nb.h)) {
            night_set("night", c.on ? "0" : "1");
            draw_night_page();
            return;
        }
        for (let r = 0; r < 2; r++) {
            let key = r == 0 ? "night_from" : "night_to";
            let val = r == 0 ? c.from : c.to;
            let m = hour_btn(r, -1), pl = hour_btn(r, 1);
            if (in_rect(tx, ty, m.x, m.y, m.w, m.h)) {
                night_set(key, (val + 23) % 24);
                draw_night_page();
                return;
            }
            if (in_rect(tx, ty, pl.x, pl.y, pl.w, pl.h)) {
                night_set(key, (val + 1) % 24);
                draw_night_page();
                return;
            }
        }
        return;
    }

    if (st.page == "display") {
        let rb = rot_btn();
        if (in_rect(tx, ty, rb.x, rb.y, rb.w, rb.h)) {
            rot_set(!rot_cfg());
            rot_apply();
            draw_display_page();
            return;
        }
        let lb = lang_btn();
        if (in_rect(tx, ty, lb.x, lb.y, lb.w, lb.h)) {
            lang_set(lang() == "ru" ? "en" : "ru");
            draw_display_page();
            return;
        }
        let fb = font_btn();
        if (in_rect(tx, ty, fb.x, fb.y, fb.w, fb.h)) {
            FONT_MODE = FONT_MODE ? 0 : 1;
            ucur.set("almond3s", "display", "font",
                     FONT_MODE ? "flipper" : "std");
            ucur.commit("almond3s");
            draw_display_page();
            return;
        }
        for (let i = 0; i < length(BRIGHT_STEPS); i++) {
            let bb = bright_btn(i);
            if (in_rect(tx, ty, bb.x, bb.y, bb.w, bb.h)) {
                bright_set(BRIGHT_STEPS[i]);
                if (!st.blank)
                    backlight_write(true);
                draw_display_page();
                return;
            }
        }
        return;
    }

    if (st.page == "saver") {
        let cur = saver_cfg();
        let idx = 0;
        for (let i = 0; i < length(SAVER_STEPS); i++)
            if (SAVER_STEPS[i] == cur) idx = i;

        let a = saver_btn(-1), z = saver_btn(1);
        if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) {
            saver_set(SAVER_STEPS[(idx + length(SAVER_STEPS) - 1) % length(SAVER_STEPS)]);
            draw_saver_page();
            return;
        }
        if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) {
            saver_set(SAVER_STEPS[(idx + 1) % length(SAVER_STEPS)]);
            draw_saver_page();
            return;
        }

        for (let i = 0; i < length(SAVER_STYLES); i++) {
            let sb = style_btn(i);
            if (in_rect(tx, ty, sb.x, sb.y, sb.w, sb.h)) {
                // Любой тап по стилю выбирает его и открывает состав
                // элементов: сразу видно, из чего этот стиль состоит.
                if (SAVER_STYLES[i] != saver_style())
                    saver_style_set(SAVER_STYLES[i]);
                go_page("savercfg");
                return;
            }
        }

        let hb = svshift_btn();
        if (in_rect(tx, ty, hb.x, hb.y, hb.w, hb.h)) {
            burnin_set(!burnin_cfg());
            draw_saver_page();
            return;
        }

        let nb = svnight_btn();
        if (in_rect(tx, ty, nb.x, nb.y, nb.w, nb.h)) {
            // Выключенный режим тап включает, и в любом случае открывает
            // страницу с часами - там же его можно выключить обратно.
            if (!night_cfg().on) night_set("night", "1");
            go_page("night");
            return;
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
                ucur.set("almond3s", "weather", "city", list[idx]);
                ucur.commit("almond3s");
                action_splash(tr("Weather"), sprintf(tr("Fetching %s..."), city_name(list[idx])), C.yellow);
                system("/etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1");
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
        backlight_write(true);   /* вернуть полный уровень после ночной заставки */
        // Просыпаемся на ту же страницу, с которой ушли в заставку:
        // человек продолжает с места, где остановился.
        refresh_data();
        st.page_sig = "";
        draw_current();
    } else if (s == "screensaver") {
        st.saver_frame = 0;
        if (saver_style() == "off") {
            set_blank(true);
        } else {
            backlight_write(true);   /* пересчитает уровень с учётом ночи */
            draw_screensaver();
        }
    }
}

// Служебный переход на страницу по файлу-запросу: echo lte > /tmp/.lcd_goto.
// Нужен для снятия экранов и отладки - тапать вслепую по живому интерфейсу
// опасно: однажды такой тап попал в выключатель Wi-Fi.
function goto_req() {
    let r = fs.readfile("/tmp/.lcd_goto");
    if (!r) return;
    fs.unlink("/tmp/.lcd_goto");
    r = trim(r);
    if (r == "menu2") { st.page = "menu"; st.mpg = 2; }
    else if (r == "menu3") { st.page = "menu"; st.mpg = 3; }
    else if (r == "menu4") { st.page = "menu"; st.mpg = 4; }
    else if (r == "menu") { st.page = "menu"; st.mpg = 1; }
    else if (r == "net") { st.page = "dashboard"; netpri_refresh(); }
    else st.page = r;
    st.ltch = time();
    set_screen("active");
    st.page_sig = "";
    draw_current();
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
    warn(sprintf("almond3s-lcd: starting (ucode) ubus=%s uci=%s uloop=%s\n",
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
    backlight_write(true);   /* внутри уже уровень из настроек */
    led_apply();             /* диод в состояние из настроек */
    rot_apply();             /* ориентация экрана из настроек */

    // Stop splash: ioctl(0) via flush
    system("printf '\\0' > /dev/lcd 2>/dev/null");

    // Initial data + draw. Стартуем на «Модем» - там же, куда попадаем из
    // заставки: иначе после каждого перезапуска демона экран молча уезжал
    // на «Сеть», и выглядело это как «страница сама перескакивает».
    refresh_data();
    st.page = "lte";
    draw_current();

    // === uloop event-driven mode ===
    if (uloop_mod) {
        uloop_mod.init();

        // Анимация зарядки: отдельный быстрый таймер, который что-то делает
        // только пока идёт заряд. На панель при этом уходят лишь строки
        // батарейки - остальное не меняется, и построчный вывод их не шлёт.
        // Полоски метрик докатываются за несколько кадров. Таймер частый, но
        // просыпается вхолостую только когда что-то реально движется.
        let bar_t;
        bar_t = uloop_mod.timer(90, function() {
            if (bar_moving && st.screen == "active" && st.page == "lte") {
                bar_moving = false;
                draw_current();
            } else {
                bar_moving = false;
            }
            // Пока открыта страница скана и результата ещё нет - опрашиваем.
            if (st.screen == "active" && st.page == "stascan" && sta.nets == null) {
                let r = wifi_scan_read();
                if (r != null) { sta.nets = r; draw_current(); }
            }
            bar_t.set(90);
        });

        let anim_t, anim_tick = 0;
        anim_t = uloop_mod.timer(700, function() {
            let bat = st.data?.battery;
            if (bat?.charging && !bat?.no_battery &&
                int(+(bat?.percent ?? 0)) < 100) {
                anim_tick++;
                if (st.screen == "active") {
                    anim_phase++;
                    draw_current();
                } else if (st.screen == "screensaver" && !st.blank && (anim_tick % 2) == 0) {
                    // На заставке шаг вдвое реже: она и задумана спокойной, а
                    // строк батарейки в кадре всего шестнадцать, так что
                    // перерисовка почти ничего не стоит.
                    anim_phase++;
                    draw_screensaver();
                }
            }
            anim_t.set(700);
        });

        // Data refresh + redraw (every 2s)
        let data_t;
        data_t = uloop_mod.timer(T.data * 1000, function() {
            refresh_data();
            // На открытой «Сети» список аплинков освежаем раз в три тика:
            // подключение STA или смена метрик иначе не видны, пока не выйдешь
            // и не зайдёшь через меню.
            if (st.page == "dashboard" && st.screen == "active") {
                st.np_tick = (st.np_tick ?? 0) + 1;
                if (st.np_tick % 3 == 0) netpri_refresh();
            }
            // Результат скана Wi-Fi: подхватываем, как только готов.
            if (st.page == "stascan" && sta.nets == null) {
                let r = wifi_scan_read();
                if (r != null) sta.nets = r;
            }
            if (st.screen == "active") {
                // Перерисовываем, только если на странице что-то изменилось.
                let sig = page_sig();
                if (sig != st.page_sig) {
                    st.page_sig = sig;
                    draw_current();
                }
            } else if (st.screen == "screensaver" && !st.blank) {
                // Заставку перерисовываем, только когда на ней что-то меняется:
                // раз в две секунды она рисовалась заново без причины, а полный
                // кадр идёт 75 мс и на приглушённой подсветке эта протяжка
                // видна как вспышка.
                let sig = clock_str() + "|" + (st.data?.weather?.temp ?? "") +
                          "|" + int(+(st.data?.battery?.percent ?? 0)) +
                          "|" + sig_state().bars +
                          "|" + int(st.data?.sms_new ?? 0);
                if (sig != st.saver_sig) {
                    st.saver_sig = sig;
                    draw_screensaver();
                }
            }
            data_t.set(T.data * 1000);
        });

        // Touch polling (every 100ms)
        let touch_t;
        touch_t = uloop_mod.timer(100, function() {
            screen_req();
            goto_req();
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

        warn("almond3s-lcd: uloop running\n");
        uloop_mod.run();

    // === Fallback: poll loop ===
    } else {
        warn("almond3s-lcd: fallback poll loop (no uloop)\n");
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
