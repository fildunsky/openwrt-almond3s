#!/usr/bin/ucode
//
// lcd_ui.uc V260401 by a43
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
    bg_top:  "#182C40", // подложка: сине-стальной отсвет сверху (ярче)...
    bg_bot:  "#070A0E", // ...и глубже уход в тень книзу - контрастнее
    hdr:     "#161B22", // GitHub Dark Overlay
    white:   "#C9D1D9", // GH Text Primary
    green:   "#3FB950", // GH Success
    red:     "#F85149", // GH Danger
    yellow:  "#E8853A", // теперь тоже оранжевый (по просьбе - единый акцент)
    orange:  "#E8853A", // предупреждения (warn-уровень)
    cyan:    "#58A6FF", // GH Accent Blue
    gray:    "#8B949E", // GH Text Secondary
    btn:     "#21262D", // GH Sub-panel
    back:    "#A40E26", // Subdued red for back bar
    press:   "#0B0E13", // нажатая кнопка: уходит в тень
    back_press: "#6E0A18", // нажатая полоса «Назад»: тёмно-красная
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
let LVC = { ok: C.green, warn: C.orange, crit: C.red };

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

// Отделяет число от единицы (хвост букв/%/кириллицы после последней цифры).
// Знак градуса ° остаётся с числом. Возвращает [число, единица].
function split_unit(v) {
    v = v ?? "";
    let last = -1;
    for (let i = 0; i < length(v); i++) {
        let c = ord(v, i);
        if (c >= 48 && c <= 57) last = i;
    }
    if (last < 0) return [ v, "" ];
    let e = last + 1;
    while (e < length(v) && substr(v, e, 2) == "°") e += 2;   // ° - к числу
    return [ substr(v, 0, e), trim(substr(v, e)) ];
}

// Версия драйвера (дата сборки) - статична до перезагрузки службы. Раньше её
// тянули popen'ом almond3s-lcd НА КАЖДУЮ перерисовку «Инфо» (форк+exec на кадр);
// кэшируем один раз.
let drv_ver_cache = null;
function drv_version() {
    if (drv_ver_cache == null) {
        let p = fs.popen("almond3s-lcd version 2>/dev/null", "r");
        drv_ver_cache = p ? trim(p.read("all") ?? "?") : "?";
        if (p) p.close();
    }
    return drv_ver_cache;
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
let GEO_JSON = "/tmp/lcd_geo.json";   // ответ геокодера для пикера выбора города

// --- Единая сетка страниц (8px модуль) ---
// Контент живёт в безопасной зоне между шапкой (22) и полосой «назад» (208):
// x 8→312 (304 шир.), y 24→206. Зазор/модуль 8. Две колонки по 148 c гаттером 8.
// Помогает: gcard() рисует карточку с акцентной полосой и возвращает координаты
// для контента (ix/iy - левый-верх с внутренним отступом 10/8).
let GX = 8, GR = 312, GW = 304, GY = 24, GB = 206, GG = 8;
let GCOL = 148;                 // ширина колонки в 2-колоночной раскладке
let GH = { xs: 40, s: 64, m: 88, l: 176 };   // набор высот карточек
// gcard() определена ниже, после lcd_rect/lcd_text (ucode без hoisting).

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
    saver_scene: null, // индекс сцены-заставки в kmod (null = обычная заставка)
    term: { kbd: true, kb: { pg: "abc", caps: false, ctrl: false, term: true } }, // терминал (демон almond3s-term)
    blank:  false,     // подсветка погашена (стиль заставки «выкл»)
    sms:    null,      // разобранный список SMS
    sms_ts: 0,         // mtime кэша, по которому разбирали
    sms_pg: 0,         // страница списка
    sms_i:  -1,        // открытое сообщение
    sms_tp: 0,         // страница текста открытого сообщения
    sms_wait: false,   // ждём фоновое чтение из модема
    sms_wait_since: 0, // когда началось ожидание (для таймаута)
    sms_nobridge: false, // 5gmodem/мост не установлен
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

// Иконки плиток меню: выключены, пока набор не дорисован. Тумблер на
// странице «Экран».
let MICONS_ON = false;
function micons_load() {
    MICONS_ON = (ucur ? ucur.get("almond3s", "display", "micons") : null) == "1";
}
micons_load();

// Градиент-подложка под плашки: включён по умолчанию, гасится тумблером
// «Фон» на странице «Экран» (тогда фон - плоская заливка C.bg).
let GRAD_ON = true;
function grad_load() {
    GRAD_ON = (ucur ? ucur.get("almond3s", "display", "gradient") : null) != "0";
}
grad_load();

// SSClash: меню VPN показываем, только если служба установлена (есть init).
// Дальше по файлу vpn_present() зовётся из отрисовки меню - потому объявлен тут.
let VPN_PRESENT = null;
function vpn_present() {
    if (VPN_PRESENT == null)
        VPN_PRESENT = (fs.stat("/etc/init.d/ssclash") != null)
                   || (fs.stat("/etc/init.d/clash") != null);
    return VPN_PRESENT;
}

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
    "Reboot": "Ребут",
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
    "OFF": "ВЫКЛ",
    "POWER": "ПИТАНИЕ",
    "Restart": "Перезагрузка",
    "Shut down": "Выключение",
    "Cancel": "Отмена",
    "Power": "Питание",
    "Unplug charger first": "Сначала отключите зарядку",
    "Power off": "Выключение",
    "Powering off...": "Выключаю питание...",
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
    "Enabling...": "Включаю...",
    "Disabling...": "Выключаю...",
    "2.4GHz on": "2.4ГГц вкл",
    "2.4GHz off": "2.4ГГц выкл",
    "5GHz on": "5ГГц вкл",
    "5GHz off": "5ГГц выкл",
    "SIM %d": "SIM %d",
    "Fetching %s...": "Загружаю %s...",
    "Updating...": "Обновляю...",
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
    "device": "устройство",
    "Wi-Fi on": "Wi-Fi вкл",
    "Wi-Fi off": "Wi-Fi выкл",
    "Updated: %02d:%02d, %02d.%02d": "Обновлено: %02d:%02d, %02d.%02d",
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
    "Connecting...": "Подключение...",
    "Menu icons": "Иконки меню",
    "Background": "Фон",
    "Running": "Работает",
    "Stopped": "Остановлен",
    "Waiting for log...": "Ожидание лога...",
    "SSClash not installed": "SSClash не установлен",
    "Install: opkg/apk add luci-app-ssclash": "Поставьте luci-app-ssclash",
    "Speedtest": "Спидтест",
    "down/up": "загрузка/отдача",
    "Download": "Загрузка",
    "Upload": "Отдача",
    "Done": "Готово",
    "Mbps": "Мбит/с",
    "Choose server": "Выбор сервера",
    "curl not installed": "нет curl",
    "No switchable groups": "Нет групп",
    "Auto (URL-test)": "Авто (URL-test)",
    "Selected: %s": "Выбран: %s",
    "Ping...": "Пинг...",
    "on battery %s": "от батареи %s",
    "sec": "с",
    "Starting...": "Запуск...",
    "Stopping...": "Остановка...",
    "Debug": "Дебаг",
    "Panel tuning": "Дебаг панели",
    "CHARGE %": "ЗАРЯД %",
    "ADC RAW": "АЦП",
    "V": "В",
    "%/h": "%/ч",
    "VOLTAGE": "НАПРЯЖЕНИЕ",
    "Charge cycles: %d  range %.1f-8.3V": "Циклов заряда: %d • %.1f-8.3 В",
    "range %.1f-8.3V, discharges in %s": "%.1f-8.3 В, разряд за %s",
    "Charge cycles: %d  ADC %d..726": "Циклов заряда: %d • АЦП %d..726",
    "ADC %d..726, discharges in %s": "АЦП %d..726, разряд за %s",
    "Editor": "Редактор",
    "pixel art": "пиксель-арт",
    "Save": "Сохранить",
    "Clear": "Очистить",
    "Clr": "Очист",
    "editing": "правится",
    "Pick an icon to edit": "Выбери иконку для правки",
    "Pick a color for the slot": "Выбери цвет кисти",
    "8 colors max": "Максимум 8 цветов в иконке",
    "Invert": "Инверт",
    "Saved": "Сохранено",
    "panel tuning": "настройки панели",
    "Invert colors": "Инверсия цветов",
    "Invert": "Инверсия",
    "Panel": "Панель",
    "kernel": "ядро",
    "boot": "бут",
    "GAMMA CURVE": "ГАММА-КРИВАЯ",
    "COLOR ENHANCE": "ЦВЕТОУСИЛЕНИЕ",
    "BACKLIGHT PWM, HZ": "ШИМ ПОДСВЕТКИ, ГЦ",
    "photo": "фото",
    "video": "видео",
    "Uptime": "Время работы",
    "Free RAM": "ОЗУ свободно",
    "Flash free": "Флеш свободно",
    "Kernel": "Ядро",
    "Driver": "Драйвер",
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
    "Matrix": "Матрица",
    "Logo": "Лого",
    "Terminal": "Терминал",
    "Exit": "Выход",
    "Alarm": "Будильник",
    "wake up": "подъём",
    "Feels": "Ощущается",
    "Humidity": "Влажность",
    "Wind": "Ветер",
    "Custom city...": "Свой город...",
    "Custom city": "Свой город",
    "Type city name": "Введите город",
    "Source": "Источник",
    "Zigbee": "Зигби",
    "Games": "Игры",
    "Setup": "Настройки",
    "tap to change": "тап по строке - следующее значение",
    "Gamepad": "Пульт",
    "Settings": "Настройки",
    "LIGHT, %": "ЯРКОСТЬ, %",
    "WARM, %": "ТЕПЛО, %",
    "brightness, warm, language": "яркость, тепло, язык",
    "timeout and look": "время и вид",
    "schedule and actions": "расписание и действия",
    "driver debug": "отладка драйвера",
    "Warm": "Тепло",
    "Wi-Fi off": "Wi-Fi ночью",
    "Green saver": "Зелёная",
    "light": "слабо",
    "medium": "средне",
    "strong": "сильно",
    "Keyboard": "Клавиатура",
    "Keys": "Клавиши",
    "Player %d": "Игрок %d",
    "tap a row, then press a key": "тап по строке, затем нажми клавишу",
    "press a key": "жми клавишу",
    "Gamepad on phone": "Джойстик на телефоне",
    "scan while a game is running": "сканируй, когда игра запущена",
    "no ROMs": "нет ромов",
    "%d ROMs": "ромов: %d",
    "Put .nes into": "Положи .nes в",
    "emulator not installed": "эмулятор не установлен",
    "Select city": "Выбор города",
    "Searching...": "Поиск...",
    "City not found": "Город не найден",
    "Once": "Разово",
    "Daily": "Ежедневно",
    "repeat": "повтор",
    "no repeat": "без повтора",
    "min": "мин",
    "vol": "гр",
    "ON": "ВКЛ",
    "OFF": "ВЫКЛ",
    "shell": "шелл",
    "keyboard": "клавиатура",
    "Screensaver dims to green at night": "Ночью заставка светится тускло-зелёным",
    "Model": "Модель",
    "Band": "Диапазон",
    "Number": "Номер",
    "SMS": "СМС",
    "inbox": "входящие",
    "%d new": "новых: %d",
    "Reading inbox...": "Читаю ящик...",
    "Modem tool not installed": "Модем-утилита не установлена",
    "Failed to read inbox": "Не удалось прочитать ящик",
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
    "Ping": "Пинг",
    "Signal qual": "Качество сигнала",
    "check": "проверить",
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
    // Фон по умолчанию - вертикальный градиент-подложка под все плашки. Явный
    // цветной clear (сплэши, спец-экраны) остаётся плоской заливкой.
    if (GRAD_ON && (c == null || c == C.bg))
        Q(sprintf('{"cmd":"vgrad","x":0,"y":0,"w":%d,"h":%d,"color":"%s","color2":"%s"}',
                  LCD_W, LCD_H, C.bg_top, C.bg_bot));
    else
        Q(sprintf('{"cmd":"clear","color":"%s"}', c ?? C.bg));
}

function lcd_rect(x, y, w, h, c) {
    Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s"}', x, y, w, h, c));
}

// Срезаем сырые контрол-байты (<0x20): регекс /[\x00-\x1f]/ в ucode
// компилируется только в рантайме и там БРОСАЕТ - уронил бы демон при первом
// же тексте. Кириллица (многобайтный UTF-8, все байты >=0x80) не затрагивается.
// Посимвольный цикл на КАЖДЫЙ вывод текста заметно тормозил реакцию на тач,
// поэтому сначала быстрый путь: три поиска на C-скорости. Реальные источники
// грязи - \r из SMS, табы и ESC из чужих данных; совсем экзотический байт
// (\x00-\x08) проскочит, но он лишь уронит одну команду в парсере render
// (текст молча не нарисуется) - это не крэш, ради него не стоит платить
// циклом на каждой перерисовке. Настоящий \n к этому моменту уже экранирован.
const CTRL_ESC = chr(27);
function strip_ctrl(str) {
    if (index(str, "\r") < 0 && index(str, "\t") < 0 && index(str, CTRL_ESC) < 0)
        return str;
    let out = "";
    for (let i = 0; i < length(str); i++)
        if (ord(str, i) >= 32) out += substr(str, i, 1);
    return out;
}

function lcd_text(x, y, text, color, bg, sz) {
    // Экранируем для JSON и УБИРАЕМ все сырые контрол-символы. Команды к render.c
    // разделяются живым \n, поэтому \n в тексте превращаем в литеральный \\n
    // (иначе перевод строки разрезал бы команду пополам). Остальные контрол-байты
    // (\r, \t, \x00-\x1f) внутри строки - незаконный JSON: парсер render.c роняет
    // команду ЦЕЛИКОМ, и текст молча не рисуется (ловили на SMS с сырым CR - ровно
    // тот же класс, что баг SMS-списка в 5gmodem). Срезаем их ПОСЛЕ эскейпа: к
    // этому моменту настоящий \n уже стал двумя печатными символами \\n.
    text = strip_ctrl(replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    // Текст на фоне страницы (C.bg) поверх градиента-подложки давал бы чёрную
    // плашку под буквами. Рисуем его прозрачным ("none"), чтобы просвечивал
    // градиент. Непрозрачные фоны (C.widget/C.hdr/акценты) не трогаем. Полный
    // кадр всегда рисуется по свежей подложке, поэтому призраков нет.
    let b = bg ?? C.bg;
    if (GRAD_ON && b == C.bg) b = "none";
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d}',
        x, y, text, color ?? C.white, b, sz ?? 2));
}

// Рамка-контур 1px (общий хелпер: кнопки Wi-Fi/спидтест). Объявлена рано -
// в ucode нет hoisting, а зовут её функции выше по файлу.
function rborder(x, y, w, h, c) {
    lcd_rect(x, y, w, 1, c);
    lcd_rect(x, y + h - 1, w, 1, c);
    lcd_rect(x, y, 1, h, c);
    lcd_rect(x + w - 1, y, 1, h, c);
}

// Карточка единой сетки: фон + акцентная полоса слева. Возвращает координаты
// для контента (ix/iy - с внутренним отступом 10/8, r - правый край).
function gcard(x, y, w, h, accent) {
    lcd_rect(x, y, w, h, C.widget);
    if (accent) lcd_rect(x, y, 3, h, accent);   // полоска тоньше (3px)
    // ix - отступ текста от полоски (13px), чтобы не липло к акценту.
    return { x: x, y: y, w: w, h: h, ix: x + 13, iy: y + 9, r: x + w };
}

// Те же координаты, что gcard, но БЕЗ отрисовки плашки/акцента - для заставки
// «Погода»: раскладка карточек, но без фоновых прямоугольников (текст поверх
// градиента-подложки).
function gcard_pos(x, y, w, h) {
    return { x: x, y: y, w: w, h: h, ix: x + 13, iy: y + 9, r: x + w };
}

// Native socket — connect/send/close per flush (fast, no deadlock)
function lcd_flush() {
    // Активный тост дорисовываем поверх любого кадра: так неблокирующая полоса
    // держится, даже если вызывающий после toast() сразу перерисовал страницу.
    if (st.toast && st.toast.until && time() < st.toast.until) {
        let t = st.toast;
        lcd_rect(0, LCD_H - 36, LCD_W, 36, t.bg);
        lcd_rect(0, LCD_H - 37, LCD_W, 1, t.color);
        lcd_text(10, LCD_H - 30, t.msg, t.color, t.bg, 2);
    }
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

    let sc = mono ?? (sections == 1 ? C.red : (sections == 2 ? C.orange : C.green));
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
            let ty2 = y + h - int((t.val - mn) * h / range);
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
        let py = y + h - 1 - int((val - mn) * (h - 2) / range);
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
        let last_py = y + h - 1 - int((last_val - mn) * (h - 2) / range);
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
    // Каждый массив истории сам ограничивает свою длину (трафик 60,
    // батарея 120) - рисуем всё, что есть.
    let pts = n;
    let start = 0;
    let step_x = (w - 2) / (pts - 1);
    let prev_px = -1, prev_py = -1;

    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * step_x);
        let py = y + h - 1 - int((val - mn) * (h - 2) / range);
        if (py < y) py = y;
        if (py >= y + h) py = y + h - 1;
        // Сегмент не должен выходить за рамку графика: при малом числе
        // точек шаг крупный, и последний прямоугольник вылезал за экран.
        let seg_lim = x + w - 1 - px;
        if (fill) {
            let fh = int(log_frac(val, mx) * (h - 2) / 1000);
            let seg_w0 = int(step_x); if (seg_w0 < 1) seg_w0 = 1;
            if (seg_w0 > seg_lim) seg_w0 = seg_lim;
            if (fh > 0 && seg_w0 > 0) lcd_rect(px, y + h - fh, seg_w0, fh, color);
            prev_px = px;
            prev_py = y + h - fh;
            continue;
        }
        let seg_w = int(step_x); if (seg_w < 1) seg_w = 1;
        if (seg_w > seg_lim) seg_w = seg_lim;
        if (seg_w < 1) seg_w = 1;
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
    // Битый/рваный снапшот не должен ронять весь демон: json() бросает
    // исключение внутри 2-секундного таймера, procd крутил бы рестарт-цикл.
    let d = {};
    if (raw) { try { d = json(raw) ?? {}; } catch(e) { d = {}; } }

    // EC21: uqmi script JSON
    let uqmi_raw = fs.readfile("/tmp/lte_uqmi.json");
    if (uqmi_raw) {
        try { d.uqmi = json(uqmi_raw); } catch(e) {}
        if (d.uqmi == null && d?.lte) d.uqmi = {};
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

    // Supplement: ubus system info (more accurate uptime/mem/load). Два
    // синхронных ubus-вызова каждые 2с - самая дорогая часть тика; пока экран
    // погашен, их результат никто не видит (заставка живёт на сокете/файлах),
    // поэтому на спящем устройстве их пропускаем. Плюс на STA-страницах
    // (скан/пароль): после `wifi reload` netifd занят, и `network.interface.wan
    // status` виснет секундами, морозя весь uloop - клавиатура не печатала.
    // Этим страницам uptime/wan не нужны, опрос пропускаем.
    if (uconn && !st.blank && st.page != "kbd" && st.page != "stascan") {
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


// Данные `system board` (модель/ядро/релиз) при жизни ПРОЦЕССА не меняются:
// поменять ядро/релиз можно только прошивкой, а она всегда перезагружает
// устройство - демон стартует заново и перечитывает всё свежим. Поэтому тянуть
// их по ubus на каждой перерисовке «Инфо» незачем - кэшируем. TTL 10 мин - это
// подстраховка на случай, если кто-то однажды сделает демон переживающим
// апгрейд: тогда данные сами обновятся за минуты, а не застрянут навсегда.
let _board = null, _board_ts = 0;
function board_info() {
    let now = time();
    if (_board != null && (now - _board_ts) <= 600) return _board;
    if (uconn) {
        let b = uconn.call("system", "board", {});
        if (b) { _board = b; _board_ts = now; }
    }
    return _board;
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
        if (m) return { x: +m[1], y: +m[2], move: false };
    }
    // Движение живёт в отдельном файле, чтобы не затирать нажатия.
    raw = fs.readfile(TOUCH_PATH + ".move");
    if (raw) {
        fs.unlink(TOUCH_PATH + ".move");
        let m = match(trim(raw), /^(\d+)\s+(\d+)/);
        if (m) return { x: +m[1], y: +m[2], move: true };
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
    if (rsrp <= -100 && rsrp > -110) return { label: "OK",        bars: 3, color: C.orange };
    if (rsrp <= -110 && rsrp > -120) return { label: "Weak",      bars: 2, color: C.orange };
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
    if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824.0);
    if (b >= 1048576) return sprintf("%.1fM", b / 1048576.0);
    if (b >= 1024) return sprintf("%.0fK", b / 1024.0);
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
let SAVER_STYLES = [ "full", "clock", "line", "matrix", "logo", "off" ];
// Стили-сцены заставки -> индекс сцены в kmod (almond3s-lcd scene N).
// Матрица = 0, наш баннер-лого = 1. Остальные сцены вырезаны из драйвера.
let SAVER_SCENE_MAP = { "matrix": 0, "logo": 1 };

function saver_style() {
    let v = ucur ? ucur.get("almond3s", "display", "saver_style") : null;
    for (let x in SAVER_STYLES) if (x == v) return v;
    return "full";
}

// Индекс сцены-заставки для стиля (или null для обычных стилей). Определён
// ПОСЛЕ saver_style: ucode не поднимает объявления, а функция его зовёт.
function saver_scene_of(v) {
    return SAVER_SCENE_MAP[v ?? saver_style()];
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
    return { x: GX, y: 36, w: 56, h: 32 };
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
    let b  = ucur ? ucur.get("almond3s", "display", "night_bright") : null;
    return {
        on:   (on == null || on == "") ? true : (on == "1"),
        from: clampi(int(+(f ?? 22)), 0, 23),
        to:   clampi(int(+(t ?? 6)), 0, 23),
        bright: clampi(int(+((b == null || b == "") ? 15 : b)), 3, 50),
    };
}

let NIGHT_BRIGHT_STEPS = [ 3, 5, 7, 10, 15 ];

function nbright_btn(i) {
    return { x: 96 + i * 44, y: 132, w: 40, h: 22 };
}

// Что именно делать ночью. Раньше режим влиял только на экран, поэтому и жил
// внутри «Заставки»; теперь это расписание для устройства целиком.
let NIGHT_ACTS = [
    { key: "night_wifi",  label: "Wi-Fi off" },
    { key: "night_green", label: "Green saver", def: true },
];

// У ночи своя степень тепла, как своя яркость: дневное значение живёт на
// «Экране» отдельно и возвращается утром. Ноль - ночью тепло не трогаем.
let NIGHT_WARM_STEPS = [ 0, 30, 60, 100 ];

function nwarm_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "night_warm_lvl") : null;
    v = (v == null || v == "") ? 0 : int(+v);
    for (let i = 0; i < length(NIGHT_WARM_STEPS); i++)
        if (NIGHT_WARM_STEPS[i] == v) return v;
    return 0;
}

function nwarm_btn(i) {
    return { x: 96 + i * 44, y: 158, w: 40, h: 22 };
}

function nact_btn(i) {
    return { x: i == 0 ? 8 : 164, y: 184, w: 148, h: 22 };
}

function night_act(key) {
    let v = ucur ? ucur.get("almond3s", "display", key) : null;
    if (v == null || v == "") {
        // Умолчание берём из таблицы: зелёная заставка была зашита в код и
        // работала всегда, поэтому по умолчанию она остаётся включённой.
        for (let i = 0; i < length(NIGHT_ACTS); i++)
            if (NIGHT_ACTS[i].key == key) return NIGHT_ACTS[i].def == true;
        return false;
    }
    return (v == "1");
}

function night_act_set(key, on) {
    if (!ucur) return;
    ucur.set("almond3s", "display", key, on ? "1" : "0");
    ucur.commit("almond3s");
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
    // Шесть стилей в один ряд (4 обычных + Матрица + Лого): у́же кнопки, чтобы
    // не двигать блоки Shift/Night ниже.
    return { x: 8 + i * 52, y: 96, w: 48, h: 30 };
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

// Страницы активного ввода не должны засыпать посреди работы: набор пароля
// на клавиатуре и рисование иконки в редакторе.
function screen_keep_awake() {
    return st.page == "kbd" || st.page == "iconedit" || st.page == "term";
}

function saver_timeout() {
    let v = saver_cfg();
    return v > 0 ? v : 999999999;
}

function style_label(v) {
    if (v == "full")   return tr("Weather");
    if (v == "clock")  return tr("Clock");
    if (v == "line")   return tr("Line");
    if (v == "matrix") return tr("Matrix");
    if (v == "logo")   return tr("Logo");
    return tr("Off");
}

function saver_label(v) {
    if (v == 0) return tr("Never");
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
    return { x: 10, y: 150, w: 300, h: 36 };
}

function svnight_btn() {
    return { x: 150, y: 150, w: 160, h: 36 };
}

// Язык - одной кнопкой в правом верхнем углу: флаг и код языка.
function lang_btn() {
    return { x: GR - 74, y: 36, w: 74, h: 32 };
}

function font_btn() {
    return { x: GX + 64, y: 36, w: GR - 74 - GG - (GX + 64), h: 32 };
}

// Два тумблера в одной строке: иконки меню слева, фон-градиент справа - по
// колонкам сетки.
function micons_btn() { return { x: GX,             y: 72, w: GCOL, h: 26 }; }
function grad_btn()   { return { x: GX + GCOL + GG, y: 72, w: GCOL, h: 26 }; }

// Переключатели: гашение, сдвиг, ночь. Состояние показывает цвет полоски,
// поэтому слова «вкл/выкл» на кнопках не нужны.
// Семь шагов в ряд: ряд занимает всю ширину, подпись уезжает строкой выше -
// иначе на кнопку остаётся 28 пикселей, это уже уже пальца.
function bright_btn(i) {
    return { x: GX + i * 44, y: 118, w: 40, h: 48 };
}

function tog_btn(i) {
    if (i == 0) return { x: 10, y: 64, w: 148, h: 38 };
    return { x: 166, y: 64, w: 144, h: 38 };
}

// Часы «с» и «до» живут на своей странице: две группы «минус - значение - плюс».
function hour_btn(row, which) {
    let y = row == 0 ? 60 : 96;
    if (which < 0) return { x: 96, y: y, w: 52, h: 32 };
    if (which > 0) return { x: 214, y: y, w: 52, h: 32 };
    return { x: 154, y: y, w: 54, h: 32 };
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

// Пиксель-флаги 15x10 по коду страны. Названия серверов в SSClash приходят с
// эмодзи-флагами, которые шрифт 5x7 не умеет; рисуем их сами по коду, а имя
// чистим от эмодзи. Что не знаем - серый прямоугольник с буквами кода.
let FLAG_C = { w:"#F5F5F5", r:"#D52B1E", b:"#0039A6", k:"#161616",
               y:"#FFD500", g:"#009246", o:"#FF7900", c:"#3C8CE0" };
let FLAGS = {
    RU:["h3","w","b","r"], DE:["h3","k","r","y"], NL:["h3","r","w","b"],
    AT:["h3","r","w","r"], HU:["h3","r","w","g"], EE:["h3","b","k","w"],
    BG:["h3","w","g","r"], LT:["h3","y","g","r"], LU:["h3","r","w","c"],
    LV:["h3","r","w","r"], ES:["h3","r","y","r"], IN:["h3","o","w","g"],
    AR:["h3","c","w","c"], CO:["h3","y","b","r"], AM:["h3","r","b","o"],
    UA:["h2","b","y"], PL:["h2","w","r"], ID:["h2","r","w"], MC:["h2","r","w"],
    FR:["v3","b","w","r"], IT:["v3","g","w","r"], IE:["v3","g","w","o"],
    RO:["v3","b","y","r"], BE:["v3","k","y","r"], CA:["v3","r","w","r"],
    MX:["v3","g","w","r"], NG:["v3","g","w","g"],
    FI:["cross","w","b"], SE:["cross","b","y"], DK:["cross","r","w"],
    NO:["cross","r","w"], IS:["cross","b","w"], GE:["cross","w","r"],
    PT:["v3","g","r","r"],
    US:["us"], GB:["gb"], UK:["gb"], JP:["jp"], KR:["jp"], CH:["ch"], TR:["tr"],
    KZ:["kz"], CN:["cn"], VN:["vn"], BR:["br"],
    EU:["eu"], AE:["ae"], HK:["hk"], BY:["by"], AU:["au"], PH:["ph"], SG:["sg"],
};
function draw_cflag(x, y, cc) {
    let W = 15, H = 10, f = FLAGS[cc];
    if (!f) {
        lcd_rect(x, y, W, H, C.btn);
        lcd_rect(x, y, W, 1, C.border); lcd_rect(x, y + H - 1, W, 1, C.border);
        if (cc != "") lcd_text(x + 2, y + 2, cc, C.gray, C.btn, 1);
        return;
    }
    let k = f[0];
    if (k == "h3") {
        lcd_rect(x, y, W, 3, FLAG_C[f[1]]); lcd_rect(x, y+3, W, 4, FLAG_C[f[2]]); lcd_rect(x, y+7, W, 3, FLAG_C[f[3]]);
    } else if (k == "h2") {
        lcd_rect(x, y, W, 5, FLAG_C[f[1]]); lcd_rect(x, y+5, W, 5, FLAG_C[f[2]]);
    } else if (k == "v3") {
        lcd_rect(x, y, 5, H, FLAG_C[f[1]]); lcd_rect(x+5, y, 5, H, FLAG_C[f[2]]); lcd_rect(x+10, y, 5, H, FLAG_C[f[3]]);
    } else if (k == "cross") {
        lcd_rect(x, y, W, H, FLAG_C[f[1]]); lcd_rect(x+4, y, 2, H, FLAG_C[f[2]]); lcd_rect(x, y+4, W, 2, FLAG_C[f[2]]);
    } else if (k == "us") {
        for (let i = 0; i < H; i += 2) lcd_rect(x, y+i, W, 1, (i % 4 == 0) ? FLAG_C.r : FLAG_C.w);
        lcd_rect(x, y, 6, 5, FLAG_C.b);
    } else if (k == "gb") {
        lcd_rect(x, y, W, H, FLAG_C.b); lcd_rect(x, y+4, W, 2, FLAG_C.r); lcd_rect(x+6, y, 3, H, FLAG_C.r);
    } else if (k == "jp") {
        lcd_rect(x, y, W, H, FLAG_C.w); lcd_rect(x+5, y+3, 5, 4, FLAG_C.r);
    } else if (k == "ch") {
        lcd_rect(x, y, W, H, FLAG_C.r); lcd_rect(x+6, y+2, 3, 6, FLAG_C.w); lcd_rect(x+4, y+4, 7, 2, FLAG_C.w);
    } else if (k == "tr") {
        lcd_rect(x, y, W, H, FLAG_C.r); lcd_rect(x+4, y+3, 5, 4, FLAG_C.w); lcd_rect(x+6, y+3, 4, 4, FLAG_C.r);
    } else if (k == "kz") {
        lcd_rect(x, y, W, H, FLAG_C.c); lcd_rect(x+5, y+3, 5, 4, FLAG_C.y);   // солнце
    } else if (k == "cn") {
        lcd_rect(x, y, W, H, FLAG_C.r); lcd_rect(x+2, y+2, 3, 3, FLAG_C.y);   // звезда в углу
    } else if (k == "vn") {
        lcd_rect(x, y, W, H, FLAG_C.r); lcd_rect(x+5, y+3, 5, 4, FLAG_C.y);   // звезда по центру
    } else if (k == "br") {
        lcd_rect(x, y, W, H, FLAG_C.g); lcd_rect(x+4, y+2, 7, 6, FLAG_C.y);   // ромб
        lcd_rect(x+6, y+3, 3, 4, FLAG_C.b);                                    // круг
    } else if (k == "eu") {
        lcd_rect(x, y, W, H, FLAG_C.b);                                        // синее поле
        let sd = [[7,1],[10,2],[11,4],[10,7],[7,8],[4,7],[3,4],[4,2]];         // кольцо звёзд
        for (let s in sd) lcd_rect(x+s[0], y+s[1], 1, 1, FLAG_C.y);
    } else if (k == "ae") {
        lcd_rect(x, y, 5, H, FLAG_C.r);                                        // красная полоса слева
        lcd_rect(x+5, y, 10, 3, FLAG_C.g); lcd_rect(x+5, y+3, 10, 4, FLAG_C.w); lcd_rect(x+5, y+7, 10, 3, FLAG_C.k);
    } else if (k == "hk") {
        lcd_rect(x, y, W, H, FLAG_C.r); lcd_rect(x+5, y+3, 5, 4, FLAG_C.w);   // белый цветок
    } else if (k == "by") {
        lcd_rect(x, y, W, 7, FLAG_C.r); lcd_rect(x, y+7, W, 3, FLAG_C.g);     // красный/зелёный
        lcd_rect(x, y, 3, H, FLAG_C.w); lcd_rect(x+1, y, 1, H, FLAG_C.r);     // узорная полоса слева
    } else if (k == "au") {
        lcd_rect(x, y, W, H, FLAG_C.b);
        lcd_rect(x, y, 7, 5, FLAG_C.b); lcd_rect(x, y+2, 7, 1, FLAG_C.r); lcd_rect(x+3, y, 1, 5, FLAG_C.r);  // юнион
        lcd_rect(x+9, y+6, 2, 2, FLAG_C.w);                                    // звезда
    } else if (k == "ph") {
        lcd_rect(x, y, W, 5, FLAG_C.b); lcd_rect(x, y+5, W, 5, FLAG_C.r);     // синий/красный
        lcd_rect(x, y+2, 6, 6, FLAG_C.w); lcd_rect(x+1, y+4, 3, 2, FLAG_C.y); // белый клин + солнце
    } else if (k == "sg") {
        lcd_rect(x, y, W, 5, FLAG_C.r); lcd_rect(x, y+5, W, 5, FLAG_C.w);     // красный/белый
        lcd_rect(x+2, y+1, 3, 3, FLAG_C.w);                                    // полумесяц
    }
}

// Жирная зелёная стрелка вправо - для DIRECT.
function draw_direct_icon(x, y) {
    lcd_rect(x + 1, y + 3, 8, 4, C.green);       // древко
    lcd_rect(x + 8, y + 1, 2, 8, C.green);       // основание головки
    lcd_rect(x + 10, y + 2, 2, 6, C.green);
    lcd_rect(x + 12, y + 4, 2, 2, C.green);      // остриё
}
// Красный перечёркнутый круг - для REJECT/REJECT-DROP.
function draw_reject_icon(x, y) {
    let cx = 7, cy = 5;
    for (let ry = 0; ry <= 10; ry++)
        for (let rx = 0; rx <= 13; rx++) {
            let dx = rx - cx, dy = ry - cy, d2 = dx * dx + dy * dy;
            if (d2 >= 11 && d2 <= 22) lcd_rect(x + rx, y + ry, 1, 1, C.red);
        }
    for (let t = -3; t <= 3; t++) lcd_rect(x + cx + t, y + cy - t, 1, 1, C.red);  // слэш
}
// Иконка узла по имени: DIRECT/REJECT - свои значки, иначе флаг по коду; если
// кода нет и это не спец-узел - НИЧЕГО (без пустого квадрата). uc() для регистра.
function draw_node_icon(x, y, cc, clean) {
    let u = uc(clean ?? "");
    if (u == "DIRECT" || u == "PASS") { draw_direct_icon(x, y); return; }
    if (substr(u, 0, 6) == "REJECT" || u == "BLOCK") { draw_reject_icon(x, y); return; }
    if (cc != "") draw_cflag(x, y, cc);
}

// Разбор имени узла: вытаскиваем код страны из эмодзи-флага (пара regional
// indicator) и отдаём имя, вычищенное от эмодзи/символов, которых нет в шрифте.
// UTF-8 разбираем вручную: ord() даёт байты, кодпойнты собираем сами.
function vpn_flag(name) {
    name ??= "";
    let L = length(name), i = 0, cc = "", ri = "", out = "";
    while (i < L) {
        let b = ord(name, i), cp = b, nb = 1;
        if (b >= 0xF0)      { nb = 4; cp = b & 0x07; }
        else if (b >= 0xE0) { nb = 3; cp = b & 0x0F; }
        else if (b >= 0xC0) { nb = 2; cp = b & 0x1F; }
        if (i + nb > L) break;
        for (let k = 1; k < nb; k++) cp = (cp << 6) | (ord(name, i + k) & 0x3F);
        let start = i; i += nb;
        if (cp >= 0x1F1E6 && cp <= 0x1F1FF) { if (length(ri) < 2) ri += chr(cp - 0x1F1E6 + 65); continue; }
        // выкидываем эмодзи/пиктограммы/стрелки/селекторы - шрифт их не рисует
        if (cp >= 0x1F000 || (cp >= 0x2600 && cp <= 0x27BF) || (cp >= 0x2B00 && cp <= 0x2BFF)
            || (cp >= 0x2190 && cp <= 0x21FF) || (cp >= 0xFE00 && cp <= 0xFE0F)) continue;
        for (let k = 0; k < nb; k++) out += chr(ord(name, start + k));
    }
    if (length(ri) == 2) cc = ri;
    // подчищаем края от лишних пробелов и осиротевших разделителей
    out = trim(out);
    while (length(out) > 0 && (substr(out, 0, 1) == "|" || substr(out, 0, 1) == "-")) out = trim(substr(out, 1));
    return [ cc, out ];
}


function btn_pos(idx) {
    let col = (idx - 1) % COLS;
    let row = int((idx - 1) / COLS);
    // По горизонтали - та же сетка, что у карточек (поля GX, колонка GCOL,
    // зазор GG): меню выравнивается с остальными страницами. По вертикали
    // шаг прежний - три ряда плиток 68px впритык укладываются в высоту.
    return {
        x: GX + col * (GCOL + GG),
        y: START_Y + row * (BTN_H + BTN_PAD),
        w: GCOL,
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
// Маленький колокольчик будильника (~13x12) для статус-бара. Блик сверху и
// затемнённый язычок дают объём. Для ночного/иного цвета рисуем плоско.
function draw_alarm_icon(x, y, col) {
    let plain = (col != C.yellow);
    let hi = plain ? col : "#FFCF9E";    // тёплый блик
    let sh = plain ? col : "#A85820";    // тень язычка
    lcd_rect(x + 5, y,     3, 1, col);   // ручка
    lcd_rect(x + 4, y + 1, 5, 2, col);   // купол
    lcd_rect(x + 3, y + 3, 7, 3, col);   // тело
    lcd_rect(x + 2, y + 6, 9, 2, col);   // расширение
    lcd_rect(x + 1, y + 8, 11, 1, col);  // основание
    lcd_rect(x + 5, y + 9, 3, 2, sh);    // язычок (тень)
    // Блик сверху-справа (свет падает с верхнего-правого угла).
    if (!plain) {
        lcd_rect(x + 7, y + 1, 2, 1, hi);   // верх-правый купола
        lcd_rect(x + 8, y + 3, 1, 2, hi);   // правый край тела
    }
}

// Значок Wi-Fi статус-бара: та же сетка, что редактируется в редакторе (иконка
// wifi_st). Объявлены рано, потому что draw_status_row выше по файлу, чем общий
// движок иконок (draw_micon/MICONS), а у ucode нет hoisting. MICON_CUSTOM
// объявлен здесь и наполняется micon_load_custom ниже - это один и тот же
// глобальный объект. Правки из редактора сразу видны в статус-баре.
let MICON_CUSTOM = {};
let WIFI_ST_DEF = [
    "......#########......",
    "....#############....",
    "...###.........###...",
    "..##.............##..",
    "..#....#######....#..",
    ".....###########.....",
    "....###.......###....",
    "....#...........#....",
    "........#####........",
    ".......#######.......",
    ".......#.....#.......",
    ".....................",
    ".........###.........",
    "..........#..........",
];
// Плашка VPN и полумесяц - в том же формате и рядом с Wi-Fi, по той же
// причине: статус-строка выше по файлу, чем движок иконок, а ucode не
// хойстит. Буквы в плашке - дырки в белом прямоугольнике, начертание взято
// из шрифта интерфейса, поэтому читается так же, как обычный текст.
let VPN_ST_DEF = [
    ".....................",
    "#####################",
    "#####################",
    "##.###.#....##.###.##",
    "##.###.#.###.#.###.##",
    "##.###.#.###.#..##.##",
    "##.###.#....##.#.#.##",
    "##.###.#.#####.##..##",
    "###.#.##.#####.###.##",
    "####.###.#####.###.##",
    "#####################",
    "#####################",
    ".....................",
    ".....................",
];
let MOON_ST_DEF = [
    ".....................",
    ".......#####.........",
    "......####...........",
    ".....####............",
    "....####.............",
    "....####.............",
    "....####.............",
    "....####.............",
    "....####.............",
    "....####.............",
    ".....####............",
    "......####...........",
    ".......#####.........",
    ".....................",
];

// Один отрисовщик на все значки статус-строки: правки из редактора лежат в
// MICON_CUSTOM и перекрывают вшитый арт.
function draw_st_icon(x, y, name, def, col) {
    let cu = MICON_CUSTOM[name];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c]) lcd_rect(x + c, y + r, 1, 1, cu.pal[cu.g[r][c] - 1]);
        return;
    }
    for (let r = 0; r < length(def); r++) {
        let row = def[r];
        for (let c = 0; c < length(row); c++)
            if (substr(row, c, 1) == "#") lcd_rect(x + c, y + r, 1, 1, col);
    }
}

function draw_wifi_status(x, y, col) {
    let cu = MICON_CUSTOM["wifi_st"];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c]) lcd_rect(x + c, y + r, 1, 1, cu.pal[cu.g[r][c] - 1]);
        return;
    }
    for (let r = 0; r < length(WIFI_ST_DEF); r++) {
        let row = WIFI_ST_DEF[r];
        for (let c = 0; c < length(row); c++)
            if (substr(row, c, 1) == "#") lcd_rect(x + c, y + r, 1, 1, col);
    }
}

// RJ45-штекер для статус-бара: контактная планка, корпус, кабель. Рисуем
// цветом переданного col (фон прозрачный), как значок Wi-Fi.
let ETH_DEF = [
    "..###########..",
    ".#############.",
    ".#...........#.",
    ".#...........#.",
    ".#...........#.",
    ".#...........#.",
    ".#############.",
    "....#######....",
    "......###......",
    "......###......",
    "......###......",
    "...............",
    "...............",
    "...............",
];
function draw_eth_icon(x, y, col) {
    let cu = MICON_CUSTOM["eth"];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c]) lcd_rect(x + c, y + r, 1, 1, cu.pal[cu.g[r][c] - 1]);
        return;
    }
    for (let r = 0; r < length(ETH_DEF); r++) {
        let row = ETH_DEF[r];
        for (let c = 0; c < length(row); c++)
            if (substr(row, c, 1) == "#") lcd_rect(x + c, y + r, 1, 1, col);
    }
}

// Кнопка «Fn» терминала (30x20, рамка + буквы) - редактируемая иконка. Рисуем
// из кастома, иначе из вшитой сетки цветом вызова.
let FN_DEF = [
    "##############################",
    "##############################",
    "##..........................##",
    "##..........................##",
    "##..........................##",
    "##...#########..............##",
    "##...#########..............##",
    "##...##.....................##",
    "##...##.........########....##",
    "##...#######....########....##",
    "##...#######....##....##....##",
    "##...##.........##....##....##",
    "##...##.........##....##....##",
    "##...##.........##....##....##",
    "##...##.........##....##....##",
    "##..........................##",
    "##..........................##",
    "##..........................##",
    "##############################",
    "##############################",
];
function draw_fn_icon(x, y, col) {
    let cu = MICON_CUSTOM["fn"];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c]) lcd_rect(x + c, y + r, 1, 1, cu.pal[cu.g[r][c] - 1]);
        return;
    }
    for (let r = 0; r < length(FN_DEF); r++) {
        let row = FN_DEF[r];
        for (let c = 0; c < length(row); c++)
            if (substr(row, c, 1) == "#") lcd_rect(x + c, y + r, 1, 1, col);
    }
}

// Тип активного аплинка по кэшу netpri (тот же, что «Сеть»): запись с наименьшей
// метрикой -> её type ("wifi"/"wan"/"modem"/"other"). Кэш 4с - статус-строка
// рисуется на каждой перерисовке. Путь литералом: NETPRI_CACHE объявлен ниже.
let uplink_kind_v = "", uplink_kind_t = 0;
function uplink_kind() {
    let now = time();
    if (now - uplink_kind_t >= 4) {
        uplink_kind_t = now;
        uplink_kind_v = "";
        let raw = fs.readfile("/tmp/lcd_netpri.json");
        if (raw) {
            try {
                let j = json(raw);
                if (type(j) == "array") {
                    let best = null;
                    for (let e in j) {
                        if (!e?.iface) continue;
                        if (best == null || int(+(e.metric ?? 999)) < int(+(best.metric ?? 999)))
                            best = e;
                    }
                    if (best) uplink_kind_v = best.type ?? "";
                }
            } catch (e) {}
        }
    }
    return uplink_kind_v;
}

// Значок VPN в статус-строке: белая плашка со словом внутри. Состояние
// спрашиваем у того же vpn_clash.sh, что и страница VPN, но не на каждом
// тике - запрос идёт в API михомо, это форк и сетевой вызов.
function clash_running() {
    if (!vpn_present()) return false;
    let p = fs.popen(SCRIPTS + "/vpn_clash.sh status 2>/dev/null", "r");
    if (!p) return false;
    let out = p.read("all") ?? "";
    p.close();
    return index(out, "\"running\":1") >= 0;
}



function draw_status_row(y, o) {
    let d = st.data;
    let sig = sig_state();
    let bg = o?.bg ?? C.hdr;
    let mono = o?.mono;            /* ночной цвет или null */
    let empty = o?.empty ?? C.dim;

    // Откуда роутер берёт интернет (по netpri): Wi-Fi STA -> значок Wi-Fi,
    // кабель в WAN -> значок RJ45, модем -> ярлык технологии (4G/5G).
    let kind = o?.no_sig ? "" : uplink_kind();

    if (!o?.no_sig) {
        draw_sigbars(4, y, sig.bars, mono ?? sig.color, empty);
        if (kind == "wifi") {
            // Значок Wi-Fi из редактируемой сетки wifi_st (правки видны вживую).
            draw_wifi_status(50, y, mono ?? C.cyan);
        } else if (kind == "wan") {
            draw_eth_icon(50, y, mono ?? C.cyan);
        } else {
            let rat = tcut(rat_label(d?.lte?.mode ?? ""), 4);
            if (rat != "" && rat != "-")
                lcd_text(50, y + 1, rat, mono ?? C.cyan, bg, 2);
        }
    }
    let rat = o?.no_sig ? "" : tcut(rat_label(d?.lte?.mode ?? ""), 4);
    let rat_x = 50;

    let tstr = clock_str();
    let t_x = int((LCD_W - tlen(tstr) * 12) / 2);

    // Конвертик встаёт сразу за ярлыком/значком аплинка: место зависит от его
    // ширины (значки Wi-Fi/RJ45 фиксированы). К часам ближе 8px не идём.
    if (!o?.no_env && int(d?.sms_new ?? 0) > 0) {
        let lead = kind == "wifi" ? 23 : (kind == "wan" ? 17
                 : (rat == "" || rat == "-" ? 0 : tlen(rat) * 12));
        let ex = (o?.no_sig ? 4 : rat_x) + (lead > 0 ? lead + 8 : 0);
        if (o?.time && ex + ENV_W + 8 > t_x) ex = t_x - ENV_W - 8;
        draw_env_icon(ex, y, 1, mono ? "#0A2A16" : null, mono);
    }

    if (o?.time)
        lcd_text(t_x, y + 1, tstr, o?.time_color ?? C.white, bg, 2);

    let bat = d?.battery;
    // full = защёлка «заряд завершён» от коллектора: иконке это «полная
    // под адаптером» - зелёная рамка, мигать нечему (pct уже 100).
    let bchg = (bat?.charging || bat?.full) && !bat?.no_battery;
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

    // Будильник включён - колокольчик слева от заряда (на всех экранах и на
    // заставке-часах, которая тоже рисует этот статус-бар).
    // Ширину зоны процентов считаем ОДИН раз и снаружи: к ней привязаны и
    // колокольчик, и значок VPN. Раньше она объявлялась внутри блока
    // будильника, и обращение к ней снаружи роняло бы демон - ucode не
    // прощает необъявленную переменную, а поймать это можно было только с
    // включённым VPN.
    let pw = (o?.pct && !(bat?.no_battery || bpct < 0))
           ? tlen(sprintf("%d", bpct)) * 12 + 6 : 0;
    // Без процентов колокольчик отодвигаем от батареи до зазора 8px (как
    // между шкалой сигнала и «4G»); с процентами расстояние уже нормальное.
    let bell_x = bat_x - pw - (pw > 0 ? 17 : 20);

    if (st.alarm_on)
        draw_alarm_icon(bell_x, y + 2, mono ?? C.yellow);

    // Справа налево: плашка VPN, за ней полумесяц ночного режима.
    let cur = st.alarm_on ? bell_x - 6 : bell_x + 14;
    if (st.vpn_on) {
        cur -= 21;
        draw_st_icon(cur, y + 1, "vpn", VPN_ST_DEF, "#FFFFFF");
        cur -= 5;
    }
    if (night_now()) {
        cur -= 21;
        draw_st_icon(cur, y + 1, "moon", MOON_ST_DEF, mono ?? "#8B949E");
    }
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

// Пиксель-арт иконки плиток меню, 14x14, рисуются в масштабе 2 (28x28 -
// высота двух строк текста плитки). Слева от текста, по мотивам эмодзи.
let MICONS = {
    // Wi-Fi для статус-бара (когда аплинк идёт через STA). Та же сетка, что
    // рисует статус-строка (WIFI_ST_DEF); правится как обычная иконка.
    wifi_st: WIFI_ST_DEF,
    // Значок RJ45/WAN статус-бара - тоже редактируемый (ETH_DEF).
    eth: ETH_DEF,
    vpn: VPN_ST_DEF,
    moon: MOON_ST_DEF,
    // Кнопка «Fn» терминала - редактируемая (FN_DEF).
    fn: FN_DEF,
    // конвертик - нарисован в редакторе на роутере
    sms: [
        ".111111111111.",
        "18111111111181",
        "11811111111811",
        "11181111118111",
        "11118111181111",
        "11118811881111",
        "11181188118111",
        "11811111111811",
        "18111111111181",
        ".111111111111.",
        "..............",
        "..............",
        "..............",
        "..............",
    ],
    // терминал: окно (белая рамка) с зелёным приглашением >_
    term: [
        "..............",
        ".111111111111.",
        ".1..........1.",
        ".1.5........1.",
        ".1..5.......1.",
        ".1...5......1.",
        ".1..5.......1.",
        ".1.5........1.",
        ".1.....5555.1.",
        ".1..........1.",
        ".111111111111.",
        "..............",
        "..............",
        "..............",
    ],
    // молния - нарисован в редакторе на роутере
    bolt: [
        "....433333....",
        "....43333.....",
        "...43333......",
        "...4333.......",
        "..43333.......",
        "..43333333....",
        ".43333333.....",
        "....4333......",
        "....433.......",
        "...433........",
        "...43.........",
        "..43..........",
        "..3...........",
        ".3............",
    ],
    network: [
        "..............",
        "....666666....",
        "..6656666666..",
        ".665566666556.",
        ".666666655666.",
        ".665566666666.",
        ".666666556666.",
        ".655666666566.",
        ".666655666666.",
        ".665666665566.",
        "..6666556666..",
        "....666666....",
        "..............",
        "..............",
    ],
    wifi: [
        "..............",
        "...11111111...",
        ".11........11.",
        "1............1",
        "....111111....",
        "..11......11..",
        ".1..........1.",
        ".....1111.....",
        "...11....11...",
        "..............",
        "......11......",
        "......11......",
        "..............",
        "..............",
    ],
    modem: {
        pal: [ "#FFFFFF", "#F85149", "#FFA930", "#FFD866",
               "#3FB950", "#58A6FF", "#B180F0", "#484F58" ],
        art: [
        "..............",
        ".888888888888.",
        ".888888888888.",
        ".855555588118.",
        ".855555588888.",
        ".855555588118.",
        ".888888888888.",
        ".811811811888.",
        ".888888888888.",
        "..............",
        "..............",
        "..............",
        "..............",
        "..............",
        ],
    },
    traffic: [
        "..............",
        "....##........",
        "...####.......",
        "..######......",
        "....##....##..",
        "....##....##..",
        "....##....##..",
        "....##....##..",
        "....##....##..",
        "....##....##..",
        "..........##..",
        "......######..",
        ".......####...",
        "........##....",
    ],
    info: [
        "..............",
        "....######....",
        "..##......##..",
        ".#....##....#.",
        ".#....##....#.",
        "#............#",
        "#.....##.....#",
        "#.....##.....#",
        "#.....##.....#",
        ".#....##....#.",
        ".#....##....#.",
        "..##......##..",
        "....######....",
        "..............",
    ],
    weather: [
        "..............",
        "..............",
        "....1111......",
        "...111111.11..",
        "..1111111111..",
        ".111111111111.",
        ".111111111111.",
        "1111111111111.",
        ".888888888888.",
        "..............",
        "..............",
        "..............",
        "..............",
        "..............",
    ],
    services: [
        ".############.",
        ".#..........#.",
        ".#........#.#.",
        ".#.......##.#.",
        ".#.#....##..#.",
        ".#.##..##...#.",
        ".#..####....#.",
        ".#...##.....#.",
        ".#..........#.",
        ".############.",
        "..............",
        "..............",
        "..............",
        "..............",
    ],
    display: [
        "11111111111111",
        "18888888888881",
        "18..........81",
        "18..........81",
        "18..........81",
        "18..........81",
        "18..........81",
        "18..........81",
        "18888888888881",
        "11111111111111",
        "..............",
        "..............",
        "..............",
        "..............",
    ],
    saver: [
        ".....######...",
        "...###....##..",
        "..##........#.",
        ".##...........",
        ".#............",
        ".#............",
        ".#............",
        ".##...........",
        "..##........#.",
        "...###....##..",
        ".....######...",
        "..............",
        "..............",
        "..............",
    ],
    // диод-огонёк - нарисован в редакторе на роутере
    led: [
        ".....1111.....",
        "....111111....",
        "....111111....",
        "....111111....",
        "....111111....",
        ".....1111.....",
        "..............",
        "..............",
        "..............",
        "..............",
        "..............",
        "..............",
        "..............",
        "..............",
    ],
    sound: [
        "..............",
        "........1.....",
        ".......11..8..",
        "..8...111...8.",
        ".88888111.8.8.",
        ".88888111.8.8.",
        ".88888111.8.8.",
        ".88888111.8.8.",
        ".88888111.8.8.",
        "..8...111...8.",
        ".......11..8..",
        "........1.....",
        "..............",
        "..............",
    ],
    // зигби - нарисован в редакторе на роутере
    // геймпад: крестовина слева, две кнопки справа
    game: [
        "..............",
        "..............",
        "..............",
        "...88888888...",
        ".888888888888.",
        "88881888855888",
        "88811188888888",
        "88881888822888",
        ".888888888888.",
        "..8888....8888",
        "..888......888",
        "..............",
        "..............",
        "..............",
    ],
    zigbee: [
        "....2111111...",
        "...212222221..",
        "..21222222111.",
        ".2222222211112",
        ".2222222111122",
        ".2222221111222",
        ".2222211112222",
        ".2222111122222",
        ".2221111222222",
        ".2211112222212",
        "..21112222212.",
        "...211111112..",
        "....2222222...",
        "..............",
    ],
    debug: {
        pal: [ "#F778BA", "#FFA8D8", "#BF4B8A", "#FFD866",
               "#3FB950", "#58A6FF", "#B180F0", "#8B949E" ],
        art: [
        "..............",
        "....111111....",
        "..1111111111..",
        ".111311131111.",
        ".113111311311.",
        ".131131131131.",
        ".111311131113.",
        ".131131131311.",
        ".113111311131.",
        "..1131131311..",
        "...11311311...",
        ".....1111.....",
        "..............",
        "..............",
        ],
    },
    editor: {
        pal: [ "#FFFFFF", "#F778BA", "#FFA930", "#FFD866",
               "#3FB950", "#58A6FF", "#484F58", "#8B949E" ],
        art: [
        "..........22..",
        ".........2228.",
        ".........2833.",
        "........8333..",
        ".......3333...",
        "......3333....",
        ".....3333.....",
        "....3333......",
        "...4333.......",
        "..443.........",
        ".74...........",
        "7.............",
        "..............",
        "..............",
        ],
    },
    reset: [
        "..............",
        ".....#####....",
        "...##.....##..",
        "..#.........#.",
        ".#....#......#",
        ".#....##......",
        ".#....###.....",
        ".#............",
        ".#...........#",
        "..#.........#.",
        "...##.....##..",
        ".....#####..#.",
        "...........##.",
        "..........###.",
    ],
    reboot: [
        "..............",
        "......##......",
        "......##......",
        "...#..##..#...",
        "..#...##...#..",
        ".#....##....#.",
        ".#....##....#.",
        ".#..........#.",
        ".#..........#.",
        ".#..........#.",
        "..#........#..",
        "...##....##...",
        ".....####.....",
        "..............",
    ],
};

let ED_PAL_DEF = [ "#FFFFFF", "#F85149", "#FFA930", "#FFD866",
                   "#3FB950", "#58A6FF", "#B180F0", "#8B949E" ];
let ED_PAL = [ "#FFFFFF", "#F85149", "#FFA930", "#FFD866",
               "#3FB950", "#58A6FF", "#B180F0", "#8B949E" ];

// Расширенный выбор цвета: перекрашивает текущий слот палитры.
let ED_COLORS = [
    "#FFFFFF", "#C9D1D9", "#8B949E", "#484F58", "#21262D", "#101418",
    "#FFB3AB", "#F85149", "#A40E26", "#FFC680", "#FFA930", "#B25E00",
    "#FFE28A", "#FFD866", "#D29922", "#7EE2A8", "#3FB950", "#1F6F3D",
    "#7CE4E4", "#39C5CF", "#0E7490", "#A5C9FF", "#58A6FF", "#1F6FEB",
    "#D2A8FF", "#B180F0", "#8250DF", "#FFA8D8", "#F778BA", "#BF4B8A",
];

// Переопределения иконок, нарисованные в редакторе: файлы-сетки в
// /etc/almond3s/icons/<имя>.txt берут верх над вшитым пиксель-артом.
// MICON_CUSTOM объявлен выше (нужен статус-бару, у ucode нет hoisting).

function micon_load_custom() {
    let names = fs.lsdir("/etc/almond3s/icons") ?? [];
    for (let f in names) {
        let m = match(f, /^([a-z0-9_]+)\.txt$/);
        if (!m) continue;
        let raw = fs.readfile("/etc/almond3s/icons/" + f);
        if (!raw) continue;
        let grid = [];
        let pal = null;
        let w = 0;
        for (let line in split(raw, "\n")) {
            let lm = match(line, /^colors:(.*)$/);
            if (lm) {
                pal = [];
                for (let pm in match(lm[1], /[0-9]=(#[0-9A-Fa-f]{6})/g))
                    push(pal, pm[1]);
                continue;
            }
            // Строка сетки: только цифры/точки. Размер - по первой такой строке
            // (иконки теперь не только 14x14).
            if (!match(line, /^[0-8.]+$/)) continue;
            if (w == 0) w = length(line);
            if (length(line) != w) continue;
            let row = [];
            for (let c = 0; c < w; c++) {
                let ch = substr(line, c, 1);
                push(row, (ch >= "1" && ch <= "8") ? int(ch) : 0);
            }
            push(grid, row);
        }
        if (length(grid) >= 4 && w >= 4)
            MICON_CUSTOM[m[1]] = {
                g: grid, w: w, h: length(grid),
                pal: (pal != null && length(pal) == 8) ? pal : ED_PAL_DEF,
            };
    }
}
micon_load_custom();

function draw_micon(x, y, name, color, sc) {
    sc ??= 2;
    let cu = MICON_CUSTOM[name];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c])
                    lcd_rect(x + c * sc, y + r * sc, sc, sc, cu.pal[cu.g[r][c] - 1]);
        return;
    }
    let e = MICONS[name];
    if (!e) return;
    let art = e, pal = ED_PAL_DEF;
    if (type(e) == "object") {
        art = e.art;
        pal = e.pal ?? ED_PAL_DEF;
    }
    for (let r = 0; r < length(art); r++) {
        let row = art[r], rw = length(row), c = 0;
        while (c < rw) {
            let ch = substr(row, c, 1);
            if (ch == ".") { c++; continue; }
            let c0 = c;
            while (c < rw && substr(row, c, 1) == ch) c++;
            lcd_rect(x + c0 * sc, y + r * sc, (c - c0) * sc, sc,
                     ch == "#" ? color : pal[int(ch) - 1]);
        }
    }
}

// Ширина/высота иконки (кастом несёт w/h, вшитая - по размеру арта).
function micon_dim(name) {
    let cu = MICON_CUSTOM[name];
    if (cu) return [ cu.w, cu.h ];
    let e = MICONS[name];
    if (!e) return [ 14, 14 ];
    let art = (type(e) == "object") ? e.art : e;
    return [ length(art[0]), length(art) ];
}

// «Вдавленная» кнопка: тот же код отрисовки, но фон акцентный и весь
// контент смещён на 2 пикселя вправо-вниз. Никаких вторых вёрсток.
let menu_pressed = null;
let cell_arrow_pressed = null;   // листалка соты под пальцем: -1 / +1

function draw_btn(idx, title, subtitle, title_c, sub_c, bg_c, middle, icon, icon_c) {
    let b = btn_pos(idx);
    let pressed = (menu_pressed != null && menu_pressed == idx);
    let bg = pressed ? C.press : (bg_c ?? C.btn);
    let o = pressed ? 2 : 0;
    let tx = b.x + 8 + o;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    // Имитатор «выпуклости»: светлый кант снизу И справа. При нажатии кнопка
    // утапливается - оба канта убираем.
    if (!pressed) {
        lcd_rect(b.x, b.y + b.h - 3, b.w, 3, C.border);
        lcd_rect(b.x + b.w - 3, b.y, 3, b.h, C.border);
    }
    if (icon && MICONS_ON) {
        draw_micon(b.x + 8 + o, b.y + 14 + o, icon, icon_c ?? C.white, 2);
        tx = b.x + 42 + o;
    }
    lcd_text(tx, b.y + 14 + o, title, title_c ?? C.white, bg, 2);
    if (middle)
        lcd_text(tx, b.y + 33 + o, tcut(middle, 22), C.white, bg, 1);
    if (subtitle)
        lcd_text(tx, b.y + 44 + o, subtitle, sub_c ?? C.gray, bg, 1);
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
// Русские стемы - строчными, БЕЗ заглавной первой буквы: ucode-регулярки
// сравнивают по байтам, а флаг /i кириллицу не сворачивает (проверено), так
// что «Солнечно» ловим по «олнеч». Без этого при lang=ru wttr.in отдаёт
// описание по-русски, ни один латинский паттерн не совпадал и иконка всегда
// падала в дефолт «облачно» (баг: «Солнечно» с тучкой, поймано 15.08).
function weather_icon_key(desc) {
    let s = desc ?? "";
    if (match(s, /thunder/i) || match(s, /роза/))                    return "storm";
    if (match(s, /snow|sleet|blizzard|ice pellet/i) || match(s, /нег|етель/)) return "snow";
    if (match(s, /rain|drizzle|shower/i) || match(s, /ождь|орос|ивен/)) return "rain";
    if (match(s, /fog|mist/i) || match(s, /уман|ымка/))             return "fog";
    if (match(s, /cloud|overcast/i) || match(s, /блачн|асмурн/))
        return (match(s, /partly/i) || match(s, /еременн/)) ? "partly" : "cloud";
    if (match(s, /sun|clear/i) || match(s, /олнеч|сно/))            return "sun";
    return "cloud";
}

// Полный набор статусов wttr.in/WWO (%C) на русском. wttr.in при lang=ru часть
// из них локализует, но не все (напр. «Light rain shower» приходит по-англ.) -
// поэтому любой оставшийся английский статус переводим сами. Если пришла уже
// кириллица (нет в словаре) - оставляем как есть.
let WCOND_RU = {
    "Sunny": "Ясно",
    "Clear": "Ясно",
    "Partly cloudy": "Переменная облачность",
    "Cloudy": "Облачно",
    "Overcast": "Пасмурно",
    "Mist": "Дымка",
    "Patchy rain possible": "Возможен дождь",
    "Patchy rain nearby": "Местами дождь",
    "Patchy snow possible": "Возможен снег",
    "Patchy sleet possible": "Возможен мокрый снег",
    "Patchy freezing drizzle possible": "Возможна изморозь",
    "Thundery outbreaks possible": "Возможна гроза",
    "Blowing snow": "Метель",
    "Blizzard": "Сильная метель",
    "Fog": "Туман",
    "Freezing fog": "Ледяной туман",
    "Patchy light drizzle": "Местами слабая морось",
    "Light drizzle": "Морось",
    "Freezing drizzle": "Замерзающая морось",
    "Heavy freezing drizzle": "Сильная замерзающая морось",
    "Patchy light rain": "Местами небольшой дождь",
    "Light rain": "Небольшой дождь",
    "Moderate rain at times": "Временами умеренный дождь",
    "Moderate rain": "Умеренный дождь",
    "Heavy rain at times": "Временами сильный дождь",
    "Heavy rain": "Сильный дождь",
    "Light freezing rain": "Небольшой ледяной дождь",
    "Moderate or heavy freezing rain": "Умеренный или сильный ледяной дождь",
    "Light sleet": "Небольшой мокрый снег",
    "Moderate or heavy sleet": "Умеренный или сильный мокрый снег",
    "Patchy light snow": "Местами небольшой снег",
    "Light snow": "Небольшой снег",
    "Patchy moderate snow": "Местами умеренный снег",
    "Moderate snow": "Умеренный снег",
    "Patchy heavy snow": "Местами сильный снег",
    "Heavy snow": "Сильный снег",
    "Ice pellets": "Ледяная крупа",
    "Light rain shower": "Небольшой ливень",
    "Moderate or heavy rain shower": "Умеренный или сильный ливень",
    "Torrential rain shower": "Проливной ливень",
    "Light sleet showers": "Небольшой ливневый мокрый снег",
    "Moderate or heavy sleet showers": "Умеренный или сильный ливневый мокрый снег",
    "Light snow showers": "Небольшой снегопад",
    "Moderate or heavy snow showers": "Умеренный или сильный снегопад",
    "Light showers of ice pellets": "Небольшая ледяная крупа",
    "Moderate or heavy showers of ice pellets": "Умеренная или сильная ледяная крупа",
    "Patchy light rain with thunder": "Небольшой дождь с грозой",
    "Moderate or heavy rain with thunder": "Умеренный или сильный дождь с грозой",
    "Patchy light snow with thunder": "Небольшой снег с грозой",
    "Moderate or heavy snow with thunder": "Умеренный или сильный снег с грозой",
};

function wcond_tr(desc) {
    if (lang() != "ru") return desc ?? "";
    let s = trim(desc ?? "");
    return WCOND_RU[s] ?? desc ?? "";
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

let _npl_raw = null, _npl = null;
function netpri_list() {
    let raw = fs.readfile(NETPRI_CACHE);
    if (!raw) return null;
    // За тик netpri_list зовут дважды (page_sig + отрисовка), а файл меняется
    // раз в несколько секунд: разбор+сортировку кэшируем по сырому содержимому.
    if (raw == _npl_raw) return _npl;
    let j;
    try { j = json(raw); } catch (e) { return null; }
    if (type(j) != "array") return [];
    let out = [];
    for (let e in j)
        if (e?.iface) push(out, e);       /* в хвосте бывает объект события */
    sort(out, function(a, b) {
        return int(+(a.metric ?? 999)) - int(+(b.metric ?? 999));
    });
    _npl_raw = raw; _npl = out;
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
let sta = { nets: null, sel: -1, pass: "", kb: { pg: "abc", caps: false }, band: 5 };
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

// Диапазон выключен -> включаем радио и его точку доступа (без интерфейса у phy
// нет netdev, сканировать нечем), перезагружаем wifi и ждём подъёма. Блокирует
// ~3с - зовём под сплэшем. true, если после этого есть интерфейс для скана.
function wifi_ensure_band_up(band) {
    if (!ucur) return false;
    let radio = radio_for_band(band);
    let ap = "default_" + radio;
    if (!wifi_is_disabled(radio, ap)) return wifi_iface_for(band) != null;
    ucur.set("wireless", radio, "disabled", "0");
    ucur.set("wireless", ap, "disabled", "0");
    ucur.commit("wireless");
    system("wifi reload");
    system("sleep 3");
    return wifi_iface_for(band) != null;
}

function wifi_scan_start(band) {
    fs.unlink(SCAN_DONE);
    fs.unlink(SCAN_OUT);
    let one = band ? wifi_iface_for(band) : null;
    if (band && !one) {
        // Радио этого диапазона выключено/без интерфейса - сканировать нечем.
        // Пишем пустой результат: без этого откат на «все интерфейсы» сканил бы
        // ДРУГОЙ диапазон (выключили 2.4 -> «скан 2.4» показывал сети 5 ГГц).
        fs.writefile(SCAN_OUT, "{\"scans\":[]}");
        fs.writefile(SCAN_DONE, "");
        return;
    }
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
    // wwan обязан лежать в зоне wan фаервола: без зоны интерфейс висит «серым» -
    // нет ни masquerade, ни форвардинга, и аплинк не раздаёт интернет. Делаем
    // идемпотентно на каждый коннект, чтобы вылечить и созданный ранее в серой зоне.
    let fzone = null;
    ucur.foreach("firewall", "zone", function(z) {
        if (z.name == "wan") fzone = z[".name"];
    });
    if (fzone) {
        let nets = ucur.get("firewall", fzone, "network");
        if (type(nets) != "array") nets = nets ? [ nets ] : [];
        let has = false;
        for (let n in nets) if (n == "wwan") has = true;
        if (!has) {
            push(nets, "wwan");
            ucur.set("firewall", fzone, "network", nets);
            ucur.commit("firewall");
            system("/etc/init.d/firewall reload >/dev/null 2>&1 &");
        }
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


// Две кнопки скана - по диапазону, на фиксированном месте над «Назад»,
// чтобы их положение не зависело от числа аплинков.
function draw_scan_btns() {
    let ny = BACK_Y - 36;
    lcd_rect(10, ny, 145, 30, C.widget);
    lcd_rect(10, ny, 3, 30, C.accent);
    lcd_text(24, ny + 11, "+ Wi-Fi 2.4GHz", C.accent, C.widget, 1);
    lcd_rect(165, ny, 145, 30, C.widget);
    lcd_rect(165, ny, 3, 30, C.accent);
    lcd_text(185, ny + 11, "+ Wi-Fi 5GHz", C.accent, C.widget, 1);
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
            lcd_rect(b.x, b.y, 3, b.h, rows[i][2]);
            lcd_text(b.x + 12, b.y + 6, rows[i][0], C.gray, C.widget, 1);
            lcd_text(b.x + 12, b.y + 20, rows[i][1], C.white, C.widget, 2);
        }
        draw_back();
        lcd_flush();
        return;
    }

    if (l == null) {
        lcd_text(20, 100, tr("Reading uplinks..."), C.gray, C.bg, 2);
        draw_scan_btns();
        draw_back();
        lcd_flush();
        return;
    }
    if (length(l) == 0) {
        // Кнопки скана обязаны быть и здесь: после «забыть сеть» без SIM
        // список пуст, и без них со страницы некуда идти (issue #4).
        lcd_text(20, 100, tr("No uplinks"), C.dim, C.bg, 2);
        draw_scan_btns();
        draw_back();
        lcd_flush();
        return;
    }

    // Идёт фоновое переключение приоритета? Помечаем нужную карточку, снимаем
    // метку когда аплинк стал основным (или по таймауту, если не вышло).
    let sw = st.np_switch;
    if (sw && (l[0].iface == sw.ifn || (time() - sw.ts) >= 12)) { st.np_switch = null; sw = null; }

    // Карточка на аплинк: слева цветная полоска (зелёная у основного), имя,
    // тип, справа метрика и адрес. Тап делает аплинк основным.
    for (let i = 0; i < length(l) && i < 3; i++) {
        let e = l[i], b = netpri_btn(i);
        let up = (e.health ?? "") == "up";
        let switching = (sw != null && e.iface == sw.ifn && i != 0);
        let col = switching ? C.accent : (i == 0 ? C.green : (up ? C.cyan : C.dim));
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, col);
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
        // Пока переключаемся - вместо метрики троеточие акцентом (мгновенный
        // отклик без попапа); как станет основным, вернётся зелёная метрика.
        let m = switching ? "..." : sprintf("%d", int(+(e.metric ?? 0)));
        lcd_text(b.x + b.w - 10 - roff - tlen(m) * 12, b.y + 5, m,
                 switching ? C.accent : (i == 0 ? C.green : C.gray), C.widget, 2);
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

    draw_scan_btns();
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
    // Нет 5gmodem/моста - не залипаем в ожидании навсегда.
    if (!fs.stat("/usr/share/5gmodem/smsbridge.sh")) {
        st.sms_nobridge = true;
        st.sms_wait = false;
        return;
    }
    st.sms_nobridge = false;
    // Ждём, но не вечно: если чтение не принесло кэш за 15 с (AT-порт занят,
    // recv упал), разрешаем повтор вместо вечного «Читаю ящик...».
    if (st.sms_wait && (time() - st.sms_wait_since) < 15) return;
    st.sms_wait = true;
    st.sms_wait_since = time();
    // Перенаправление вешаем на подоболочку целиком, иначе фоновый процесс
    // держит наши дескрипторы и ucode ждёт его завершения.
    system("(/usr/share/5gmodem/smsbridge.sh recv > " + SMS_CACHE + ".new 2>/dev/null" +
           " && mv " + SMS_CACHE + ".new " + SMS_CACHE + ") >/dev/null 2>&1 &");
}

// Удаление сообщения: мост smsbridge.sh delete <index>. Мультипарт = несколько
// слотов (idx), сносим все. Слоты модема независимы, порядок не важен. Сразу
// перечитываем ящик, чтобы список обновился.
function sms_delete(m) {
    if (!m || !fs.stat("/usr/share/5gmodem/smsbridge.sh")) return;
    let ids = type(m.idx) == "array" ? m.idx : [];
    let cmd = "";
    for (let ix in ids)
        cmd += sprintf("/usr/share/5gmodem/smsbridge.sh delete %d >/dev/null 2>&1; ", ix);
    if (cmd == "") return;
    system("( " + cmd + "/usr/share/5gmodem/smsbridge.sh recv > " + SMS_CACHE + ".new" +
           " 2>/dev/null && mv " + SMS_CACHE + ".new " + SMS_CACHE + " ) >/dev/null 2>&1 &");
    // st.sms НЕ обнуляем: вызывающий уже убрал строку оптимистично; когда
    // фоновый recv перепишет кэш, sms_list перечитает его по новому mtime.
}

// Отправитель: цифровой номер приводим к виду +7 (962) 699-90-32 - так же, как
// на «Входящих» в 5gmodem. Буквенные имена вроде «T-Mob» phone_fmt вернёт как
// есть, поэтому проверять тип отправителя отдельно не нужно.
function sms_from(raw) {
    // Компактный номер без пробелов (+7(962)699-90-32): в списке/шапке СМС полный
    // с пробелами не влезал.
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
        let txt = "", ids = [];
        for (let p in e.parts) {
            txt += (p?.content ?? "");
            let ix = int(+(p?.index ?? -1));
            if (ix >= 0) push(ids, ix);   // слоты для удаления (мультипарт - несколько)
        }
        push(out, { sender: e.sender, time: e.time, key: e.key,
                    text: sms_clean(txt), idx: ids });
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
        let msg = st.sms_nobridge ? tr("Modem tool not installed")
                : ((st.sms_wait && (time() - st.sms_wait_since) >= 15)
                   ? tr("Failed to read inbox")
                   : tr("Reading inbox..."));
        lcd_text(20, 100, msg, C.gray, C.bg, 1);
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
        lcd_rect(10, y, 3, 40, neu ? C.green : C.dim);
        // Красный минус справа за разделителем - как «забыть» у Wi-Fi.
        lcd_rect(310 - 34, y + 4, 1, 40 - 8, C.border);
        lcd_text(310 - 24, y + 8, "-", C.red, C.widget, 3);
        let from = sms_from(m.sender), when = sms_short_time(m.time);
        lcd_text(20, y + 5, tcut(from, 16), neu ? C.white : C.gray, C.widget, 2);
        lcd_text(310 - 34 - tlen(when) * 6 - 6, y + 8, when, C.dim, C.widget, 1);
        // Обрезаем до зоны минуса (справа), чтобы текст на него не налезал.
        lcd_text(20, y + 25, tcut(replace(m.text, /\n/g, " "), 40),
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

// Таблица русских имён городов + маппер. Подняты СЮДА (выше menu_items): плитка
// «Погода» показывает город, а hoisting в ucode нет.
let CITY_RU = {
    "Moscow": "Москва", "Saint Petersburg": "Петербург", "Voronezh": "Воронеж",
    "Novosibirsk": "Новосибирск", "Yekaterinburg": "Екатеринбург",
    "Kazan": "Казань", "Nizhny Novgorod": "Нижний Новгород",
    "Samara": "Самара", "Rostov-on-Don": "Ростов-на-Дону",
    "Krasnoyarsk": "Красноярск", "Sochi": "Сочи",
    "Khabarovsk": "Хабаровск", "Vladivostok": "Владивосток",
    "Ishim": "Ишим",
};

function city_name(v) {
    return lang() == "ru" ? (CITY_RU[v] ?? v) : v;
}

// Подпись плитки «Погода»: город + температура прошлого прогноза, иначе «обновить».
function weather_sub() {
    let w = st.data?.weather;
    if (!w || (w.city == null && w.temp == null)) return tr("Update now");
    return sprintf("%s, %s", city_name(w.city) ?? "", w.temp ?? "");
}

// Подпись плитки «Будильник»: время, если он включён; иначе «подъём».
function alarm_sub() {
    if (!ucur || ucur.get("almond3s", "alarm", "enabled") != "1") return tr("wake up");
    let h = int(+(ucur.get("almond3s", "alarm", "hour") ?? 7));
    let m = int(+(ucur.get("almond3s", "alarm", "minute") ?? 0));
    return sprintf("%02d:%02d", h, m);
}

// Подпись плитки «Спидтест» - реальные цифры прошлого замера из кэша (down/up).
// Самодостаточна (без поздних хелперов): нет hoisting, а menu_items выше по файлу.
function speedtest_sub() {
    let raw = fs.readfile("/tmp/5gmodem_speedtest.json");
    if (raw) {
        try {
            let j = json(raw);
            if (j?.down_mbps != null) {
                let u = (j.up_mbps == null) ? "—" : sprintf("%.1f", +j.up_mbps);
                return sprintf("%.1f / %s Мб/с", +j.down_mbps, u);
            }
        } catch (e) {}
    }
    return tr("down/up");
}

// Пункты меню в фиксированном порядке (пожелание владельца). VPN - только если
// стоит SSClash. draw_menu бьёт список по 5 на страницу; тап диспатчит по act.
// === Раздел «Игры» ===
// Свой платформер + ромы NES. Ромы ищем в /etc/almond3s/roms (переживает
// перезагрузку) и в /tmp/roms (закинул на пробу - и играешь).
let ROM_DIRS = [ "/etc/almond3s/roms", "/tmp/roms" ];
let NES_BIN  = "/usr/libexec/almond3s/nes-quick";

function rom_list() {
    let out = [];
    for (let d in ROM_DIRS) {
        let ls = fs.lsdir(d);
        if (type(ls) != "array") continue;
        for (let f in ls) {
            if (lc(substr(f, length(f) - 4)) != ".nes") continue;
            push(out, { name: substr(f, 0, length(f) - 4), path: d + "/" + f });
        }
    }
    return out;
}

function games_sub() {
    let n = length(rom_list());
    return n ? sprintf(tr("%d ROMs"), n) : tr("no ROMs");
}

function menu_items() {
    let d = st.data;
    let nc = type(d?.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
    let rx_last = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
    let tx_last = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
    let lc = led_cfg();
    let bt = d?.battery, bp = int(+(bt?.percent ?? -1));
    let ns = int(d?.sms_new ?? 0);
    let it = [];
    push(it, { label: tr("Network"), sub: netpri_primary(), icon: "network", ic: C.cyan, act: "dashboard" });
    push(it, { label: tr("WiFi"), sub: sprintf(tr("%d clients"), nc), icon: "wifi", ic: C.cyan, act: "wifi" });
    push(it, { label: tr("Modem"), sub: modem_status(d?.lte), mid: d?.lte?.operator, icon: "modem", ic: C.cyan, act: "lte" });
    push(it, { label: "VPN", sub: vpn_present() ? "SSClash" : tr("SSClash not installed"),
               sc: vpn_present() ? C.gray : C.dim, ic: C.green, act: "vpn" });
    push(it, { label: tr("Ping"), sub: tr("check"), icon: "services", ic: C.green, act: "services" });
    push(it, { label: tr("Speedtest"), sub: speedtest_sub(), icon: "bolt", ic: C.cyan, act: "speedtest" });
    push(it, { label: tr("Traffic"), sub: sprintf("R:%s T:%s", fmt_bytes(rx_last), fmt_bytes(tx_last)), icon: "traffic", ic: C.cyan, act: "traffic" });
    push(it, { label: tr("SMS"), sub: ns > 0 ? sprintf(tr("%d new"), ns) : tr("inbox"), sc: ns > 0 ? C.green : C.gray, icon: "sms", ic: C.white, act: "sms" });
    push(it, { label: tr("LED"), sub: led_blinking ? tr("blinking") : (lc.on ? tr("on") : tr("off")), sc: (lc.on || led_blinking) ? C.green : C.gray, icon: "led", ic: C.yellow, act: "led" });
    push(it, { label: tr("Weather"), sub: weather_sub(), icon: "weather", ic: C.yellow, act: "weather" });
    push(it, { label: tr("Alarm"), sub: alarm_sub(), icon: "sound", ic: C.cyan, act: "alarm" });
    push(it, { label: tr("Battery"), sub: bp >= 0 ? sprintf("%d%%", bp) : "--", sc: bt?.charging ? C.green : C.gray, icon: "bolt", ic: "#FFA930", act: "battery" });
    push(it, { label: tr("Terminal"), sub: tr("shell"), icon: "term", ic: C.green, act: "term" });
    // Зигби из меню убран: пока модулем ничего не управляется, плитка только
    // занимает место. Сама страница жива и открывается через /tmp/.lcd_goto,
    // так что вернуть её - это одна строка.
    push(it, { label: tr("Games"), sub: games_sub(), icon: "game", ic: C.green, act: "games" });
    push(it, { label: tr("Settings"), sub: sprintf("%d%%", bright_cfg()), icon: "display", ic: C.cyan, act: "settings" });
    push(it, { label: tr("Info"), sub: fmt_uptime(d?.uptime), icon: "info", ic: C.cyan, act: "info" });
    push(it, { label: tr("Modem Reset"), sub: tr("LTE restart"), sc: "#F0A868", bg: "#3A2208", icon: "reset", ic: C.orange, act: "reset", line: C.orange });
    push(it, { label: tr("Power"), sub: tr("System"), sc: "#F0B0B8", bg: C.back, icon: "reboot", ic: "#F0B0B8", act: "power", line: "#D32F2F" });
    return it;
}

function menu_pages() {
    let p = int((length(menu_items()) + 4) / 5);
    return p < 1 ? 1 : p;
}

// Плитка-пейджер: слева «<» (страница назад, зона = левая треть), остальное -
// «вперёд»; по центру номер N/M, справа «>». Двунаправленная навигация одним
// тапом + видно, сколько всего экранов. Определена ПОСЛЕ menu_pages/menu_items
// (нет hoisting - иначе draw_nav_tile их не видит и роняет меню).
function draw_nav_tile() {
    let b = btn_pos(6);
    let pages = menu_pages();
    let pressed = (menu_pressed != null && menu_pressed == 6);
    let bg = pressed ? C.press : C.hdr;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    if (!pressed) {
        lcd_rect(b.x, b.y + b.h - 3, b.w, 3, C.border);
        lcd_rect(b.x + b.w - 3, b.y, 3, b.h, C.border);
    }
    let ac = pages > 1 ? C.cyan : C.dim;
    let cy = b.y + int((b.h - 18) / 2);
    let m = 14;                       // одинаковый отступ стрелок от краёв
    lcd_text(b.x + m, cy, "<", ac, bg, 3);
    lcd_text(b.x + b.w - m - 17, cy, ">", ac, bg, 3);
    // Номер страницы - строго по центру плитки.
    let ps = sprintf("%d/%d", st.mpg, pages);
    lcd_text(b.x + int((b.w - tlen(ps) * 12) / 2), b.y + int((b.h - 16) / 2),
             ps, C.white, bg, 2);
}

function draw_menu() {
    if (st.halting) return;   // идёт выключение/ребут - не рисовать поверх заставки
    lcd_clear(C.bg);
    draw_header();
    let items = menu_items();
    let pages = int((length(items) + 4) / 5); if (pages < 1) pages = 1;
    if (st.mpg == null || st.mpg < 1 || st.mpg > pages) st.mpg = 1;
    let base = (st.mpg - 1) * 5;
    for (let s = 0; s < 5 && base + s < length(items); s++) {
        let m = items[base + s];
        draw_btn(s + 1, m.label, m.sub, m.tc ?? C.white, m.sc ?? C.gray,
                 m.bg, m.mid, m.icon, m.ic);
        if (m.line) { let b = btn_pos(s + 1); lcd_rect(b.x, b.y, b.w, 2, m.line); }
    }
    draw_nav_tile();
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

// То же самое, но для произвольной строки: ссылка на джойстик, например.
let qr_txt_cache = {};

function qr_rows(text) {
    if (!text || text == "") return null;
    if (exists(qr_txt_cache, text)) return qr_txt_cache[text];

    let rows = null;
    let p = fs.popen("qrencode -t ASCII -m 0 -l L -o - " + sh_quote(text) + " 2>/dev/null", "r");
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
    qr_txt_cache[text] = rows;
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
    return { x: GX + GW - 68, y: y + 9, w: 62, h: 62 };
}

// === Страница «Дебаг»: тонкие настройки вывода панели ===
// Сырые команды ILI9341 через CLI: инверсия, гамма-кривая, CABC
// (адаптивное цветоусиление) и частота ШИМ подсветки. Значения живут в uci
// и накатываются при старте интерфейса.
let PWM_STEPS = [ 120, 250, 500, 1000, 2000 ];

function pancfg() {
    let inv = ucur ? ucur.get("almond3s", "display", "pinv") : null;
    let gam = ucur ? ucur.get("almond3s", "display", "pgamma") : null;
    let cab = ucur ? ucur.get("almond3s", "display", "pcabc") : null;
    let hz  = ucur ? ucur.get("almond3s", "display", "pwmhz") : null;
    let ini = ucur ? ucur.get("almond3s", "display", "pinit") : null;
    return {
        inv:   inv == "1",
        gamma: clampi(int(+(gam ?? 1)), 1, 4),
        cabc:  clampi(int(+(cab ?? 0)), 0, 3),
        hz:    clampi(int(+((hz == null || hz == "") ? 250 : hz)), 50, 20000),
        init:  ini == "kernel" ? "kernel" : "boot",
    };
}

function pancfg_set(key, v) {
    if (!ucur) return;
    ucur.set("almond3s", "display", key, sprintf("%s", v));
    ucur.commit("almond3s");
}

function panel_apply() {
    let c = pancfg();
    system(sprintf("almond3s-lcd panel %s >/dev/null 2>&1", c.inv ? "0x21" : "0x20"));
    system(sprintf("almond3s-lcd panel 0x26 0x%02X >/dev/null 2>&1", 1 << (c.gamma - 1)));
    system(sprintf("almond3s-lcd panel 0x55 0x%02X >/dev/null 2>&1", c.cabc));
    system(sprintf("almond3s-lcd pwm %d >/dev/null 2>&1", c.hz));
}

function dbg_inv_btn()   { return { x: 10, y: 30, w: 146, h: 28 }; }
function dbg_pinit_btn() { return { x: 164, y: 30, w: 146, h: 28 }; }
function dbg_gamma_btn(i){ return { x: 10 + i * 76, y: 78, w: 72, h: 28 }; }
function dbg_cabc_btn(i) { return { x: 10 + i * 76, y: 126, w: 72, h: 28 }; }
function dbg_pwm_btn(i)  { return { x: 10 + i * 60, y: 174, w: 56, h: 28 }; }

function draw_debug_page() {
    lcd_clear(C.bg);
    draw_header(tr("Debug"));
    let c = pancfg();

    let ib = dbg_inv_btn();
    lcd_rect(ib.x, ib.y, ib.w, ib.h, C.widget);
    lcd_rect(ib.x, ib.y, 3, ib.h, c.inv ? C.green : C.dim);
    lcd_text(ib.x + 12, ib.y + 8, tr("Invert"), C.white, C.widget, 1);
    lcd_text(ib.x + ib.w - 44, ib.y + 8, c.inv ? tr("on") : tr("off"),
             c.inv ? C.green : C.gray, C.widget, 1);

    // Таблица инициализации панели: загрузчик (наш дефолт) или вторая
    // заводская из стокового ядра. Смена = полный reset+init панели.
    let pb = dbg_pinit_btn();
    lcd_rect(pb.x, pb.y, pb.w, pb.h, C.widget);
    lcd_rect(pb.x, pb.y, 3, pb.h, c.init == "kernel" ? C.yellow : C.dim);
    lcd_text(pb.x + 12, pb.y + 8, tr("Panel"), C.white, C.widget, 1);
    lcd_text(pb.x + pb.w - 44, pb.y + 8,
             c.init == "kernel" ? tr("kernel") : tr("boot"),
             c.init == "kernel" ? C.yellow : C.gray, C.widget, 1);

    lcd_text(12, 66, tr("GAMMA CURVE"), C.gray, C.bg, 1);
    for (let i = 0; i < 4; i++) {
        let b = dbg_gamma_btn(i), sel = (c.gamma == i + 1);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", i + 1);
        lcd_text(b.x + int((b.w - 6) / 2), b.y + 10, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    lcd_text(12, 114, tr("COLOR ENHANCE"), C.gray, C.bg, 1);
    let cl = [ tr("off"), "UI", tr("photo"), tr("video") ];
    for (let i = 0; i < 4; i++) {
        let b = dbg_cabc_btn(i), sel = (c.cabc == i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        lcd_text(b.x + int((b.w - tlen(cl[i]) * 6) / 2) + 2, b.y + 10, cl[i],
                 sel ? C.white : C.gray, C.widget, 1);
    }

    lcd_text(12, 162, tr("BACKLIGHT PWM, HZ"), C.gray, C.bg, 1);
    for (let i = 0; i < length(PWM_STEPS); i++) {
        let b = dbg_pwm_btn(i), sel = (c.hz == PWM_STEPS[i]);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", PWM_STEPS[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 10, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

// === Редактор пиксель-арта: рисовать иконки прямо на экране ===
// Палитра из 8 цветов и ластик; тап красит клетку кистью, движение с
// прижатым стилусом рисует непрерывно (клетки между точками доливаются).
// Размер иконки не фиксирован 14x14: клетка подгоняется под холст (ED_BOX),
// чтобы влезала и широкая (напр. wifi_st 21x14).
let ED_BOX = 168;              // сторона области холста, px
let ED_CELL = 12;              // размер клетки - пересчитывается под иконку
let ED_X = 8, ED_Y = 28;
let ed_w = 14, ed_h = 14;      // размеры текущей иконки
function ed_set_dims(w, h) {
    ed_w = w; ed_h = h;
    let cw = int(ED_BOX / w), ch = int(ED_BOX / h);
    ED_CELL = cw < ch ? cw : ch;
    if (ED_CELL < 1) ED_CELL = 1;
}
// Слоты иконок меню, которые можно открыть на правку: имя и цвет,
// которым моно-арт превращается в редактируемую сетку.
let ED_SLOTS = [
    { name: "network",  pal: 6 }, { name: "wifi",   pal: 6 },
    { name: "modem",    pal: 6 }, { name: "traffic", pal: 6 },
    { name: "sms",      pal: 1 }, { name: "info",   pal: 6 },
    { name: "weather",  pal: 4 }, { name: "services", pal: 5 },
    { name: "display",  pal: 6 }, { name: "saver",  pal: 4 },
    { name: "led",      pal: 4 }, { name: "sound",  pal: 6 },
    { name: "bolt",     pal: 3 }, { name: "zigbee", pal: 5 },
    { name: "debug",    pal: 8 }, { name: "editor", pal: 6 },
    { name: "reset",    pal: 4 }, { name: "reboot", pal: 2 },
    { name: "term",     pal: 5 }, { name: "wifi_st", pal: 6 },
    { name: "vpn",      pal: 1 }, { name: "moon",   pal: 1 },
    { name: "eth",      pal: 6 }, { name: "fn",     pal: 5 },
];
let ed_pick = false;
let ed_cpick = false;
let ed_target = null;
let ed_grid = null;
let ed_color = 1;
let ed_last = null;
let ed_saved = "";
// «Взведён» = палец отрывался после открытия холста. Пока не взведён, касания
// по холсту не рисуют: иначе палец, ещё лежащий на стекле после выбора иконки
// в пикере (или пункта меню), успевал наляпать ложные пиксели на свежий канвас.
let ed_armed = false;

function ed_init() {
    if (ed_grid != null) return;
    ed_set_dims(14, 14);
    ed_grid = [];
    for (let r = 0; r < ed_h; r++) {
        let row = [];
        for (let c = 0; c < ed_w; c++) push(row, 0);
        push(ed_grid, row);
    }
}

function ed_btn(i) {
    return { x: 192, y: 28 + i * 30, w: 118, h: 26 };
}

function ed_pal_btn(i) {
    // 3x3: восемь цветов и ластик в правом нижнем углу
    return { x: 192 + (i % 3) * 28, y: 92 + int(i / 3) * 28, w: 24, h: 24 };
}

function ed_cell_draw(r, c) {
    let v = ed_grid[r][c];
    lcd_rect(ED_X + c * ED_CELL + 1, ED_Y + r * ED_CELL + 1,
             ED_CELL - 2, ED_CELL - 2, v ? ED_PAL[v - 1] : C.btn);
}

function ed_preview() {
    lcd_rect(278, 92, 34, 84, C.bg);
    lcd_rect(280, 116, 32, 32, C.widget);
    let ps = int(30 / (ed_w > ed_h ? ed_w : ed_h));
    if (ps < 1) ps = 1;
    let px0 = 280 + int((32 - ed_w * ps) / 2), py0 = 116 + int((32 - ed_h * ps) / 2);
    for (let r = 0; r < ed_h; r++)
        for (let c = 0; c < ed_w; c++)
            if (ed_grid[r][c])
                lcd_rect(px0 + c * ps, py0 + r * ps, ps, ps, ED_PAL[ed_grid[r][c] - 1]);
}

function ed_paint(r, c) {
    if (r < 0 || r >= ed_h || c < 0 || c >= ed_w) return false;
    if (ed_grid[r][c] == ed_color) return false;
    ed_grid[r][c] = ed_color;
    ed_cell_draw(r, c);
    return true;
}

function ed_load(name) {
    let grid = [];
    let cust = MICON_CUSTOM[name];
    let slot_pal = 1;
    for (let sl in ED_SLOTS)
        if (sl.name == name) slot_pal = sl.pal;
    // Палитру ставим под открываемую иконку: кастомная несёт свою,
    // вшитая - либо собственную, либо дефолтную. Иначе чужой цвет в
    // слоте перекрашивал её прямо при загрузке.
    let bart = null, bpal = ED_PAL_DEF;
    if (!cust) {
        let e = MICONS[name];
        bart = e;
        if (type(e) == "object") {
            bart = e.art;
            bpal = e.pal ?? ED_PAL_DEF;
        }
    }
    // Размер холста - под открываемую иконку (кастом несёт свой w/h, вшитая -
    // по размеру арта).
    if (cust) ed_set_dims(cust.w, cust.h);
    else ed_set_dims(bart ? length(bart[0]) : 14, bart ? length(bart) : 14);
    if (cust)
        for (let i = 0; i < 8; i++) ED_PAL[i] = cust.pal[i];
    else
        for (let i = 0; i < 8; i++) ED_PAL[i] = bpal[i];
    for (let r = 0; r < ed_h; r++) {
        let row = [];
        for (let c = 0; c < ed_w; c++) {
            if (cust) push(row, cust.g[r][c]);
            else {
                let ch = bart ? substr(bart[r], c, 1) : ".";
                if (ch == "#") push(row, slot_pal);
                else if (ch >= "1" && ch <= "8") push(row, int(ch));
                else push(row, 0);
            }
        }
        push(grid, row);
    }
    ed_grid = grid;
    ed_target = name;
}

function draw_iconedit_page() {
    ed_init();
    lcd_clear(C.bg);
    draw_header(tr("Editor"));
    if (ed_cpick) {
        // Пикер цветов: расширенная палитра для текущего слота.
        lcd_text(ED_X, ED_Y, tr("Pick a color for the slot"), C.gray, C.bg, 1);
        for (let i = 0; i < length(ED_COLORS); i++) {
            let px = ED_X + (i % 6) * 28;
            let py = ED_Y + 14 + int(i / 6) * 30;
            lcd_rect(px, py, 26, 26, ED_COLORS[i]);
            if (ed_color > 0 && ED_PAL[ed_color - 1] == ED_COLORS[i]) {
                lcd_rect(px, py, 26, 2, C.bg);
                lcd_rect(px, py + 24, 26, 2, C.bg);
                lcd_rect(px, py, 2, 26, C.bg);
                lcd_rect(px + 24, py, 2, 26, C.bg);
            }
        }
        draw_back();
        lcd_flush();
        return;
    }
    if (ed_pick) {
        // Пикер: все иконки меню сеткой на месте холста.
        lcd_text(ED_X, ED_Y, tr("Pick an icon to edit"), C.gray, C.bg, 1);
        for (let i = 0; i < length(ED_SLOTS); i++) {
            let px = ED_X + (i % 6) * 34;
            let py = ED_Y + 14 + int(i / 6) * 36;
            lcd_rect(px, py, 32, 32, ed_target == ED_SLOTS[i].name ? C.accent : C.btn);
            // Масштаб под размер: широкая иконка (напр. wifi_st) в scale 1,
            // центрируем в клетке 32x32.
            let d = micon_dim(ED_SLOTS[i].name);
            let sc = (d[0] * 2 <= 30 && d[1] * 2 <= 30) ? 2 : 1;
            draw_micon(px + int((32 - d[0] * sc) / 2), py + int((32 - d[1] * sc) / 2),
                       ED_SLOTS[i].name, ED_PAL[ED_SLOTS[i].pal - 1], sc);
        }
        draw_back();
        lcd_flush();
        return;
    }
    lcd_rect(ED_X, ED_Y, ed_w * ED_CELL, ed_h * ED_CELL, C.border);
    for (let r = 0; r < ed_h; r++)
        for (let c = 0; c < ed_w; c++)
            ed_cell_draw(r, c);
    let b0 = ed_btn(0);
    lcd_rect(b0.x, b0.y, b0.w, b0.h, C.widget);
    lcd_rect(b0.x, b0.y, 3, b0.h, C.green);
    lcd_text(b0.x + 14, b0.y + 6, tr("Save"), C.white, C.widget, 2);
    let b1 = ed_btn(1);
    lcd_rect(b1.x, b1.y, 62, b1.h, C.widget);
    lcd_rect(b1.x, b1.y, 3, b1.h, C.red);
    lcd_text(b1.x + 10, b1.y + 9, tr("Clr"), C.white, C.widget, 1);
    // Кнопка пикера: открыть иконку меню на правку.
    lcd_rect(260, b1.y, 50, 24, C.btn);
    for (let dy = 0; dy < 3; dy++)
        for (let dx = 0; dx < 3; dx++)
            lcd_rect(268 + dx * 12, b1.y + 5 + dy * 6, 6, 3, C.cyan);
    for (let i = 0; i < 9; i++) {
        let b = ed_pal_btn(i);
        if (i < 8) {
            lcd_rect(b.x, b.y, b.w, b.h, ED_PAL[i]);
            if (ed_color == i + 1) {
                lcd_rect(b.x, b.y, b.w, 2, C.bg);
                lcd_rect(b.x, b.y + b.h - 2, b.w, 2, C.bg);
                lcd_rect(b.x, b.y, 2, b.h, C.bg);
                lcd_rect(b.x + b.w - 2, b.y, 2, b.h, C.bg);
                lcd_rect(b.x + 2, b.y + 2, b.w - 4, 2, C.white);
                lcd_rect(b.x + 2, b.y + b.h - 4, b.w - 4, 2, C.white);
            }
        } else {
            // резинка: классический розовый ластик с белой полосой
            lcd_rect(b.x, b.y, b.w, b.h, "#E8889C");
            lcd_rect(b.x, b.y + int(b.h / 2) - 3, b.w, 6, "#F5EFF0");
            if (ed_color == 0) {
                lcd_rect(b.x, b.y, b.w, 2, C.bg);
                lcd_rect(b.x, b.y + b.h - 2, b.w, 2, C.bg);
                lcd_rect(b.x, b.y, 2, b.h, C.bg);
                lcd_rect(b.x + b.w - 2, b.y, 2, b.h, C.bg);
                lcd_rect(b.x + 2, b.y + 2, b.w - 4, 2, C.white);
                lcd_rect(b.x + 2, b.y + b.h - 4, b.w - 4, 2, C.white);
            }
        }
    }
    ed_preview();
    // Радуга: расширенный выбор цвета для выбранного слота палитры.
    // После превью - оно чистит свою зону и затирало кнопку.
    for (let i = 0; i < 4; i++)
        lcd_rect(282 + i * 7, 94, 7, 16,
                 [ "#F85149", "#FFD866", "#3FB950", "#58A6FF" ][i]);
    lcd_text(192, 180, ed_target != null
             ? sprintf("%s: %s", tr("editing"), ed_target)
             : "/etc/almond3s/art", C.dim, C.bg, 1);
    if (ed_saved != "")
        lcd_text(192, 192, ed_saved, C.gray, C.bg, 1);
    draw_back();
    lcd_flush();
}

function dbg_open_btn() { return { x: GX, y: 176, w: 160, h: 26 }; }

// Тёплый фильтр: вечернее наложение. Убавляет синий и чуть зелёный уже при
// передаче на панель, поэтому это настоящий тёплый свет, а не нарисованная
// поверх плёнка - исходный кадр не трогается.
let WARM_STEPS = [ 0, 30, 60, 100 ];

function warm_btn() { return { x: GX, y: 176, w: GW, h: 26 }; }

function warm_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "warm") : null;
    v = (v == null || v == "") ? 0 : int(+v);
    for (let i = 0; i < length(WARM_STEPS); i++)
        if (WARM_STEPS[i] == v) return v;
    return 0;
}

function warm_apply() {
    system(sprintf("almond3s-lcd warm %d >/dev/null 2>&1", warm_cfg()));
}

function warm_next() {
    let v = warm_cfg(), k = 0;
    for (let i = 0; i < length(WARM_STEPS); i++)
        if (WARM_STEPS[i] == v) k = i;
    v = WARM_STEPS[(k + 1) % length(WARM_STEPS)];
    if (ucur) {
        ucur.set("almond3s", "display", "warm", sprintf("%d", v));
        ucur.commit("almond3s");
    }
    warm_apply();
}

function warm_label() {
    let v = warm_cfg();
    if (v == 0)  return tr("off");
    if (v <= 30) return tr("light");
    if (v <= 60) return tr("medium");
    return tr("strong");
}

// Настройки одним местом. Раньше они были размазаны: «Экран» и «Заставка»
// плитками в меню, «Ночь» внутри «Заставки», редактор иконок и дебаг панели -
// кто где. Найти что-то можно было только помня, где оно лежит.
// Питание и Будильник сюда НЕ переехали - это функции, а не настройки.
let SETTINGS = [
    { label: "Display",      sub: "brightness, warm, language", act: "display" },
    { label: "Saver",        sub: "timeout and look",           act: "saver" },
    { label: "Night",        sub: "schedule and actions",       act: "night" },
    { label: "Editor",       sub: "pixel art",                  act: "iconedit" },
    { label: "Panel tuning", sub: "driver debug",               act: "debug" },
];

function settings_btn(i) {
    return { x: GX, y: 30 + i * 34, w: GW, h: 30 };
}

function draw_settings_page() {
    lcd_clear(C.bg);
    draw_header(tr("Settings"));

    for (let i = 0; i < length(SETTINGS); i++) {
        let b = settings_btn(i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, C.accent);
        lcd_text(b.x + 12, b.y + 4, tr(SETTINGS[i].label), C.white, C.widget, 1);
        lcd_text(b.x + 12, b.y + 17, tr(SETTINGS[i].sub), C.gray, C.widget, 1);
        lcd_text(b.x + b.w - 18, b.y + 10, ">", C.gray, C.widget, 2);
    }

    draw_back();
    lcd_flush();
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
    gcard(fb.x, fb.y, fb.w, fb.h, ff ? C.green : C.border);
    let flab = ff ? tr("FONT FLIPPER") : tr("FONT STD");
    lcd_text(fb.x + int((fb.w - tlen(flab) * 6) / 2) + 2, fb.y + 13, flab,
             ff ? C.white : C.gray, C.widget, 1);

    // Иконки меню и фон-градиент: два тумблера в одной строке. Цвет полоски
    // показывает состояние, справа компактное «вкл/выкл».
    let mb = micons_btn();
    gcard(mb.x, mb.y, mb.w, mb.h, MICONS_ON ? C.green : C.dim);
    lcd_text(mb.x + 12, mb.y + 9, tr("Menu icons"), C.white, C.widget, 1);
    lcd_text(mb.x + mb.w - 26, mb.y + 9, MICONS_ON ? tr("on") : tr("off"),
             MICONS_ON ? C.green : C.gray, C.widget, 1);

    let gb = grad_btn();
    gcard(gb.x, gb.y, gb.w, gb.h, GRAD_ON ? C.green : C.dim);
    lcd_text(gb.x + 12, gb.y + 9, tr("Background"), C.white, C.widget, 1);
    lcd_text(gb.x + gb.w - 26, gb.y + 9, GRAD_ON ? tr("on") : tr("off"),
             GRAD_ON ? C.green : C.gray, C.widget, 1);

    // Яркость: семь шагов, выбранный подсвечен.
    let bp = bright_cfg();
    lcd_text(GX + 4, 102, tr("LIGHT"), C.gray, C.bg, 1);
    for (let i = 0; i < length(BRIGHT_STEPS); i++) {
        let b = bright_btn(i), sel = (BRIGHT_STEPS[i] == bp);
        gcard(b.x, b.y, b.w, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", BRIGHT_STEPS[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 18, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    let wb = warm_btn(), wv = warm_cfg();
    gcard(wb.x, wb.y, wb.w, wb.h, wv ? "#F0A868" : C.dim);
    lcd_text(wb.x + 12, wb.y + 9, tr("Warm"), C.white, C.widget, 1);
    lcd_text(wb.x + wb.w - 8 - tlen(warm_label()) * 6, wb.y + 9, warm_label(),
             wv ? "#F0A868" : C.gray, C.widget, 1);

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
    lcd_rect(sb.x, sb.y, 3, sb.h, C.cyan);
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
    lcd_rect(hb.x, hb.y, 3, hb.h, on ? C.green : C.dim);
    let ht = tr("Shift");
    lcd_text(hb.x + int((hb.w - tlen(ht) * 12) / 2) + 2, hb.y + 12, ht,
             C.white, C.widget, 2);

    // Ночной режим: зелёная тусклая заставка по расписанию. Тап открывает
    // часы и включает, если был выключен.
    draw_back();
    lcd_flush();
}

// Часы ночного режима - отдельной страницей: открывается тапом по «Ночь».
function led_row(i) {
    return { x: 20, y: 44 + i * 56, w: 280, h: 44 };
}

// ===== Будильник =====
// Играет выбранную мелодию в заданное время. Крон-запись на точное время ставит
// alarm_set.sh (без поминутного опроса), играет alarm_play.sh, гасит
// alarm_stop.sh. Всё состояние - в config almond3s.alarm.
// Частоты звонка октавой ниже заводских: байты 0xB7/0x8B вешают PIC (issue #5).
let ALARM_SOUNDS = [
    { label: "звонок",  name: "tone",  args: "988 130 988 267 838 130 838 535" },
    { label: "скорая",  name: "ambulance", args: "" },
    { label: "полиция", name: "police", args: "" },
    { label: "марш",    name: "tone",
      args: "440 500 440 500 440 500 349 375 523 125 440 500 349 375 523 125 440 650" },
    { label: "сирена",  name: "siren", args: "" },
    { label: "бумер",   name: "tone",
      args: "660 240 784 720 0 400 784 240 660 720 0 400 880 240 784 240 880 240 784 240 880 240 784 240 880 240 784 240 880 240 988 720" },
    { label: "марио",   name: "mario", args: "" },
];
let ALARM_REPEATS = [ 0, 1, 2, 5, 10 ];   // минут; 0 = без повтора

function alarm_load() {
    let g = function(k, d) {
        let v = ucur ? ucur.get("almond3s", "alarm", k) : null;
        return (v == null || v == "") ? d : v;
    };
    st.alarm = {
        en:   g("enabled", "0") == "1",
        h:    int(g("hour", "7")),
        m:    int(g("minute", "0")),
        vol:  int(g("volume", "1")),
        mode: g("mode", "once"),
        rep:  int(g("repeat", "0")),
        si:   0,
    };
    let lbl = g("sound_label", "звонок");
    for (let i = 0; i < length(ALARM_SOUNDS); i++)
        if (ALARM_SOUNDS[i].label == lbl) st.alarm.si = i;
}

// Будильник активен? Источник истины - наличие cron-записи (её ставит/снимает
// alarm_set.sh при ВКЛ/ВЫКЛ и при once-срабатывании). Переживает ребут и ловит
// авто-выключение. Дёшево: одно чтение маленького файла.
function alarm_is_on() {
    let raw = fs.readfile("/etc/crontabs/root");
    return raw != null && index(raw, "almond3s-alarm") >= 0;
}

// Пишем конфиг и обновляем cron-запись под него (ставит/снимает запись на время).
function alarm_save() {
    if (!ucur || !st.alarm) return;
    let a = st.alarm, s = ALARM_SOUNDS[a.si];
    ucur.set("almond3s", "alarm", "alarm");   // создать секцию, если её нет
    ucur.set("almond3s", "alarm", "enabled", a.en ? "1" : "0");
    ucur.set("almond3s", "alarm", "hour", sprintf("%d", a.h));
    ucur.set("almond3s", "alarm", "minute", sprintf("%d", a.m));
    ucur.set("almond3s", "alarm", "sound", s.name);
    ucur.set("almond3s", "alarm", "sound_args", s.args);
    ucur.set("almond3s", "alarm", "sound_label", s.label);
    ucur.set("almond3s", "alarm", "volume", sprintf("%d", a.vol));
    ucur.set("almond3s", "alarm", "mode", a.mode);
    ucur.set("almond3s", "alarm", "repeat", sprintf("%d", a.rep));
    ucur.commit("almond3s");
    system("/etc/almond3s/scripts/alarm_set.sh >/dev/null 2>&1 &");
    st.alarm_on = a.en;   // иконку в статусе обновляем сразу
}

// Демонстрация выбранной мелодии (кнопка play).
function alarm_preview() {
    let s = ALARM_SOUNDS[st.alarm.si];
    let a = s.args != "" ? " " + s.args : "";
    system("k=$(cat /tmp/.lcd_tone.pid 2>/dev/null); [ -n \"$k\" ] && " +
           "kill $k 2>/dev/null; almond3s-lcd stop >/dev/null 2>&1");
    system(sprintf("almond3s-lcd %s -v %d%s >/dev/null 2>&1 &", s.name, st.alarm.vol, a));
}

// Прямоугольники контролов (общие для отрисовки и тача).
function alarm_rects() {
    return {
        // Время слева: крупные +/- кнопками, цифры между ними.
        hup:  { x: 8,  y: 28, w: 66, h: 20 }, hdn: { x: 8,  y: 80, w: 66, h: 18 },
        mup:  { x: 82, y: 28, w: 66, h: 20 }, mdn: { x: 82, y: 80, w: 66, h: 18 },
        // Мелодия справа: одна строка "< имя >", тап по имени = проигрывание.
        sprev:{ x: 158, y: 50, w: 44, h: 32 }, sname:{ x: 202, y: 50, w: 66, h: 32 },
        snext:{ x: 268, y: 50, w: 44, h: 32 },
        // Режим + повтор, ниже - громкость (мельче) и большой тумблер.
        mode: { x: 8,  y: 106, w: 150, h: 28 }, rep: { x: 162, y: 106, w: 150, h: 28 },
        vol:  { x: 8,  y: 142, w: 96,  h: 40 }, tog: { x: 112, y: 142, w: 200, h: 40 },
    };
}

function draw_alarm_page() {
    if (!st.alarm) alarm_load();
    let a = st.alarm, R = alarm_rects();
    lcd_clear(C.bg);
    draw_header(tr("Alarm"));

    // --- Время слева: цифры HH:MM, крупные кнопки +/- сверху и снизу ---
    let dc = a.en ? C.white : C.gray;
    let pm = function(r, g) {
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        // Прозрачный фон глифа: клетка size-3 (24px) выше плашки кнопки (18-20px)
        // и её фон вылезал бы вниз. Так рисуется только сам знак - он влезает.
        lcd_text(r.x + int((r.w - 18) / 2), r.y + int((r.h - 18) / 2) + 1, g, C.cyan, "none", 3);
    };
    pm(R.hup, "+"); pm(R.hdn, "-"); pm(R.mup, "+"); pm(R.mdn, "-");
    lcd_text(17, 50, sprintf("%02d", a.h), dc, C.bg, 4);   // часы
    lcd_text(70, 50, ":", dc, C.bg, 4);                    // двоеточие по центру
    lcd_text(91, 50, sprintf("%02d", a.m), dc, C.bg, 4);   // минуты

    // --- Мелодия справа: одна строка "< имя >". Тап по имени - проигрывание. ---
    let lbl = ALARM_SOUNDS[a.si].label;
    lcd_rect(158, 50, 154, 32, C.widget);
    lcd_text(168, 58, "<", C.cyan, C.widget, 2);
    lcd_text(296, 58, ">", C.cyan, C.widget, 2);
    lcd_text(158 + int((154 - tlen(lbl) * 12) / 2), 58, lbl, C.white, C.widget, 2);

    // --- Режим + повтор ---
    lcd_rect(R.mode.x, R.mode.y, R.mode.w, R.mode.h, C.widget);
    lcd_text(R.mode.x + 8, R.mode.y + 7, a.mode == "daily" ? tr("Daily") : tr("Once"),
             C.white, C.widget, 2);
    lcd_rect(R.rep.x, R.rep.y, R.rep.w, R.rep.h, C.widget);
    lcd_text(R.rep.x + 8, R.rep.y + 9,
             a.rep == 0 ? tr("no repeat") : sprintf("%s: %d %s", tr("repeat"), a.rep, tr("min")),
             C.white, C.widget, 1);

    // --- Громкость (компактно): подпись + 3 палочки, тап циклит 1..3 ---
    lcd_rect(R.vol.x, R.vol.y, R.vol.w, R.vol.h, C.widget);
    lcd_text(R.vol.x + 6, R.vol.y + 15, tr("vol"), C.gray, C.widget, 1);
    for (let b = 0; b < 3; b++) {
        let bh = 8 + b * 6, bx = R.vol.x + 38 + b * 16, by = R.vol.y + R.vol.h - 8 - bh;
        lcd_rect(bx, by, 11, bh, (b < a.vol) ? C.white : C.dim);
    }

    // --- Тумблер ВКЛ/ВЫКЛ ---
    let tbg = a.en ? "#0d3b1a" : C.widget;
    lcd_rect(R.tog.x, R.tog.y, R.tog.w, R.tog.h, tbg);
    lcd_rect(R.tog.x, R.tog.y, 5, R.tog.h, a.en ? C.green : C.red);
    lcd_text(R.tog.x + 58, R.tog.y + 12, a.en ? tr("ON") : tr("OFF"),
             a.en ? C.green : C.gray, tbg, 3);

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
        lcd_rect(b.x, b.y, 3, b.h, on ? C.green : C.dim);
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
        let bc = bars == 3 ? C.green : (bars == 2 ? C.orange : C.red);
        lcd_rect(b.x, b.y, 3, b.h, bc);
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
// Общая экранная клавиатура (терминал + ввод пароля Wi-Fi). Каждый ряд -
// массив клавиш: строка = символьная клавиша, объект {k,l,w} = спецклавиша
// (k - код, l - подпись, w - ширина в юнитах). Ряды набраны так, чтобы сумма
// ширин = 10. Спецклавиши встроены в ряды: ⌫ после l, ⇧ перед z, ↵ после m.
let KB_ROWS = {
    abc: [
        [ "q","w","e","r","t","y","u","i","o","p" ],
        [ "a","s","d","f","g","h","j","k","l", {k:"del",l:"<x"} ],
        [ {k:"shift",l:"^",w:1.5}, "z","x","c","v","b","n","m", {k:"enter",l:"OK",w:1.5} ],
        [ {k:"pg",l:"?123",w:2}, {k:"space",l:"space",w:6}, ".", "/" ],
    ],
    symA: [
        [ "1","2","3","4","5","6","7","8","9","0" ],
        [ "-","_","=","+","/","\\","|",":",";", {k:"del",l:"<x"} ],
        [ {k:"shift",l:"=>",w:1.5}, "@","#","$","%","&","*","?", {k:"enter",l:"OK",w:1.5} ],
        [ {k:"pg",l:"abc",w:2}, {k:"space",l:"space",w:6}, "!", "," ],
    ],
    symB: [
        [ "~","`","(",")","[","]","{","}","'","\"" ],
        [ "<",">","^","&","*","%","$","#","@", {k:"del",l:"<x"} ],
        [ {k:"shift",l:"<=",w:1.5}, "!","?",".",",",":",";","|", {k:"enter",l:"OK",w:1.5} ],
        [ {k:"pg",l:"abc",w:2}, {k:"space",l:"space",w:6}, "/", "\\" ],
    ],
    // Страница спецклавиш терминала: стрелки (навигация в nano, история команд
    // по стрелке вверх) и Esc/Tab/Home/End/PgUp/PgDn/Ins/Del.
    ext: [
        [ {k:"esc",l:"Esc",w:2}, {k:"tab",l:"Tab",w:2}, {k:"home",l:"Home",w:3}, {k:"end",l:"End",w:3} ],
        [ {k:"pgup",l:"PgUp",w:2.5}, {k:"pgdn",l:"PgDn",w:2.5}, {k:"ins",l:"Ins",w:2.5}, {k:"del2",l:"Del",w:2.5} ],
        [ {k:"pg",l:"abc",w:3.5}, {k:"up",l:"Up",w:3}, {k:"del",l:"<x",w:3.5} ],
        [ {k:"left",l:"Left",w:3.34}, {k:"down",l:"Down",w:3.33}, {k:"right",l:"Right",w:3.33} ],
    ],
};
// Нижний ряд для терминала: рядом с выбором цифр - залипающий Ctrl (для nano:
// ^X выход, ^O запись и т.п.). Только в терминале; на клавиатуре пароля его нет.
let KB_TERM_BOTTOM = {
    abc:  [ {k:"pg",l:"?123",w:1.5}, {k:"ctrl",l:"Ctrl",w:1.5}, {k:"space",l:"space",w:5}, ".", "/" ],
    symA: [ {k:"pg",l:"abc",w:1.5},  {k:"ctrl",l:"Ctrl",w:1.5}, {k:"space",l:"space",w:5}, "!", "," ],
    symB: [ {k:"pg",l:"abc",w:1.5},  {k:"ctrl",l:"Ctrl",w:1.5}, {k:"space",l:"space",w:5}, "/", "\\" ],
};
let KB_KEYS = [];   // прямоугольники клавиш последней отрисовки (для тапа)
let kb_pressed = null;  // клавиша под пальцем: рисуется вдавленной

function kb_draw(y0, kb) {
    KB_KEYS = [];
    let rows = KB_ROWS[kb.pg];
    // В терминале подменяем нижний ряд на вариант с Ctrl (кроме страницы стрелок).
    if (kb.term && kb.pg != "ext")
        rows = [ rows[0], rows[1], rows[2], KB_TERM_BOTTOM[kb.pg] ];
    let unit = (LCD_W - 8) / 10;
    for (let r = 0; r < length(rows); r++) {
        let row = rows[r], y = y0 + r * 28, cx = 4;
        for (let key in row) {
            let isobj = type(key) == "object";
            let wu = isobj ? (key.w ?? 1) : 1;
            let x = int(cx), w = int(wu * unit) - 2, h = 26;
            let ch = isobj ? null : ((kb.caps && kb.pg == "abc") ? uc(key) : key);
            let label = isobj ? key.l : ch;
            // Вдавленная клавиша: фон в тень, надпись затемняется и съезжает на
            // 1px вправо-вниз (как кнопки меню).
            let pd = (kb_pressed != null && kb_pressed.x == x && kb_pressed.y == y);
            let kbg = pd ? C.press : C.widget;
            lcd_rect(x, y, w, h, kbg);
            if (isobj) {
                let ac = key.k == "enter" ? C.green
                       : key.k == "del" ? C.yellow
                       : key.k == "ctrl" ? (kb.ctrl ? C.green : C.cyan)
                       : key.k == "shift" ? ((kb.caps && kb.pg == "abc") ? C.green : C.cyan)
                       : key.k == "pg" ? C.cyan : C.gray;
                lcd_rect(x, y, 3, h, ac);
            }
            let sc = isobj ? 1 : 2;
            let lw = length(label) * (sc == 2 ? 12 : 6);
            let o = pd ? 1 : 0;
            lcd_text(x + int((w - lw) / 2) + o, y + (sc == 2 ? 6 : 8) + o,
                     label, pd ? C.gray : C.white, kbg, sc);
            push(KB_KEYS, { x:x, y:y, w:w, h:h, ch:ch, k: isobj ? key.k : null });
            cx += wu * unit;
        }
    }
}

function kb_key_at(tx, ty) {
    for (let e in KB_KEYS)
        if (tx >= e.x && tx < e.x + e.w && ty >= e.y && ty < e.y + e.h) return e;
    return null;
}

// Короткая анимация нажатия: рисуем клавишу вдавленной, ждём ~45мс, отпускаем.
function kb_press_show(e, kb, y0) {
    kb_pressed = e;
    kb_draw(y0, kb);
    lcd_flush();
    kb_pressed = null;
    sock_poll(45);
}

// Применяет клавишу: мутирует kb (страница/регистр) для навигации, возвращает
// действие для буфера: {t:"char",ch} | {t:"del"} | {t:"space"} | {t:"enter"} |
// {t:"nav"}. Буфер (пароль/команда) правит вызывающий - он у всех свой.
// Спецклавиши терминала -> байты для PTY (xterm-последовательности).
let KB_SEQ = {
    up:   CTRL_ESC + "[A", down:  CTRL_ESC + "[B",
    right:CTRL_ESC + "[C", left:  CTRL_ESC + "[D",
    home: CTRL_ESC + "[H", end:   CTRL_ESC + "[F",
    pgup: CTRL_ESC + "[5~", pgdn: CTRL_ESC + "[6~",
    ins:  CTRL_ESC + "[2~", del2: CTRL_ESC + "[3~",
    esc:  CTRL_ESC,         tab:  chr(9),
};

function kb_apply(e, kb) {
    if (e.ch != null) return { t: "char", ch: e.ch };
    if (e.k == "del") return { t: "del" };
    if (e.k == "space") return { t: "space" };
    if (e.k == "enter") return { t: "enter" };
    if (e.k == "ctrl") { kb.ctrl = !kb.ctrl; return { t: "nav" }; }
    if (KB_SEQ[e.k] != null) return { t: "seq", s: KB_SEQ[e.k] };
    if (e.k == "pg") { kb.pg = (kb.pg == "abc") ? "symA" : "abc"; return { t: "nav" }; }
    if (e.k == "shift") {
        if (kb.pg == "abc") kb.caps = !kb.caps;
        else kb.pg = (kb.pg == "symA") ? "symB" : "symA";
        return { t: "nav" };
    }
    return { t: "nav" };
}

// Иконка клавиатуры для кнопки «назад» (белый прямоугольник с точками-клавишами).
function draw_kbd_icon(x, y) {
    lcd_rect(x, y, 30, 20, C.white);
    lcd_rect(x + 2, y + 2, 26, 16, C.back);
    for (let r = 0; r < 2; r++)
        for (let c = 0; c < 6; c++)
            lcd_rect(x + 4 + c * 4, y + 4 + r * 4, 2, 2, C.white);
    lcd_rect(x + 6, y + 13, 18, 3, C.white);   // «пробел»
}

function draw_kbd_page() {
    lcd_clear(C.bg);
    // Режим ввода города: то же поле+клавиатура, но текст открытый и свой буфер.
    if (st.kbmode == "city") {
        draw_header(tr("Custom city"));
        lcd_rect(10, 30, 300, 30, C.widget);
        let v = st.citybuf ?? "";
        lcd_text(18, 38, v != "" ? v : tr("Type city name"),
                 v != "" ? C.white : C.dim, C.widget, 2);
        kb_draw(92, st.citykb);
        draw_back();
        lcd_flush();
        return;
    }
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

    kb_draw(92, sta.kb);   // общая клавиатура (встроенные ⌫⇧↵)
    draw_back();           // полоса «назад» = отмена ввода
    lcd_flush();
}

// ===== Терминал =====
// Настоящий шелл роутера на экране. Ввод-вывод держит фоновый демон
// almond3s-term: forkpty(ash) + libvterm разбирают поток PTY в текстовую сетку
// /tmp/.almond3s_term_grid (эталонный VT-эмулятор - `ls` даёт колонки, работает
// cd, редактирование строки, top/vi). Мы её только рисуем, а нажатия шлём в fifo
// /tmp/.almond3s_term_in. Клавиатуру можно скрыть - тогда окно шелла выше
// (8 строк с клавой, 22 без); демон живёт лишь пока открыта страница.
let TERM_BIN  = "/usr/libexec/almond3s/almond3s-term";
let TERM_GRID = "/tmp/.almond3s_term_grid";
let TERM_FIFO = "/tmp/.almond3s_term_in";
let TERM_PID  = "/tmp/.almond3s_term.pid";
let TERM_COLS = 52;      // символов в строке (6px, экран 320)

function term_rows() { return st.term.kbd ? 8 : 22; }

// Живость демона по pidfile + /proc: fork-free и надёжнее pgrep. Открытие fifo
// на запись без читателя вешает писателя навсегда (и весь ui.uc), поэтому пишем
// только живому - и всё равно в фоне, на случай гонки «умер между проверкой и
// записью».
function term_alive() {
    let pf = fs.open(TERM_PID, "r");
    if (!pf) return false;
    let pid = "";
    try { pid = trim(pf.read("all") ?? ""); } catch (e) {}
    pf.close();
    if (pid == "") return false;
    // сверяем cmdline - защита от стухшего pidfile, чей PID переиспользован.
    let cf = fs.open("/proc/" + pid + "/cmdline", "r");
    if (!cf) return false;
    let cmd = "";
    try { cmd = cf.read("all") ?? ""; } catch (e) {}
    cf.close();
    return index(cmd, "almond3s-term") >= 0;
}

// Сырые байты уходят октальными экранами через printf: любой символ (кавычки,
// $, \, управляющие) без возни с шелл-кавычками.
function term_write(s) {
    if (!term_alive()) return false;
    let oct = "";
    for (let i = 0; i < length(s); i++)
        oct += sprintf("\\%03o", ord(s, i));
    system("printf '" + oct + "' > " + TERM_FIFO + " 2>/dev/null &");
    return true;
}

function term_resize() {
    return term_write(chr(1) + sprintf("r%dx%d", TERM_COLS, term_rows()) + chr(10));
}

function term_start() {
    // единственный экземпляр: сносим прежний по имени (killall себя не заденет),
    // затем поднимаем свежий, отвязанный от нашего сеанса (setsid).
    system("killall almond3s-term 2>/dev/null; setsid " + TERM_BIN +
           " </dev/null >/dev/null 2>&1 &");
    st.tgrid = "";
    st.term_rows_sent = -1;
    st.term.scroll = 0;
    st.term.kb.pg = "abc";
    st.term.kb.ctrl = false;
    st.term.hold = null;
    kb_pressed = null;
    st.term_was_alive = false;   // для «печать exit -> закрыть терминал»
}

function term_stop() {
    system("killall almond3s-term 2>/dev/null");
    st.tgrid = "";
    st.term.hold = null;
    kb_pressed = null;
}

// Клавиши, которые имеет смысл автоповторять при удержании: буквы/символы,
// Backspace, пробел, стрелки/спец (не pg/shift/ctrl/enter).
function term_key_repeatable(e) {
    if (e.ch != null) return true;
    return e.k == "del" || e.k == "space" || KB_SEQ[e.k] != null;
}

// Применяет клавишу и отправляет её демону (учитывая залипающий Ctrl). Печать
// возвращает прокрутку к низу. Используется и при тапе, и при автоповторе.
function term_send_key(e, t) {
    let a = kb_apply(e, t.kb);
    if (a.t == "char" || a.t == "del" || a.t == "space" ||
        a.t == "enter" || a.t == "seq") t.scroll = 0;
    if (a.t == "char") {
        if (t.kb.ctrl) { term_write(chr(ord(a.ch, 0) & 0x1f)); t.kb.ctrl = false; }
        else term_write(a.ch);
    }
    else if (a.t == "del")   { term_write(chr(127)); t.kb.ctrl = false; }
    else if (a.t == "space") { term_write(" ");      t.kb.ctrl = false; }
    else if (a.t == "enter") { term_write(chr(13));  t.kb.ctrl = false; }
    else if (a.t == "seq")   { term_write(a.s);      t.kb.ctrl = false; }
}

function term_grid() {
    let fh = fs.open(TERM_GRID, "r");
    if (!fh) return "";
    // read() оборачиваем: term_grid зовётся из 90мс-таймера, и брось он
    // исключение - оно бы всплыло в uloop и уронило цикл, оставив дескриптор.
    let raw = "";
    try { raw = fh.read("all") ?? ""; } catch (e) {}
    fh.close();
    return raw;
}

// Нижняя красная панель терминала: слева «Fn» (страница стрелок/спецклавиш),
// по центру «Выход», справа иконка показа/скрытия клавиатуры. Зоны по x
// разведены: tx<52 - Fn, tx>=278 - клава, между - выход.
function draw_term_bar() {
    lcd_rect(0, BACK_Y, LCD_W, 32, C.back);
    lcd_rect(0, BACK_Y, LCD_W, 2, "#D32F2F");
    // Fn - редактируемая иконка (30x20, слот "fn" в редакторе). Активна
    // (открыта страница стрелок) - рисуем вторым проходом со сдвигом 1px = жирнее.
    let active = st.term.kb.pg == "ext";
    draw_fn_icon(8, BACK_Y + 6, C.white);
    if (active) draw_fn_icon(9, BACK_Y + 6, C.white);
    lcd_text(130, BACK_Y + 9, tr("Exit"), C.white, C.back, 2);
    draw_kbd_icon(284, BACK_Y + 6);
}

function draw_term_page() {
    if (st.halting) return;
    lcd_clear(C.bg);
    draw_header(tr("Terminal"));
    let t = st.term;
    let out_top = HDR_H + 2;

    // Сетка: первая строка - "nlines cols cur_x cur_line" (история+экран),
    // дальше строки. Рисуем окно высотой visible со сдвигом прокрутки.
    let lines = split(st.tgrid ?? "", "\n");
    let hdr = split(lines[0] ?? "", " ");
    let nlines = int(hdr[0] ?? 0);
    let cx0 = int(hdr[2] ?? 0), cur_line = int(hdr[3] ?? 0);
    let visible = term_rows();

    if (nlines <= 0) {
        lcd_text(4, out_top, tr("starting shell..."), C.dim, "none", 1);
    } else {
        let maxstart = nlines - visible;
        if (maxstart < 0) maxstart = 0;
        let sc = t.scroll ?? 0;
        if (sc > maxstart) sc = maxstart;
        if (sc < 0) sc = 0;
        t.scroll = sc;
        let start = maxstart - sc;       // sc=0 -> низ (следим за шеллом)
        // Прозрачный фон ("none"): под буквами остаётся подложка, а не чернота.
        for (let r = 0; r < visible && (start + r) < nlines; r++)
            lcd_text(4, out_top + r * 8, lines[1 + start + r] ?? "", "#3fb950", "none", 1);
        // курсор подчёркиванием, только если он в окне (при прокрутке вверх нет).
        if (cur_line >= start && cur_line < start + visible)
            lcd_rect(4 + cx0 * 6, out_top + (cur_line - start) * 8 + 7, 6, 2, C.cyan);
        // индикатор прокрутки: не у низа - показываем стрелку вверх.
        if (sc > 0) lcd_text(LCD_W - 10, out_top, "^", C.yellow, "none", 1);
    }

    if (t.kbd)
        kb_draw(92, t.kb);
    draw_term_bar();
    lcd_flush();
}

function draw_battery_page() {
    let bat = st.data?.battery ?? {};
    lcd_clear(C.bg);
    draw_header(tr("Battery"));

    let cx = GX, cw = GW;
    let pct = int(+(bat?.percent ?? -1));
    let adc = int(+(bat?.adc ?? 0));
    let chg = bat?.charging && !bat?.no_battery;
    let full = (bat?.full && !bat?.no_battery) || (chg && pct >= 100);
    // Состояние: уровень крупно слева, статус и АЦП по правому краю.
    let y1 = GY;
    let pcol = pct < 0 ? C.dim : (pct <= 5 && !chg ? C.red : (pct <= 25 ? C.orange : C.green));
    gcard(cx, y1, cw, 50, pcol);
    lcd_text(cx + 12, y1 + 10, pct < 0 ? "--" : sprintf("%d%%", pct), pcol, C.widget, 3);
    let st_s = bat?.no_battery ? tr("Battery not installed")
             : (full ? tr("Plugged in") : (chg ? tr("Charging") : tr("Battery")));
    lcd_text(cx + cw - 12 - tlen(st_s) * 6, y1 + 10, st_s, C.white, C.widget, 1);
    // Вольты вместо сырого АЦП по ТОЧНОЙ стоковой формуле (из дизасма ядра:
    // ADC*3.3*(1/1024)*7.11*0.5 = ADC*0.01145654); прежняя adc*8.4/726
    // завышала на ~1% (при 726 рисовала 8.4В, реально 8.32В).
    let adc_s = adc > 0 ? sprintf("%.2f %s", adc * 0.01145654, tr("V")) : "";
    lcd_text(cx + cw - 12 - tlen(adc_s) * 6, y1 + 26, adc_s, C.gray, C.widget, 1);

    // Время работы от батареи с момента, когда сняли зарядку (даёт collector).
    let obs = int(+(bat?.on_bat_sec ?? 0));
    if (!chg && !full && !bat?.no_battery && obs > 0) {
        let ob = sprintf(tr("on battery %s"),
                         obs < 60 ? sprintf("%d %s", obs, tr("sec")) : fmt_dur(int(obs / 60), false));
        lcd_text(cx + cw - 12 - tlen(ob) * 6, y1 + 40, ob, C.gray, C.widget, 1);
    }

    // Прогноз: слева подпись и время, справа расход.
    let y2 = y1 + 50 + GG;
    gcard(cx, y2, cw, 40, C.cyan);
    let cap = full ? tr("charge complete")
            : (chg ? tr("To full charge") : tr("Time left"));
    let rmin = int(+(bat?.remain_min ?? -1));
    let tstr = full ? "" : (rmin > 0 ? fmt_dur(rmin, false) : tr("estimating"));
    lcd_text(cx + 12, y2 + 8, cap, C.white, C.widget, 1);
    if (tstr != "")
        lcd_text(cx + 12, y2 + 22, tstr, C.gray, C.widget, 1);
    let drain = +(bat?.drain_rate ?? 0);
    let d1 = tr("drain");
    // Скорость разряда в процентах в час: сырые «АЦП/мин» человеку ни о
    // чём (пересчёт линейный по рабочему диапазону 512..726 ~= 0..100%).
    let d2 = drain > 0 ? sprintf("%d%s", int(drain * 6000 / 214), tr("%/h")) : tr("measuring");
    lcd_text(cx + cw - 12 - tlen(d1) * 6, y2 + 8, d1, C.white, C.widget, 1);
    lcd_text(cx + cw - 12 - tlen(d2) * 6, y2 + 22, d2, C.gray, C.widget, 1);

    // Графики за последние ~2 часа: слева заряд, справа сырой АЦП.
    let y3 = y2 + 40 + GG;
    gcard(cx, y3, cw, 56, chg ? C.green : C.yellow);
    lcd_text(cx + 12, y3 + 4, tr("CHARGE %"), C.gray, C.widget, 1);
    lcd_text(cx + 158, y3 + 4, tr("VOLTAGE"), C.gray, C.widget, 1);
    // Историю ведёт collector в файле (двухчасовое окно, точка в минуту):
    // страница показывает кривые сразу, рестарты UI их не стирают.
    let bh_pct = [], bh_adc = [];
    let bh_raw = fs.readfile("/tmp/almond3s_bat_hist");
    if (bh_raw) {
        for (let line in split(bh_raw, "\n")) {
            let m = match(line, /^(\d+) (\d+) [01]$/);
            if (!m) continue;
            push(bh_adc, +m[1]);
            push(bh_pct, +m[2]);
        }
    }
    // Заряд - линией по честной шкале 0..100 (режим заливки считает
    // высоту логарифмом под байты трафика и для процентов даёт ноль).
    draw_graph_compact(cx + 10, y3 + 16, 136, 36, bh_pct, C.green, 0, 100, false);
    // АЦП - с автомасштабом по данным: на фиксированной шкале 500..730
    // час зарядки выглядел одной неподвижной полосой.
    let abm = arr_minmax(bh_adc);
    draw_graph_compact(cx + 156, y3 + 16, 136, 36, bh_adc, C.cyan,
                       abm.min - 4, abm.max + 4, false);

    // Подвал: счётчик циклов (копится с этой версии) и пределы платы.
    let cyc = 0;
    let ce = fs.readfile("/etc/almond3s/charge_events");
    if (ce) {
        for (let ch in split(ce, "\n"))
            if (ch != "") cyc++;
    }
    let cofv = int(+(bat?.cutoff ?? 512)) * 0.01145654;
    let foot = cyc > 0
        ? sprintf(tr("Charge cycles: %d  range %.1f-8.3V"), cyc, cofv)
        : sprintf(tr("range %.1f-8.3V, discharges in %s"), cofv, fmt_dur(263, true));
    lcd_text(cx + 2, y3 + 62, foot, C.dim, "none", 1);

    draw_back();
    lcd_flush();
}

function games_btn(i) {
    return { x: 8, y: 28 + i * 34, w: 304, h: 30 };
}

// Листалка: ромов стало много, на страницу помещается четыре.
function games_arrow(dir) {
    return { x: dir < 0 ? 112 : 224, y: 172, w: 88, h: 28 };
}

// Кнопка настроек живёт между стрелками листалки: отдельной строки на неё в
// списке нет, а место посередине всё равно занимал только счётчик страниц.
function games_cfg_btn() {
    return { x: 8, y: 172, w: 96, h: 28 };
}

// Переключатели эмулятора лежат в файлах: он перечитывает их на живую, без
// перезапуска игры. Здесь мы им просто даём лицо.
let KEYFILE = "/etc/almond3s/nes_keys";

let GSET = [
    { file: "/etc/almond3s/nes_fps",   label: "Кадры",  vals: [ "all", "45", "30" ],
      names: [ "60", "45", "30" ], def: "all" },
    { file: "/etc/almond3s/nes_blend", label: "Склейка", vals: [ "off", "avg", "max" ],
      names: [ "выкл", "полусумма", "максимум" ], def: "off" },
    // Ровный ритм: кадров доходит меньше, но через равные промежутки - глаз
    // читает как плавность именно регулярность, а не их число.
    { file: "/etc/almond3s/nes_cadence", label: "Ритм", vals: [ "even", "off" ],
      names: [ "ровный", "как есть" ], def: "even" },
    // Звук выключен: на этой плате динамик висит на PIC, а не на звуковой
    // шине, выхода нет. Выключатель сделан под будущее железо.
    { file: "/etc/almond3s/nes_sound", label: "Звук", vals: [ "off", "on" ],
      names: [ "выкл", "вкл" ], def: "off" },
    // Глубина цвета панели: 12 бит - это на четверть меньше байтов по шине
    // GPIO, то есть выше частота обновления, ценой ступенек на градиентах.
    { file: "/etc/almond3s/lcd_color12", label: "Цвет", vals: [ "0", "1" ],
      names: [ "16 бит", "12 бит" ], def: "0",
      sysfs: "/sys/module/almond3s_lcd/parameters/color12" },
    // Обновление через строку: байтов по шине вдвое меньше, но на быстром
    // движении видна гребёнка.
    { file: "/etc/almond3s/lcd_interlace", label: "Через строку", vals: [ "0", "1" ],
      names: [ "выкл", "вкл" ], def: "0",
      sysfs: "/sys/module/almond3s_lcd/parameters/interlace" },
];

function gset_read(i) {
    let raw = fs.readfile(GSET[i].file);
    let v = raw ? trim(raw) : GSET[i].def;
    for (let k = 0; k < length(GSET[i].vals); k++)
        if (GSET[i].vals[k] == v) return k;
    return 0;
}

// Настройка, у которой есть sysfs, живёт в параметре модуля - файл лишь
// помнит выбор между перезагрузками.
function gset_apply(i) {
    if (!GSET[i].sysfs) return;
    fs.writefile(GSET[i].sysfs, GSET[i].vals[gset_read(i)]);
}

function gset_apply_all() {
    for (let i = 0; i < length(GSET); i++) gset_apply(i);
}

function gset_next(i) {
    let k = (gset_read(i) + 1) % length(GSET[i].vals);
    fs.writefile(GSET[i].file, GSET[i].vals[k] + "\n");
    gset_apply(i);
    return k;
}

function gset_btn(i) {
    return { x: 8, y: 28 + i * 24, w: 304, h: 22 };
}

// Кнопка «Пульт» под списком настроек - ведёт на страницу с QR-кодами.
function gqr_btn() {
    return { x: 8, y: 32 + length(GSET) * 24, w: 148, h: 26 };
}

function gkeys_btn() {
    return { x: 164, y: 32 + length(GSET) * 24, w: 148, h: 26 };
}

function lan_ip() {
    let raw = fs.popen("uci -q get network.lan.ipaddr", "r");
    let v = raw ? trim(raw.read("all") ?? "") : "";
    if (raw) raw.close();
    v = split(v, "/")[0];              // uci отдаёт адрес с маской
    return (v && v != "") ? v : "192.168.1.1";
}

// Сервер джойстика поднимается вместе с игрой и живёт только пока она идёт.
// Номер игрока берётся из ссылки, поэтому коды разные: кто по какому зашёл,
// тот тем и играет, а не «кто успел первым».
function pad_url(player) {
    return sprintf("http://%s:8099/?p=%d", lan_ip(), player);
}

function draw_gqr_page() {
    lcd_clear(C.bg);
    draw_header(tr("Gamepad"));

    for (let i = 0; i < 2; i++) {
        let x = 22 + i * 156;
        draw_qr(qr_rows(pad_url(i + 1)), x, 46, 3, "#000000", "#FFFFFF");
        lcd_text(x + 4, 140, sprintf(tr("Player %d"), i + 1), C.white, C.bg, 1);
    }
    lcd_text(12, 168, tr("scan while a game is running"), C.dim, C.bg, 1);
    lcd_text(12, 184, pad_url(1), C.gray, C.bg, 1);

    draw_back();
    lcd_flush();
}

// Раскладка клавиатуры. Ловит нажатие помощником keygrab: разбирать двоичные
// события /dev/input прямо здесь неудобно, а он печатает один код и выходит.
let KEYS = [
    { id: "a",      label: "A (прыжок)", def: 45 },
    { id: "b",      label: "B (бег)",    def: 44 },
    { id: "start",  label: "START",      def: 28 },
    { id: "select", label: "SELECT",     def: 42 },
    { id: "exit",   label: "Выход",      def: 1  },
];

// Имена для кодов, которые реально попадаются; остальное показываем числом.
let KEYNAMES = {
    "1": "ESC", "28": "ENTER", "42": "SHIFT", "54": "SHIFT",  "57": "ПРОБЕЛ",
    "44": "Z", "45": "X", "46": "C", "47": "V", "48": "B", "49": "N", "50": "M",
    "30": "A", "31": "S", "32": "D", "33": "F", "34": "G", "35": "H", "36": "J",
    "37": "K", "38": "L", "16": "Q", "17": "W", "18": "E", "19": "R", "20": "T",
    "21": "Y", "22": "U", "23": "I", "24": "O", "25": "P",
    "103": "ВВЕРХ", "108": "ВНИЗ", "105": "ВЛЕВО", "106": "ВПРАВО",
    "96": "ENTER", "29": "CTRL", "56": "ALT", "15": "TAB",
};

function keymap_read() {
    let m = {};
    for (let k in KEYS) m[k.id] = k.def;
    let raw = fs.readfile(KEYFILE);
    if (raw)
        for (let ln in split(trim(raw), "\n")) {
            let f = split(trim(ln), /\s+/);
            if (length(f) == 2 && int(f[1]) > 0) m[f[0]] = int(f[1]);
        }
    return m;
}

function keymap_write(m) {
    let out = "";
    for (let k in KEYS) out += k.id + " " + m[k.id] + "\n";
    fs.writefile(KEYFILE, out);
}

function gkey_btn(i) {
    return { x: 8, y: 32 + i * 32, w: 304, h: 28 };
}

function key_title(code) {
    return KEYNAMES[sprintf("%d", code)] ?? sprintf("код %d", code);
}

function draw_gkeys_page() {
    lcd_clear(C.bg);
    draw_header(tr("Keyboard"));

    let m = keymap_read();
    for (let i = 0; i < length(KEYS); i++) {
        let b = gkey_btn(i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, C.accent);
        lcd_text(b.x + 12, b.y + 8, KEYS[i].label, C.gray, C.widget, 1);
        lcd_text(b.x + 180, b.y + 8, key_title(m[KEYS[i].id]), C.white, C.widget, 1);
    }
    lcd_text(12, 32 + length(KEYS) * 32 + 4, tr("tap a row, then press a key"), C.dim, C.bg, 1);

    draw_back();
    lcd_flush();
}

// Ждём нажатие и записываем. Пока ждём, показываем это на самой строке -
// иначе непонятно, слушает интерфейс или подвис.
function gkey_learn(i) {
    let b = gkey_btn(i);
    lcd_rect(b.x, b.y, b.w, b.h, C.press);
    lcd_rect(b.x, b.y, 3, b.h, C.accent);
    lcd_text(b.x + 12, b.y + 8, KEYS[i].label, C.gray, C.press, 1);
    lcd_text(b.x + 180, b.y + 8, tr("press a key"), C.accent, C.press, 1);
    lcd_flush();

    let p = fs.popen("/usr/libexec/almond3s/keygrab 8 2>/dev/null", "r");
    let code = p ? int(trim(p.read("all") ?? "")) : 0;
    if (p) p.close();

    if (code > 0) {
        let m = keymap_read();
        m[KEYS[i].id] = code;
        keymap_write(m);
    }
    draw_gkeys_page();
}

function draw_gset_page() {
    lcd_clear(C.bg);
    draw_header(tr("Setup"));

    for (let i = 0; i < length(GSET); i++) {
        let b = gset_btn(i);
        let k = gset_read(i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, C.accent);
        lcd_text(b.x + 10, b.y + 7, GSET[i].label, C.gray, C.widget, 1);
        lcd_text(b.x + 150, b.y + 7, GSET[i].names[k], C.white, C.widget, 1);
    }
    let kb = gkeys_btn();
    lcd_rect(kb.x, kb.y, kb.w, kb.h, C.widget);
    lcd_rect(kb.x, kb.y, 3, kb.h, C.accent);
    lcd_text(kb.x + 10, kb.y + 8, tr("Keys"), C.accent, C.widget, 1);

    let q = gqr_btn();
    lcd_rect(q.x, q.y, q.w, q.h, C.widget);
    lcd_rect(q.x, q.y, 3, q.h, C.accent);
    lcd_text(q.x + 10, q.y + 8, tr("Gamepad"), C.accent, C.widget, 1);

    draw_back();
    lcd_flush();
}

function draw_games_page() {
    lcd_clear(C.bg);
    draw_header(tr("Games"));

    let roms = rom_list();
    let pages = length(roms) > 4 ? int((length(roms) + 3) / 4) : 1;
    if (st.gpg == null || st.gpg >= pages) st.gpg = 0;
    let base = st.gpg * 4;
    for (let i = 0; i < 4 && base + i < length(roms); i++) {
        let r = games_btn(i);
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        lcd_rect(r.x, r.y, 3, r.h, C.accent);
        lcd_text(r.x + 12, r.y + 9, tcut(roms[base + i].name, 46), C.white, C.widget, 1);
    }
    let cb = games_cfg_btn();
    lcd_rect(cb.x, cb.y, cb.w, cb.h, C.widget);
    lcd_rect(cb.x, cb.y, 3, cb.h, C.accent);
    lcd_text(cb.x + 10, cb.y + 10, tr("Setup"), C.accent, C.widget, 1);

    if (pages > 1) {
        let a = games_arrow(-1), z = games_arrow(1);
        lcd_rect(a.x, a.y, a.w, a.h, C.widget);
        lcd_text(a.x + 32, a.y + 8, "<<", C.accent, C.widget, 2);
        lcd_rect(z.x, z.y, z.w, z.h, C.widget);
        lcd_text(z.x + 32, z.y + 8, ">>", C.accent, C.widget, 2);
        // Просвет между стрелками 200..224, текст 3 знака по 6px - ставим в центр.
        lcd_text(203, z.y + 11, sprintf("%d/%d", st.gpg + 1, pages), C.gray, C.bg, 1);

    }

    // Подсказка, когда ромов нет или эмулятор не поставлен.
    let y = 28 + (length(roms) + 1) * 34 + 6;
    if (!fs.stat(NES_BIN))
        lcd_text(12, y, tr("emulator not installed"), C.dim, C.bg, 1);
    else if (!length(roms)) {
        lcd_text(12, y, tr("Put .nes into"), C.dim, C.bg, 1);
        lcd_text(12, y + 12, ROM_DIRS[0], C.gray, C.bg, 1);
    }

    draw_back();
    lcd_flush();
}


function draw_zigbee_page() {
    lcd_clear(C.bg);
    draw_header(tr("Zigbee"));

    let cx = GX, cw = GW;
    let y1 = GY;
    gcard(cx, y1, cw, 50, C.accent);
    lcd_text(cx + 12, y1 + 6, "Silicon Labs EM357", C.white, C.widget, 1);
    lcd_text(cx + 12, y1 + 20, "EZSP v4, EmberZNet 5.1.0", C.gray, C.widget, 1);
    lcd_text(cx + 12, y1 + 34, "/dev/ttyS2, 57600 8N1", C.gray, C.widget, 1);

    let y2 = y1 + 50 + GG;
    gcard(cx, y2, cw, 40, C.yellow);
    lcd_text(cx + 12, y2 + 8, tr("Not joined to any network"), C.white, C.widget, 1);
    lcd_text(cx + 12, y2 + 22, tr("Modern software needs EZSP 8+"), C.gray, C.widget, 1);

    let y3 = y2 + 40 + GG;
    gcard(cx, y3, cw, 52, C.gray);
    lcd_text(cx + 12, y3 + 6, tr("UPGRADE PATH"), C.gray, C.widget, 1);
    lcd_text(cx + 12, y3 + 20, tr("Flash EmberZNet 6.7.10 over SWD"), C.white, C.widget, 1);
    lcd_text(cx + 12, y3 + 34, tr("header J5705, see ZIGBEE.md"), C.gray, C.widget, 1);

    draw_back();
    lcd_flush();
}

// =============================================
//  VPN (SSClash / mihomo)
//
// Меню появляется, только если стоит SSClash (init-скрипт есть). Данные тянет
// мост vpn_clash.sh через API ядра - дорого, поэтому зовём при входе и после
// действий, а не в общем refresh_data. Карточки групп раскрываются в список
// серверов, тап переключает узел (PUT /proxies/<group>).
// =============================================

let VPN_GPP = 3, VPN_MPP = 6;   // групп и серверов на страницу

function vpn_sh(args) {
    let p = fs.popen(SCRIPTS + "/vpn_clash.sh " + args, "r");
    if (!p) return null;
    let out = p.read("all");
    p.close();
    return out;
}

// want_delays: тянуть ли /providers/proxies (278КБ, ~2-3с). Нужно при входе и
// после пинга; при выборе сервера задержки не меняются - переиспользуем прошлые.
function vpn_refresh(want_delays) {
    let v = { installed: vpn_present() ? 1 : 0, running: 0, enabled: 0,
              groups: [], delays: {}, provider: {} };
    let sraw = vpn_sh("status");
    if (sraw) {
        try { let s = json(sraw);
              v.running = int(+(s?.running ?? 0));
              v.enabled = int(+(s?.enabled ?? 0)); } catch(e) {}
    }
    if (v.running) {
        let graw = vpn_sh("groups");
        if (graw) {
            try {
                let px = json(graw)?.proxies ?? {};
                // Задержки прямых узлов из history (0 = не измерено/таймаут).
                for (let name in px) {
                    let h = px[name]?.history;
                    if (type(h) == "array" && length(h) > 0)
                        v.delays[name] = int(+(h[length(h) - 1]?.delay ?? 0));
                }
                // mihomo отдаёт объект прокси. Группа - это запись с непустым
                // списком членов all[]. Берём ВСЕ типы (Selector, URLTest,
                // Fallback, LoadBalance, Relay), кроме служебной GLOBAL и
                // скрытых. url-test тоже переключается вручную (ядро фиксирует),
                // поэтому показываем все.
                for (let name in px) {
                    let e = px[name];
                    if (e?.hidden) continue;
                    let all = type(e?.all) == "array" ? e.all : [];
                    if (length(all) == 0) continue;
                    push(v.groups, {
                        name: name,
                        gtype: e?.type ?? "",
                        now: e?.now ?? "",
                        fixed: e?.fixed ?? "",
                        all: all,
                    });
                }
            } catch(e) {}
        }
        // Узлы подписок: их задержки и провайдер (для точечного пинга) - из
        // /providers/proxies. Реальные серверы SSClash приходят отсюда. Дорого,
        // поэтому только когда просят; иначе берём прошлые (при выборе не меняются).
        if (want_delays) {
            let praw = vpn_sh("providers");
            if (praw) {
                try {
                    let pv = json(praw)?.providers ?? {};
                    for (let pn in pv) {
                        let arr = pv[pn]?.proxies;
                        if (type(arr) != "array") continue;
                        for (let node in arr) {
                            let nm = node?.name;
                            if (!nm) continue;
                            v.provider[nm] = pn;
                            let h = node?.history;
                            if (type(h) == "array" && length(h) > 0)
                                v.delays[nm] = int(+(h[length(h) - 1]?.delay ?? 0));
                        }
                    }
                } catch(e) {}
            }
        } else if (st.vpn) {
            v.delays = st.vpn.delays ?? v.delays;
            v.provider = st.vpn.provider ?? {};
        }
        // GLOBAL - служебная «всё сразу», отправляем в конец списка.
        let ordered = [], glob = null;
        for (let g in v.groups) { if (uc(g.name) == "GLOBAL") glob = g; else push(ordered, g); }
        if (glob) push(ordered, glob);
        v.groups = ordered;
    }
    st.vpn = v;
    if (st.vpn_exp != null && st.vpn_exp >= length(v.groups)) st.vpn_exp = null;
}

function vpn_tog_rect()     { return { x: GX, y: GY, w: GW, h: 40 }; }
function vpn_group_rect(i)  { return { x: GX, y: GY + 48 + i * 34, w: GW, h: 28 }; }
function vpn_member_rect(i) { return { x: GX, y: GY + i * 24, w: GW, h: 22 }; }
function vpn_pg_rect(dir)   { return { x: dir < 0 ? GX : GX + GCOL + GG, y: 176, w: GCOL, h: 26 }; }

// Авто-группы (url-test/fallback/...) можно вернуть в автоподбор - для них
// первым пунктом идёт «Авто». У Selector такого нет: там выбор всегда ручной.
function vpn_auto(g)  { return (g.gtype ?? "") != "" && (g.gtype ?? "") != "Selector"; }

// Цвет и текст задержки узла: зелёный/оранжевый/красный по порогам, «-» если
// не измерено (0) или таймаут.
function vpn_delay_col(ms) {
    if (ms <= 0) return C.dim;
    if (ms <= 200) return C.green;
    if (ms <= 450) return C.orange;
    return C.red;
}
function vpn_delay_txt(ms) {
    if (ms <= 0) return "-";
    if (ms >= 1000) return sprintf("%d.%dk", int(ms / 1000), int((ms % 1000) / 100));
    return sprintf("%d", ms);
}
function vpn_delay(name) {
    return int(+((st.vpn?.delays ?? {})[name] ?? 0));
}

// Кнопка задержки: рамка + цифра цветом. Тап = пинг. Пока идёт замер (в фоне)
// кнопка вдавлена и показывает «...» (st.vpn_ping.key = ключ строки). key:
// "m<i>" сервер, "g<i>" группа.
function vpn_dbtn(r) {
    return { x: r.x + r.w - 50, y: r.y + int((r.h - 18) / 2), w: 44, h: 18 };
}
function draw_dbtn(r, ms, key) {
    let b = vpn_dbtn(r), pinging = (st.vpn_ping?.key == key), o = pinging ? 1 : 0;
    let bg = pinging ? C.press : C.btn;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    if (!pinging) lcd_rect(b.x, b.y + b.h - 2, b.w, 2, C.border);   // кант «кнопки»
    let txt = pinging ? "..." : vpn_delay_txt(ms);
    let col = pinging ? C.cyan : vpn_delay_col(ms);
    lcd_text(b.x + int((b.w - tlen(txt) * 6) / 2) + o, b.y + 6 + o, txt, col, bg, 1);
}

// Запустить пинг В ФОНЕ: команда пишет done-файл по завершении, UI опрашивает
// его в таймере данных и дорисовывает цифру. Так интерфейс не виснет на замере.
function vpn_ping_bg(cmd, key) {
    fs.unlink("/tmp/.vpn_ping_done");
    system("( " + cmd + " ; touch /tmp/.vpn_ping_done ) >/dev/null 2>&1 &");
    st.vpn_ping = { key: key, ts: time() };
    draw_vpn_page();
}
function vpn_items(g) {
    let items = [];
    if (vpn_auto(g)) push(items, "__AUTO__");
    for (let x in (type(g.all) == "array" ? g.all : [])) push(items, x);
    return items;
}

// ============================ СПИДТЕСТ ============================
// Порт теста скорости из 5gmodem: тот же бэкенд speedtest.sh (start/status/stop),
// живой JSON в /tmp/5gmodem_speedtest.json. Карточка заливается зелёным слева
// (загрузка) и синим справа (отдача) по доле elapsed/secs; сверху сервис, в
// центре ↓/↑ скорости, снизу IP с пиксель-флагом (draw_cflag).
let SPEEDBIN = "/usr/share/5gmodem/speedtest.sh";
let SPEED_CACHE = "/tmp/5gmodem_speedtest.json";

// Пресеты серверов - как в настройках 5gmodem (5gsettings.js).
let SPD_DL = [
    [ "Selectel",    "https://speedtest.selectel.ru/1GB" ],
    [ "Yandex 1GB",  "http://mirror.yandex.ru/archlinux/iso/latest/archlinux-x86_64.iso" ],
    [ "Tele2",       "http://speedtest.tele2.net/1GB.zip" ],
    [ "Cloudflare",  "https://speed.cloudflare.com/__down?bytes=1000000000" ],
    [ "Hetzner",     "https://speed.hetzner.de/1GB.bin" ],
    [ "Yandex 16MB", "http://mirror.yandex.ru/debian/ls-lR.gz" ],
];
let SPD_UL = [
    [ "Rostelecom",  "https://speedtest.rt.ru/backend/empty.php" ],
    [ "Yandex",      "https://yandex.ru/internet/api/v1/upload" ],
    [ "Cloudflare",  "https://speed.cloudflare.com/__up" ],
    [ "LibreSpeed",  "https://librespeed.org/backend/empty.php" ],
];

function speedtest_read() {
    let raw = fs.readfile(SPEED_CACHE);
    if (!raw) { st.spd = st.spd ?? {}; return; }
    try { st.spd = json(raw) ?? {}; } catch (e) {}
}

function speedtest_start() {
    system(SPEEDBIN + " start >/dev/null 2>&1 &");
    st.spd = { running: 1, service: st.spd?.service ?? "" };
    st.spd_poll = true;
    st.spd_ebase = 0; st.spd_eticks = 0;   // сброс плавной доводки заливки
}

function speedtest_stop() {
    system(SPEEDBIN + " stop >/dev/null 2>&1 &");
}

function spd_num(v) { return (v == null) ? "—" : sprintf("%.1f", +v); }

// Стрелки фаз: зелёная вниз (загрузка), синяя вверх (отдача) - 9x5.
function draw_tri_down(x, y, col) { for (let i = 0; i < 5; i++) lcd_rect(x + i, y + i, 9 - 2 * i, 1, col); }
function draw_tri_up(x, y, col)   { for (let i = 0; i < 5; i++) lcd_rect(x + 4 - i, y + i, 1 + 2 * i, 1, col); }

function spd_settings_btn() { return { x: GX + st.ox, y: 152, w: GW, h: 30 }; }
function spd_card_rect()    { return { x: GX + st.ox, y: GY + st.oy, w: GW, h: 118 }; }

function draw_speedtest_page() {
    // В покое (тест не идёт) подтягиваем последний результат из кэша - чтобы
    // карточка показывала прошлый замер при любом входе на страницу.
    if (!st.spd_poll) speedtest_read();
    let sp = st.spd ?? {};
    lcd_clear(C.bg);
    draw_header(tr("Speedtest"));

    let c = spd_card_rect(), cx = c.x, cy = c.y, cw = c.w, ch = c.h;
    let running = int(+(sp.running ?? 0)) > 0;
    let up = (sp.phase == "up");
    let secs = int(+(sp.secs ?? 15)); if (secs < 1) secs = 15;
    // Плавная доводка прогресса МЕЖДУ секундными обновлениями бэкенда: база
    // (последний elapsed) + доли по тикам анимации (250мс) - заливка ползёт
    // мелкими шагами, без рывков раз в секунду.
    let disp_e = (st.spd_ebase ?? 0) + (st.spd_eticks ?? 0) * 0.25;
    if (disp_e > secs) disp_e = secs;

    // База + заливка по фазе (тон = цвет фазы при ~16% над фоном виджета).
    lcd_rect(cx, cy, cw, ch, C.widget);
    let bord = C.border;
    if (running && disp_e > 0) {
        let fw = int(cw * disp_e / secs); if (fw > cw) fw = cw;
        if (up) { lcd_rect(cx + cw - fw, cy, fw, ch, "#122E45"); bord = "#0095FF"; }
        else    { lcd_rect(cx, cy, fw, ch, "#1A3027"); bord = "#2EA043"; }
    } else if (running) {
        bord = up ? "#0095FF" : "#2EA043";
    }
    rborder(cx, cy, cw, ch, bord);
    rborder(cx + 1, cy + 1, cw - 2, ch - 2, bord);

    // Строка 1: сервис слева, фаза справа.
    let svc = sp.service ?? "";
    if (sp.error == "no-curl") svc = tr("curl not installed");
    else if (svc == "") svc = tr("Speedtest");
    lcd_text(cx + 12, cy + 8, tcut(svc, 22), C.gray, "none", 2);
    let ph = running ? (up ? tr("Upload") : tr("Download"))
                     : (int(+(sp.ok ?? 0)) ? tr("Done") : (sp.cancelled ? tr("Stopped") : ""));
    if (ph != "")
        lcd_text(cx + cw - 12 - tlen(ph) * 6, cy + 10,
                 ph, running ? (up ? "#0095FF" : "#2EA043") : C.gray, "none", 1);

    // Значения: живое число - в текущей фазе, второе - последнее известное.
    let dl, ul, dl_hot, ul_hot;
    if (running && !up)     { dl = sp.live_down; ul = sp.up_mbps; dl_hot = true; }
    else if (running && up) { dl = sp.down_mbps; ul = sp.live_up; ul_hot = true; }
    else                    { dl = sp.down_mbps; ul = sp.up_mbps; }

    let ds = spd_num(dl), us = spd_num(ul);
    draw_tri_down(cx + 14, cy + 42, "#2EA043");
    lcd_text(cx + 30, cy + 34, ds, dl_hot ? C.white : C.gray, "none", 3);
    lcd_text(cx + 30 + tlen(ds) * 18 + 6, cy + 42, tr("Mbps"), C.dim, "none", 1);

    draw_tri_up(cx + 14, cy + 70, "#0095FF");
    lcd_text(cx + 30, cy + 64, us, ul_hot ? C.white : C.gray, "none", 3);
    lcd_text(cx + 30 + tlen(us) * 18 + 6, cy + 72, tr("Mbps"), C.dim, "none", 1);

    // Строка 4: IP + пиксель-флаг страны. Флаг рисуем только когда код страны
    // уже приехал (гео-запрос отстаёт от старта) - иначе просто IP, без пустого
    // серого бокса-заглушки.
    let ip = sp.pub_ip ?? "", cc = uc(sp.cc ?? "");
    if (ip != "") {
        if (int(+(sp.ip_local ?? 0)) == 1) {
            lcd_text(cx + 12, cy + 98, tcut(ip, 24), C.dim, "none", 1);
        } else if (cc != "") {
            draw_cflag(cx + 12, cy + 97, cc);
            lcd_text(cx + 32, cy + 98, tcut(ip, 22), C.gray, "none", 1);
        } else {
            lcd_text(cx + 12, cy + 98, tcut(ip, 24), C.gray, "none", 1);
        }
    }

    // Кнопка «Выбор сервера» - в языке дизайна: виджет + акцент слева.
    let sb = spd_settings_btn();
    lcd_rect(sb.x, sb.y, sb.w, sb.h, C.widget);
    lcd_rect(sb.x, sb.y, 3, sb.h, C.cyan);
    lcd_text(sb.x + 12, sb.y + 8, tr("Choose server"), C.white, C.widget, 2);

    draw_back();
    lcd_flush();
}

// Две колонки: слева загрузка (SPD_DL), справа отдача (SPD_UL). Одинаково -
// оба списком с выбором тапом.
function spd_dl_rect(i) { return { x: GX + st.ox,       y: 44 + i * 20, w: 150, h: 18 }; }
function spd_ul_rect(i) { return { x: GX + st.ox + 154, y: 44 + i * 20, w: 150, h: 18 }; }

function spd_cfg_read() {
    let out = "";
    let g = fs.popen("echo DL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url); " +
                     "echo UL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_up_url)", "r");
    if (g) { out = g.read("all") ?? ""; g.close(); }
    let md = match(out, /DL=([^\n]*)/), mu = match(out, /UL=([^\n]*)/);
    st.spd_cfg = { dl: md ? md[1] : "", ul: mu ? mu[1] : "" };
}

function spd_cfg_set(key, val) {
    system("uci set 5gmodem.@5gmodem[0]." + key + "=" + sh_quote(val) +
           " >/dev/null 2>&1; uci commit 5gmodem >/dev/null 2>&1");
    spd_cfg_read();
}

function draw_speedtest_settings_page() {
    lcd_clear(C.bg);
    draw_header(tr("Choose server"));
    let cx = GX + st.ox;
    let cfg = st.spd_cfg ?? { dl: "", ul: "" };

    lcd_text(cx + 4, 28, tr("Download"), C.dim, C.bg, 1);
    lcd_text(cx + 158, 28, tr("Upload"), C.dim, C.bg, 1);

    for (let i = 0; i < length(SPD_DL); i++) {
        let sel = SPD_DL[i][1] == cfg.dl, r = spd_dl_rect(i);
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        lcd_rect(r.x, r.y, 3, r.h, sel ? C.green : C.dim);
        lcd_text(r.x + 10, r.y + 2, tcut(SPD_DL[i][0], 11), sel ? C.white : C.gray, C.widget, 2);
    }
    for (let i = 0; i < length(SPD_UL); i++) {
        let sel = SPD_UL[i][1] == cfg.ul, r = spd_ul_rect(i);
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        lcd_rect(r.x, r.y, 3, r.h, sel ? C.cyan : C.dim);
        lcd_text(r.x + 10, r.y + 2, tcut(SPD_UL[i][0], 11), sel ? C.white : C.gray, C.widget, 2);
    }

    draw_back();
    lcd_flush();
}

// Живой лог ядра пишем в кэш фоном (logread + awk - форк, синхронно на каждом
// тике не тянем), страница читает файл. Тот же источник, что у luci.
function vpn_log_refresh() {
    system("(" + SCRIPTS + "/vpn_clash.sh log > /tmp/.vpn_log.new 2>/dev/null" +
           " && mv /tmp/.vpn_log.new /tmp/.vpn_log) >/dev/null 2>&1 &");
}

// Разворачиваем лог в готовые к выводу строки: словоперенос по ширине экрана
// (резиновый лог, ничего не вылезает за край), цвет по уровню. Порядок
// хронологический.
function vpn_log_lines(maxchars) {
    let raw = fs.readfile("/tmp/.vpn_log");
    if (!raw || trim(raw) == "") return [];
    let out = [];
    for (let entry in split(trim(raw), "\n")) {
        if (entry == "") continue;
        let lvl = substr(entry, 0, 1);
        let msg = substr(entry, 2);
        let col = lvl == "E" ? C.red : (lvl == "W" ? C.orange : C.gray);
        let cur = "";
        for (let word in split(msg, " ")) {
            let w = word;
            while (length(w) > maxchars) {          // слово длиннее строки - рубим
                if (cur != "") { push(out, { t: cur, c: col }); cur = ""; }
                push(out, { t: substr(w, 0, maxchars), c: col });
                w = substr(w, maxchars);
            }
            let cand = cur == "" ? w : cur + " " + w;
            if (length(cand) > maxchars) { push(out, { t: cur, c: col }); cur = w; }
            else cur = cand;
        }
        if (cur != "") push(out, { t: cur, c: col });
    }
    return out;
}

// Пока служба не поднялась - вместо карточек показываем окно лога (виден
// процесс запуска/остановки). Тумблер уже нарисован выше, заголовка нет.
function draw_vpn_log() {
    let y0 = GY + 46, lh = 11, maxchars = 50;
    let maxrows = int((BACK_Y - 4 - y0) / lh);
    if (maxrows < 1) maxrows = 1;
    let lines = vpn_log_lines(maxchars);
    if (length(lines) == 0) {
        lcd_text(GX + 4, y0, tr("Waiting for log..."), C.dim, C.bg, 1);
    } else {
        let start = length(lines) > maxrows ? length(lines) - maxrows : 0;
        let ry = y0;
        for (let i = start; i < length(lines); i++) {
            lcd_text(GX + 4, ry, lines[i].t, lines[i].c, C.bg, 1);
            ry += lh;
        }
    }
    draw_back();
    lcd_flush();
}

function draw_vpn_page() {
    let v = st.vpn ?? { installed: 1, running: 0, enabled: 0, groups: [] };
    lcd_clear(C.bg);

    // Служба не установлена: не прячем плитку в меню, а объясняем прямо тут.
    if (int(+(v.installed ?? 1)) == 0) {
        draw_header("VPN");
        gcard(GX, GY, GW, 44, C.dim);
        lcd_text(GX + 12, GY + 8, "SSClash", C.gray, C.widget, 2);
        lcd_text(GX + 12, GY + 26, tr("SSClash not installed"), C.dim, C.widget, 1);
        lcd_text(GX + 4, GY + 60, tr("Install: opkg/apk add luci-app-ssclash"), C.dim, C.bg, 1);
        draw_back();
        lcd_flush();
        return;
    }

    // --- Раскрытая группа: список серверов ---
    if (st.vpn_exp != null && st.vpn_exp < length(v.groups)) {
        let g = v.groups[st.vpn_exp];
        draw_header(sprintf("VPN: %s", tcut(g.name, 22)));
        let items = vpn_items(g);
        let fixed = g.fixed ?? "";
        let n = length(items);
        let pages = int((n + VPN_MPP - 1) / VPN_MPP);
        if (pages < 1) pages = 1;
        if (st.vpn_mpg == null || st.vpn_mpg >= pages) st.vpn_mpg = 0;
        let base = st.vpn_mpg * VPN_MPP;
        for (let i = 0; i < VPN_MPP && base + i < n; i++) {
            let it = items[base + i], r = vpn_member_rect(i);
            let is_auto = (it == "__AUTO__");
            // Выбранный (зелёный): «Авто» - когда фиксации нет; узел - когда он
            // зафиксирован (авто-группа) или выбран (Selector, fixed пуст -> now).
            let sel = is_auto ? (fixed == "")
                              : (fixed != "" ? (it == fixed) : (it == g.now));
            let live = (!is_auto && it == g.now);   // реально маршрутизирует сейчас
            gcard(r.x, r.y, r.w, r.h, sel ? C.green : C.border);
            if (is_auto) {
                lcd_text(r.x + 12, r.y + int((r.h - 8) / 2), tr("Auto (URL-test)"),
                         sel ? C.white : C.gray, C.widget, 1);
            } else {
                // Значок узла + имя слева (по центру строки), кнопка-задержка
                // справа. Цвет имени: выбран - белый, живой (авто) - голубой,
                // иначе серый.
                let fl = vpn_flag(it);
                draw_node_icon(r.x + 10, r.y + int((r.h - 10) / 2), fl[0], fl[1]);
                let ncol = sel ? C.white : (live ? C.cyan : C.gray);
                lcd_text(r.x + 30, r.y + int((r.h - 8) / 2), tcut(fl[1], 33), ncol, C.widget, 1);
                draw_dbtn(r, vpn_delay(it), "m" + i);
            }
        }
        if (pages > 1) {
            let a = vpn_pg_rect(-1), z = vpn_pg_rect(1);
            gcard(a.x, a.y, a.w, a.h, C.btn); lcd_text(a.x + 62, a.y + 5, "<<", C.accent, C.widget, 2);
            gcard(z.x, z.y, z.w, z.h, C.btn); lcd_text(z.x + 62, z.y + 5, ">>", C.accent, C.widget, 2);
        }
        draw_back();
        lcd_flush();
        return;
    }

    // --- Основной экран: тумблер + карточки групп ---
    draw_header("VPN");
    let run = v.running > 0;
    let tg = vpn_tog_rect();
    gcard(tg.x, tg.y, tg.w, tg.h, run ? C.green : C.red);
    lcd_text(tg.x + 12, tg.y + 8, "SSClash", C.white, C.widget, 2);
    lcd_text(tg.x + 12, tg.y + 26, run ? tr("Running") : tr("Stopped"),
             run ? C.green : C.gray, C.widget, 1);
    let ts = run ? tr("ON") : tr("OFF");
    lcd_text(tg.x + tg.w - 12 - tlen(ts) * 12, tg.y + 12, ts, run ? C.green : C.red, C.widget, 2);

    if (!run) {
        // Служба не работает (лежит / поднимается / останавливается) - показываем
        // живой лог ядра вместо пояснений. Как поднимется - сами покажем карточки.
        draw_vpn_log();
        return;
    }
    if (length(v.groups) == 0) {
        // Служба поднялась, но группы ещё грузятся (ядро отдаёт proxies позже
        // /version) - показываем лог как «загрузку»; таймер добьёт группы и
        // покажет карточки. «Нет групп» - только если так и не появились (~30с).
        if ((st.vpn_gwait ?? 0) < 15) { draw_vpn_log(); return; }
        lcd_text(GX + 4, GY + 62, tr("No switchable groups"), C.dim, C.bg, 1);
        draw_back();
        lcd_flush();
        return;
    }

    let ng = length(v.groups);
    let gpages = int((ng + VPN_GPP - 1) / VPN_GPP);
    if (st.vpn_gpg == null || st.vpn_gpg >= gpages) st.vpn_gpg = 0;
    let gbase = st.vpn_gpg * VPN_GPP;
    for (let i = 0; i < VPN_GPP && gbase + i < ng; i++) {
        let g = v.groups[gbase + i], r = vpn_group_rect(i);
        gcard(r.x, r.y, r.w, r.h, C.cyan);
        lcd_text(r.x + 12, r.y + int((r.h - 14) / 2), tcut(g.name, 10), C.white, C.widget, 2);
        // Справа кнопка-задержка (тап = тест группы), левее - значок и имя
        // текущего узла (по центру строки). У залоченной авто-группы это сам
        // закреплённый узел (now у url-test отстаёт) оранжевым.
        let locked = vpn_auto(g) && (g.fixed ?? "") != "";
        let cur = locked ? g.fixed : g.now;
        let fl = vpn_flag(cur);
        draw_dbtn(r, vpn_delay(cur), "g" + i);
        let b = vpn_dbtn(r);
        let txt = tcut(fl[1], 11), tw = tlen(txt) * 6;
        let ex = b.x - 8 - tw;
        lcd_text(ex, r.y + int((r.h - 8) / 2), txt, locked ? C.orange : C.cyan, C.widget, 1);
        draw_node_icon(ex - 18, r.y + int((r.h - 10) / 2), fl[0], fl[1]);
    }
    if (gpages > 1) {
        let a = vpn_pg_rect(-1), z = vpn_pg_rect(1);
        gcard(a.x, a.y, a.w, a.h, C.btn); lcd_text(a.x + 62, a.y + 5, "<<", C.accent, C.widget, 2);
        gcard(z.x, z.y, z.w, z.h, C.btn); lcd_text(z.x + 62, z.y + 5, ">>", C.accent, C.widget, 2);
    }
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
        lcd_rect(b.x, b.y, 3, b.h, r.on ? C.green : C.dim);
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
    lcd_rect(nb.x, nb.y, 3, nb.h, c.on ? C.green : C.dim);
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

    lcd_text(24, 138, tr("LIGHT, %"), C.gray, C.bg, 1);
    for (let i = 0; i < length(NIGHT_BRIGHT_STEPS); i++) {
        let b = nbright_btn(i), sel = (NIGHT_BRIGHT_STEPS[i] == c.bright);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", NIGHT_BRIGHT_STEPS[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 10, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    lcd_text(24, 164, tr("WARM, %"), C.gray, C.bg, 1);
    for (let i = 0; i < length(NIGHT_WARM_STEPS); i++) {
        let b = nwarm_btn(i), sel = (NIGHT_WARM_STEPS[i] == nwarm_cfg());
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? "#F0A868" : C.border);
        let t = NIGHT_WARM_STEPS[i] == 0 ? tr("off") : sprintf("%d", NIGHT_WARM_STEPS[i]);
        lcd_text(b.x + int((b.w - tlen(t) * 6) / 2) + 2, b.y + 8, t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    for (let i = 0; i < length(NIGHT_ACTS); i++) {
        let b = nact_btn(i), on = night_act(NIGHT_ACTS[i].key);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, (c.on && on) ? C.green : C.dim);
        lcd_text(b.x + 12, b.y + 7, tr(NIGHT_ACTS[i].label),
                 c.on ? C.white : C.dim, C.widget, 1);
        lcd_text(b.x + b.w - 30, b.y + 7, on ? tr("on") : tr("off"),
                 (c.on && on) ? C.green : C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

// Информация о соте - то же наполнение, что на одноимённой странице 5gmodem.
// Полей много, поэтому три листа со стрелками, как в выборе города.
let CELL_PAGES = 3;

function cell_arrow(dir) {
    return { x: dir < 0 ? GX : GX + GCOL + GG, y: 176, w: GCOL, h: 26 };
}

// Листалки соты в стиле кнопок меню: тот же приём вдавленности - при нажатии
// фон акцентный, «стрелка» смещается на 2px вправо-вниз, снизу теневой кант.
function draw_cell_arrow(dir) {
    let a = cell_arrow(dir);
    let pressed = (cell_arrow_pressed == dir);
    let bg = pressed ? C.press : C.btn;
    let o = pressed ? 2 : 0;
    lcd_rect(a.x, a.y, a.w, a.h, bg);
    if (!pressed)
        lcd_rect(a.x, a.y + a.h - 3, a.w, 3, C.border);
    lcd_text(a.x + 62 + o, a.y + 5 + o, dir < 0 ? "<<" : ">>", C.accent, bg, 2);
}

function kv(x, y, k, v, vc) {
    lcd_text(x, y, k, C.gray, C.widget, 1);
    lcd_text(x + 74, y, (v == null || v == "" || v == "-") ? tr("no data") : v,
             vc ?? C.white, C.widget, 1);
}

// Узкий вариант kv для двухколоночной раскладки: значение ближе к подписи.
function kv2(x, y, k, v) {
    lcd_text(x, y, k, C.gray, C.widget, 1);
    lcd_text(x + 58, y, (v == null || v == "" || v == "-") ? tr("no data") : v,
             C.white, C.widget, 1);
}

function draw_cell_page() {
    let l = st.data?.lte ?? {};
    let c = l.cell ?? {};
    if (st.cpage == null || st.cpage >= CELL_PAGES) st.cpage = 0;

    lcd_clear(C.bg);
    draw_header(sprintf(tr("Cell %d/%d"), st.cpage + 1, CELL_PAGES));

    let cx = GX, cw = GW, y = GY;

    if (st.cpage == 0) {
        // Идентификаторы и радио - в две колонки, чтобы не листать длинный список.
        let rc = GX + GCOL + GG;
        gcard(cx, y, GCOL, 140, C.cyan);
        lcd_text(cx + 10, y + 6, tr("IDENTITY"), C.gray, C.widget, 1);
        kv2(cx + 10, y + 22,  "PLMN", sprintf("%d-%02d", int(+(l.mcc ?? 0)), int(+(l.mnc ?? 0))));
        kv2(cx + 10, y + 36,  "LAC",  c.lac);
        kv2(cx + 10, y + 50,  "TAC",  c.tac);
        kv2(cx + 10, y + 64,  "CID",  sprintf("%d", int(+(l.cid ?? 0))));
        kv2(cx + 10, y + 78,  "hex",  c.cid_hex);
        kv2(cx + 10, y + 92,  "eNB",  sprintf("%d", int(+(l.enbid ?? 0))));
        kv2(cx + 10, y + 106, "PCI",  sprintf("%d", int(+(l.pci ?? 0))));
        kv2(cx + 10, y + 120, "ARFCN", sprintf("%d", int(+(l.earfcn ?? 0))));

        gcard(rc, y, GCOL, 140, C.green);
        lcd_text(rc + 10, y + 6, tr("RADIO"), C.gray, C.widget, 1);
        kv2(rc + 10, y + 22,  "Band",  l.band);
        kv2(rc + 10, y + 36,  "BW",    c.bandwidth);
        kv2(rc + 10, y + 50,  "CQI",   c.cqi);
        kv2(rc + 10, y + 64,  "MIMO",  c.mimo);
        kv2(rc + 10, y + 78,  "UEcat", c.uecat);
        kv2(rc + 10, y + 92,  "VoLTE", c.volte);
        kv2(rc + 10, y + 106, "PLoss", c.pathloss);
        kv2(rc + 10, y + 120, "TXpwr", c.txpower);
    } else if (st.cpage == 1) {
        gcard(cx, y, cw, 84, C.accent);
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
        gcard(cx, y2, cw, 48, "#D2A8FF");
        lcd_text(cx + 10, y2 + 6, tr("ANTENNA PORTS"), C.gray, C.widget, 1);
        let ap = c.antports ?? "";
        let rd = c.rxdiv ?? "";
        if (rd != "" && rd != "-") {
            let rdt = sprintf("RX div: %s", rd);
            lcd_text(cx + cw - 10 - tlen(rdt) * 6, y2 + 6, rdt, C.gray, C.widget, 1);
        }
        if (ap == "" || ap == "-") {
            lcd_text(cx + 10, y2 + 22, tr("no data"), C.dim, C.widget, 1);
        } else {
            // По каждому приёмному тракту (Rx0..Rx1): RSRP числом+полоской (как в
            // соседях и в 5gmodem) и RSRQ справа. RSRQ прижат к правому краю, а
            // полоска тянется до него - справа не пустует.
            let i = 0;
            for (let part in split(ap, " ")) {
                let f = split(part, ":");
                if (length(f) < 3 || i >= 2) continue;
                let rsrp = int(+(f[1]));
                let col = LVC[MET.rsrp.lv(rsrp)];
                let yy = y2 + 21 + i * 13;
                lcd_text(cx + 10, yy, sprintf("Rx%s", f[0]), C.white, C.widget, 1);
                lcd_text(cx + 40, yy, sprintf("%d", rsrp), col, C.widget, 1);
                let rqx = cx + cw - 10 - tlen(f[2]) * 6;
                let bx = cx + 76, bw = rqx - 8 - bx;
                if (bw < 40) bw = 40;
                lcd_rect(bx, yy + 1, bw, 6, C.dim);
                let fill = bar_ease("ant" + f[0],
                                    int(bw * clampi(MET.rsrp.bar(rsrp), 0, 100) / 100));
                if (fill > 0) lcd_rect(bx, yy + 1, fill, 6, col);
                lcd_text(rqx, yy, f[2], C.gray, C.widget, 1);
                i++;
            }
        }
    } else {
        // Соседние соты столбиками: на 320x240 таблица из шести строк по пять
        // колонок нечитаема, а относительный уровень видно с одного взгляда.
        gcard(cx, y, cw, 140, C.green);

        // Своя сота отдельным блоком сверху: так не нужна пометка внутри
        // списка, а сравнивать соседей с текущей всё равно удобнее сверху вниз.
        let nb = c.neighbors;
        let own = null, others = [];
        if (type(nb) == "array")
            for (let e in nb)
                if (own == null && int(+(e?.serving ?? 0)) > 0) own = e;
                else push(others, e);

        let cell_row = function(e, yy, name_c, bkey) {
            let rsrp = int(+(e?.rsrp ?? 0));
            let col = LVC[MET.rsrp.lv(rsrp)];
            lcd_text(cx + 10, yy, sprintf("B%s", e?.band ?? "?"), name_c, C.widget, 1);
            lcd_text(cx + 40, yy, sprintf("%d", int(+(e?.pci ?? 0))), C.gray, C.widget, 1);
            lcd_text(cx + 74, yy, sprintf("%d", rsrp), col, C.widget, 1);
            let bx = cx + 110, bw = cw - 120;
            lcd_rect(bx, yy + 1, bw, 6, C.dim);
            let fill = bar_ease(bkey, int(bw * clampi(MET.rsrp.bar(rsrp), 0, 100) / 100));
            if (fill > 0) lcd_rect(bx, yy + 1, fill, 6, col);
        };

        lcd_text(cx + 10, y + 6, tr("OWN CELL"), C.gray, C.widget, 1);
        if (own) cell_row(own, y + 22, C.white, "cellown");
        else lcd_text(cx + 10, y + 22, tr("no data"), C.dim, C.widget, 1);

        lcd_text(cx + 10, y + 44, tr("NEIGHBOURS"), C.gray, C.widget, 1);
        if (length(others) == 0) {
            lcd_text(cx + 10, y + 60, tr("no data"), C.dim, C.widget, 1);
        } else {
            let rows = length(others) > 4 ? 4 : length(others);
            for (let i = 0; i < rows; i++)
                cell_row(others[i], y + 60 + i * 19, C.gray, "cellnb" + i);
        }
    }

    draw_cell_arrow(-1);
    draw_cell_arrow(1);

    draw_back();
    lcd_flush();
}

// Карточки доступности сервисов. Пробу делает svcping.sh поверх netpri.sh
// (TLS/HTTP, а не ICMP - на мобильном интернете с белыми списками пинг молчит
// даже там, где сайт открывается). Шесть хостов занимают до полуминуты,
// поэтому экран только читает готовый файл, а проверку запускает фоном.
function svc_btn(i) {
    return { x: GX + (i % 2) * (GCOL + GG), y: GY + int(i / 2) * 48, w: GCOL, h: 44 };
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
    draw_header(tr("Ping"));

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

        gcard(b.x, b.y, b.w, b.h, col);
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
    // Идёт фоновая проверка? Снимаем метку, когда svcping перепишет кэш (сменит
    // mtime) или по таймауту. Пока идёт - метку «Пинг» чуть выше, чтобы под ней
    // поместилось мелкое «Проверка...».
    let sc = st.svc_check;
    if (sc) {
        let ss = fs.stat("/tmp/lcd_services.json");
        if ((ss && ss.mtime != sc.mt) || (time() - sc.ts) >= 15) { st.svc_check = null; sc = null; }
    }
    lcd_rect(rb.x, rb.y, rb.w, rb.h, C.btn);
    lcd_rect(rb.x, rb.y + rb.h - 3, rb.w, 3, C.border);
    let lbl_y = sc ? (rb.y + 16) : (rb.y + int((rb.h - 14) / 2));
    lcd_text(rb.x + int((rb.w - tlen(lbl) * 12) / 2), lbl_y, lbl, C.white, C.btn, 2);
    if (sc) {
        let ct = tr("Checking...");
        lcd_text(rb.x + int((rb.w - tlen(ct) * 6) / 2), rb.y + 40, ct, C.cyan, C.btn, 1);
    }

    // «Назад» - в стиле стандартной полосы: красный фон + верхняя подсветка.
    lcd_rect(bb.x, bb.y, bb.w, bb.h, C.back);
    lcd_rect(bb.x, bb.y, bb.w, 2, "#D32F2F");
    lcd_text(bb.x + 20, bb.y + 20, tr("<<< BACK"), C.white, C.back, 2);

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


function wifi_onoff_rect(cy) {
    // Зона тача - постоянная (шире текста), чтобы ВКЛ/ВЫКЛ ловились одинаково.
    return { x: GX + st.ox + 176, y: cy + 40, w: 62, h: 28 };
}

function wifi_onoff_box(cy, label) {
    // Видимая рамка - впритык к тексту, прижата к правому краю зоны. Правый край
    // держим левее QR-бокса (он с GX+GW-68=244), иначе кнопка касалась кода.
    let w = tlen(label) * 12 + 10;
    let rx = GX + st.ox + 232;
    return { x: rx - w, y: cy + 43, w: w, h: 22 };
}

function wifi_cli_rect(cy) {
    return { x: GX + st.ox + 4, y: cy + 40, w: 148, h: 30 };
}

function wifi_band_match(cb, want) {
    if (want == "5G") return cb == "5G" || cb == "5GHz";
    return cb == "2G" || cb == "2.4G";
}

function wifi_band_list(band) {
    let clients = st.data?.wifi?.clients;
    let list = [];
    if (type(clients) == "array")
        for (let cl in clients)
            if (wifi_band_match(cl.band, band)) push(list, cl);
    return list;
}

function wifi_sig_col(dbm) {
    if (dbm >= -60) return C.green;
    if (dbm >= -72) return C.orange;
    return C.red;
}

function wifi_sig_bars(x, y, dbm) {
    let n = dbm >= -55 ? 4 : (dbm >= -65 ? 3 : (dbm >= -75 ? 2 : 1));
    let col = wifi_sig_col(dbm);
    for (let i = 0; i < 4; i++) {
        let bh = 3 + i * 3;
        lcd_rect(x + i * 5, y + 12 - bh, 3, bh, i < n ? col : C.dim);
    }
}

function draw_wifi_clients_page() {
    let band = st.wcli_band ?? "2G";
    lcd_clear(C.bg);
    draw_header(band == "5G" ? "5 GHz" : "2.4 GHz");
    let cx = GX + st.ox, cw = GW;
    let list = wifi_band_list(band);

    if (!length(list)) {
        lcd_text(cx + 10, 110, tr("No Clients"), C.dim, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }

    let per = 5;
    let pages = int((length(list) + per - 1) / per);
    if (pages < 1) pages = 1;
    if (st.wcli_pg == null || st.wcli_pg >= pages) st.wcli_pg = 0;

    let y = GY + st.oy;
    for (let r = 0; r < per; r++) {
        let idx = st.wcli_pg * per + r;
        if (idx >= length(list)) break;
        let cl = list[idx];
        let ry = y + r * 34;
        let dbm = int(+(cl.signal ?? 0));
        let scol = wifi_sig_col(dbm);
        lcd_rect(cx, ry, cw, 30, C.widget);
        lcd_rect(cx, ry, 3, 30, scol);
        let nm = cl.name;
        if (nm == null || nm == "" || nm == "unknown") nm = tr("device");
        lcd_text(cx + 10, ry + 3, tcut(nm, 20), C.white, C.widget, 2);
        let ip = cl.ip ?? "";
        lcd_text(cx + 10, ry + 19, ip, C.gray, C.widget, 1);
        lcd_text(cx + 12 + (tlen(ip) + 1) * 6, ry + 19, uc(cl.mac ?? ""),
                 C.dim, C.widget, 1);
        let sg = sprintf("%d dBm", dbm);
        lcd_text(cx + cw - tlen(sg) * 6 - 10, ry + 19, sg, scol, C.widget, 1);
        wifi_sig_bars(cx + cw - 30, ry + 4, dbm);
    }

    if (pages > 1) draw_back_pager(st.wcli_pg, pages);
    else draw_back();
    lcd_flush();
}

function draw_wifi_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header("WiFi");

    let ox = st.ox, oy = st.oy;
    let cx = GX + ox;
    let cw = GW;

    // Card 1: 2.4GHz WiFi (radio1)
    let y1 = GY + oy;
    let disabled_2g_state = ucur ? wifi_is_disabled("radio1", "default_radio1") : true;
    gcard(cx, y1, cw, 80, disabled_2g_state ? C.dim : C.green);
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

        let bt1 = disabled_2g ? tr("OFF") : tr("ON");
        let bb1 = wifi_onoff_box(y1, bt1);
        let bc1 = disabled_2g ? C.gray : C.green;
        rborder(bb1.x, bb1.y, bb1.w, bb1.h, bc1);
        lcd_text(bb1.x + int((bb1.w - tlen(bt1) * 12) / 2), bb1.y + 4, bt1, bc1, C.widget, 2);
        if (!disabled_2g) {
            let qb = qr_box(y1);
            draw_qr(wifi_qr_rows(ssid_2g, key_2g), qb.x + 2, qb.y + 2, 2, "#000000", "#FFFFFF");
        }
    }

    // Card 2: 5GHz WiFi (radio0)
    let y2 = y1 + 80 + GG;
    let disabled_5g_state = ucur ? wifi_is_disabled("radio0", "default_radio0") : true;
    gcard(cx, y2, cw, 80, disabled_5g_state ? C.dim : C.green);
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

        let bt2 = disabled_5g ? tr("OFF") : tr("ON");
        let bb2 = wifi_onoff_box(y2, bt2);
        let bc2 = disabled_5g ? C.gray : C.green;
        rborder(bb2.x, bb2.y, bb2.w, bb2.h, bc2);
        lcd_text(bb2.x + int((bb2.w - tlen(bt2) * 12) / 2), bb2.y + 4, bt2, bc2, C.widget, 2);
        if (!disabled_5g) {
            let qb = qr_box(y2);
            draw_qr(wifi_qr_rows(ssid_5g, key_5g), qb.x + 2, qb.y + 2, 2, "#000000", "#FFFFFF");
        }
    }

    draw_back();
    lcd_flush();
}

// Полноэкранная карточка «Инфо» (issue #2, для слабовидящих): тап по
// карточке разворачивает её крупным шрифтом, повторный тап сворачивает.
function info_zoom_rows(i) {
    let d = st.data;
    let board = board_info();
    if (i == 0) {
        let bat = d?.battery;
        let bpct = int(+(bat?.percent ?? -1));
        let load = d?.cpu_load_raw ? sprintf("%.2f", d.cpu_load_raw / 65536.0)
                 : (d?.cpu_load ?? "?");
        let busy = int(+(d?.cpu_busy ?? -1));
        let mfree = int(+(d?.mem_free_mb ?? 0));
        let mtot  = int(+(d?.mem_total_mb ?? 0));
        return [
            [ tr("SYSTEM"), board?.model ?? "?" ],
            [ tr("Uptime"), fmt_uptime(d?.uptime) ],
            [ tr("Free RAM"), mtot > 0 ? sprintf("%d / %d MB", mfree, mtot)
                                       : sprintf("%d MB", mfree) ],
            [ "CPU", busy >= 0 ? sprintf("%s, %d%%", load, busy) : load ],
            [ tr("Battery"), bpct >= 0 ? sprintf("%d%%%s", bpct,
                  bat?.charging ? " +" : "") : "--" ],
        ];
    }
    if (i == 1) {
        let so = d?.storage;
        let s_free = int(+(so?.free_kb ?? 0)), s_tot = int(+(so?.total_kb ?? 0));
        let lan = d?.lan;
        return [
            [ tr("STORAGE AND NETWORK"), "" ],
            [ tr("Flash free"), s_tot > 0
                ? sprintf("%.1f / %.1f MB", s_free / 1024.0, s_tot / 1024.0)
                : tr("no data") ],
            [ "LAN IP", lan?.ip ?? "?" ],
            [ "MAC", uc(lan?.mac ?? "?") ],
        ];
    }
    let drv = drv_version();
    return [
        [ tr("SOFTWARE"), "" ],
        [ "OpenWrt", board?.release?.version ?? "?" ],
        [ tr("Kernel"), board?.kernel ?? "?" ],
        [ tr("Driver"), drv ],
        [ "Telegram", TG_LINK ],
    ];
}

function draw_info_zoom(i) {
    lcd_clear(C.bg);
    draw_header(tr("System Info"));
    let rows = info_zoom_rows(i);
    let y = 34;
    for (let r = 0; r < length(rows); r++) {
        let lab = rows[r][0], val = rows[r][1];
        if (r == 0) {
            lcd_text(12, y, lab, C.gray, C.bg, 1);
            if (val != "") {
                y += 12;
                lcd_text(12, y, tcut(val, 25), C.white, C.bg, 2);
                y += 22;
            } else {
                y += 14;
            }
            continue;
        }
        lcd_text(12, y, lab, C.gray, C.bg, 1);
        lcd_text(12, y + 11, tcut(val, 25), C.white, C.bg, 2);
        y += 34;
    }
    draw_back();
    lcd_flush();
}

function draw_info_page() {
    if (st.izoom != null) { draw_info_zoom(st.izoom); return; }
    let d = st.data;
    lcd_clear(C.bg);
    draw_header(tr("System Info"));

    let ox = st.ox, oy = st.oy;
    let cx = GX + ox;
    let cw = GW;
    let board = board_info();

    let load = d?.cpu_load_raw ? sprintf("%.2f", d.cpu_load_raw / 65536.0)
             : (d?.cpu_load ?? "?");
    let bat = d?.battery;
    let braw = bat?.raw_hex ?? "??";
    let badc = int(+(bat?.adc ?? 0));
    let bpct = int(+(bat?.percent ?? 0));

    // Версия драйвера - дата сборки, отдаётся ioctl'ом через almond3s-lcd (кэш).
    let drv_ver = drv_version();

    // Card 1: System
    let y1 = GY + oy;
    gcard(cx, y1, cw, 52, C.cyan);
    lcd_text(cx + 10, y1 + 6, tr("SYSTEM"), C.gray, C.widget, 1);
    let hw = board?.model ?? "";
    lcd_text(cx + 10, y1 + 20, hw != "" ? hw : "?", C.white, C.widget, 1);

    // ЦП поднят наверх и прижат к правому краю - над строкой «Свободно ОЗУ».
    let busy = int(+(d?.cpu_busy ?? -1));
    let cores = int(+(d?.cpu_cores ?? 0));
    let cstr = sprintf(tr("CPU %s"), load);
    if (busy >= 0) cstr += sprintf(", %d%%", busy);
    if (cores > 0) cstr += sprintf(tr(", %d threads"), cores);
    lcd_text(cx + cw - 10 - tlen(cstr) * 6, y1 + 20, cstr, C.accent, C.widget, 1);

    // Заряд отсюда убран: он и так виден в шапке каждой страницы, а
    // подробности живут на «Батарее» - дубль на карточке только шумел.
    lcd_text(cx + 10, y1 + 34, sprintf(tr("Uptime %s"), fmt_uptime(d?.uptime)), C.white, C.widget, 1);

    // Свободную память прижимаем к правому краю карточки: строка длинная,
    // а слева уже стоит время работы.
    let mfree = int(+(d?.mem_free_mb ?? 0));
    let mtot  = int(+(d?.mem_total_mb ?? 0));
    let mstr = mtot > 0 ? sprintf(tr("free RAM %d/%dM"), mfree, mtot)
                        : sprintf(tr("free RAM %dM"), mfree);
    lcd_text(cx + cw - 10 - tlen(mstr) * 6, y1 + 34, mstr, C.green, C.widget, 1);

    // Card 2: Power
    let y2 = y1 + 52 + GG;
    gcard(cx, y2, cw, 52, C.green);
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
    let y3 = y2 + 52 + GG;
    gcard(cx, y3, cw, 52, "#D2A8FF");
    lcd_text(cx + 10, y3 + 6, tr("SOFTWARE"), C.gray, C.widget, 1);
    // Ссылка на телеграм-канал - напротив заголовка «ПРОШИВКА», справа.
    lcd_text(cx + cw - 10 - tlen(TG_LINK) * 6, y3 + 6, TG_LINK, C.dim, C.widget, 1);
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

    draw_back();
    lcd_flush();
}

let WCITY_DEFAULT = [ "Moscow", "Saint Petersburg", "Voronezh", "Novosibirsk",
                      "Yekaterinburg", "Kazan", "Nizhny Novgorod", "Samara",
                      "Rostov-on-Don", "Krasnoyarsk", "Sochi", "Khabarovsk",
                      "Vladivostok", "Ishim" ];
let WCITY_PER_PAGE = 6;   // 3 ряда пресетов; остальные города - через «Свой город»

// В wttr.in уходит латинское имя (кириллицу он понимает хуже), а на экране
// показываем русское. Незнакомый город останется как записан.

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

// Провайдер погоды: openmeteo (по умолчанию) | wttr. weather_fetch.sh читает тот
// же ключ. Переключатель - строкой на экране выбора города.
function weather_provider() {
    return (ucur ? ucur.get("almond3s", "weather", "provider") : null) ?? "openmeteo";
}
function weather_provider_name() {
    return weather_provider() == "wttr" ? "wttr.in" : "Open-Meteo";
}

// Экран выбора города: 6 пресетов (3 ряда), ниже «Свой город» и «Источник».
function wcity_btn(i) {
    return { x: 8 + (i % 2) * 156, y: 28 + int(i / 2) * 36, w: 148, h: 32 };
}
function wcity_kbd_btn()  { return { x: 8, y: 136, w: 304, h: 28 }; }
function wcity_prov_btn() { return { x: 8, y: 168, w: 304, h: 28 }; }

// Стрелки листания — только когда страниц больше одной.
function wcity_arrow(dir) {
    return { x: dir < 0 ? 8 : 164, y: 174, w: 148, h: 28 };
}

function draw_wcity_page() {
    lcd_clear(C.bg);
    draw_header(tr("City"));

    let cur = wcity_current();
    let list = wcity_list();

    // До 6 быстрых пресетов; активный — фиолетовой полоской. Остальные города
    // набираются на клавиатуре («Свой город») и ищутся геокодером.
    let n = length(list); if (n > WCITY_PER_PAGE) n = WCITY_PER_PAGE;
    for (let i = 0; i < n; i++) {
        let b = wcity_btn(i);
        let sel = (list[i] == cur);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, sel ? "#D2A8FF" : C.border);
        lcd_text(b.x + 12, b.y + 10, city_name(list[i]),
                 sel ? C.white : C.gray, C.widget, 1);
    }

    // «Свой город» — открывает клавиатуру.
    let k = wcity_kbd_btn();
    lcd_rect(k.x, k.y, k.w, k.h, C.widget);
    lcd_rect(k.x, k.y, 3, k.h, C.accent);
    lcd_text(k.x + 12, k.y + 8, tr("Custom city..."), C.accent, C.widget, 1);

    // «Источник: <провайдер>» — переключатель по тапу.
    let p = wcity_prov_btn();
    lcd_rect(p.x, p.y, p.w, p.h, C.widget);
    lcd_rect(p.x, p.y, 3, p.h, C.cyan);
    lcd_text(p.x + 12, p.y + 8, tr("Source") + ": ", C.gray, C.widget, 1);
    lcd_text(p.x + 12 + tlen(tr("Source") + ": ") * 6, p.y + 8,
             weather_provider_name() + "  ▸", C.cyan, C.widget, 1);

    draw_back();
    lcd_flush();
}

// Время последнего обновления погоды - по mtime кэша, который пишет
// Пикер выбора города при неоднозначности («две Москвы»): фоновый weather_geo.sh
// кладёт JSON совпадений в GEO_JSON, здесь их парсим и показываем списком с
// уточнением (регион, страна). НЕ зовёт go_page (no-hoisting) - выбор в тач-хэндлере.
function geopick_btn(i) { return { x: 8, y: 28 + i * 30, w: 304, h: 28 }; }

function draw_geopick_page() {
    lcd_clear(C.bg);
    draw_header(tr("Select city"));
    let raw = fs.readfile(GEO_JSON);
    if (!raw) {
        let msg = (time() - (st.geo_wait ?? 0) > 15) ? tr("City not found") : tr("Searching...");
        lcd_text(20, 100, msg, C.gray, C.bg, 2);
        draw_back(); lcd_flush(); return;
    }
    let j; try { j = json(raw); } catch (e) { j = {}; }
    let r = (type(j?.results) == "array") ? j.results : [];
    st.geo_res = r;
    if (length(r) == 0) {
        lcd_text(20, 100, tr("City not found"), C.dim, C.bg, 2);
        draw_back(); lcd_flush(); return;
    }
    let n = length(r); if (n > 6) n = 6;
    for (let i = 0; i < n; i++) {
        let b = geopick_btn(i), e = r[i];
        let sub = e.admin1 ? (e.admin1 + ", " + (e.country ?? "")) : (e.country ?? "");
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        lcd_rect(b.x, b.y, 3, b.h, C.accent);
        lcd_text(b.x + 10, b.y + 3, tcut(e.name ?? "", 24), C.white, C.widget, 1);
        lcd_text(b.x + 10, b.y + 15, tcut(sub, 48), C.gray, C.widget, 1);
    }
    draw_back(); lcd_flush();
}

// weather_fetch.sh (сам ответ API времени не несёт).
function weather_updated_str() {
    let s = fs.stat("/tmp/lcd_weather.txt");
    if (!s || !s.mtime) return "";
    let t = localtime(s.mtime);
    if (!t) return "";
    return sprintf(tr("Updated: %02d:%02d, %02d.%02d"), t.hour, t.min, t.mday, t.mon);
}

function draw_weather_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header(tr("Weather"));
    let ox = st.ox, oy = st.oy;
    let w = d?.weather;

    if (!w) {
        let c = gcard(GX + ox, GY + oy, GW, GH.m, C.yellow);
        lcd_text(c.ix, c.iy + 24, tr("No data yet"), C.dim, C.widget, 2);
        lcd_text(c.ix, c.iy + 48, tr("Tap Weather in menu to fetch"), C.dim, C.widget, 1);
        draw_back(); lcd_flush(); return;
    }

    let desc = w.desc ?? "";
    let X = GX + ox;
    // Герой: температура крупно, город под ней, иконка справа (высота 84).
    let h = gcard(X, GY + oy, GW, 84, C.yellow);
    draw_weather_icon(h.r - 82, h.y + 8, desc, 3, null);   // 72x72
    // Температура в главной карточке - крупно и целиком (как было).
    lcd_text(h.ix, h.y + 14, w.temp ?? "?", C.white, C.widget, 4);
    lcd_text(h.ix, h.y + 52, city_name(w?.city) ?? "", C.gray, C.widget, 1);
    let wupd = weather_updated_str();
    if (wupd != "") lcd_text(h.ix, h.y + 66, wupd, C.dim, C.widget, 1);

    // Условие - полосой (зазоры прежние, 8px).
    let cy = GY + oy + 84 + GG;                   // 24+92 = 116
    let cc = gcard(X, cy, GW, 32, C.cyan);
    lcd_text(cc.ix, cc.y + 9, wcond_tr(desc), C.cyan, C.widget, 2);

    // Три метрики ровным рядом, подписи целиком, текст с отступом от полоски.
    let my = cy + 32 + GG;                         // 116+40 = 156
    let mw = int((GW - 2 * GG) / 3);               // (304-16)/3 = 96
    let mets = [ [ tr("Feels"), w.feels ?? "?" ],
                 [ tr("Humidity"), w.humidity ?? "?" ],
                 [ tr("Wind"), wind_fmt(w.wind ?? "") ] ];
    for (let i = 0; i < 3; i++) {
        let mx = X + i * (mw + GG);
        let mc = gcard(mx, my, (i < 2) ? mw : (X + GW - mx), 44, C.gray);
        lcd_text(mc.ix, mc.y + 9, mets[i][0], C.gray, C.widget, 1);
        let mv = split_unit(mets[i][1]);
        lcd_text(mc.ix, mc.y + 23, mv[0], C.white, C.widget, 2);
        if (mv[1] != "")
            lcd_text(mc.ix + tlen(mv[0]) * 12 + 1, mc.y + 22, mv[1], C.gray, C.widget, 1);
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
    let X = GX + ox;
    let csq  = int(+(l.csq ?? 0));
    let rsrp = int(+(l.rsrp ?? 0));
    let temp = int(+(l.temp ?? 0));
    let nca  = int(+(l.nca ?? 0));

    let LX = X + 13, VX = X + 66;
    let REDGE = X + GW - 12;
    let rx = function(t) { return REDGE - tlen(t) * 6; };

    // Три карточки одной высоты (54) с шагом сетки, чтобы строки совпадали:
    // Модем - Сигнал - Сота. У каждой по четыре строки.
    let ay = GY + oy;
    gcard(X, ay, GW, 54, C.green);
    let model = l.modem ?? "-";
    if (tlen(model) > 15) {
        let w = split(model, " ");
        if (length(w) > 1) model = join(" ", slice(w, 1));
    }
    lcd_text(LX, ay + 6, tr("Modem"), C.gray, C.widget, 1);
    lcd_text(VX, ay + 6, tcut(model, 15), C.white, C.widget, 1);
    let mode_s = rat_label(l.mode ?? "-");
    if (nca > 1) mode_s += sprintf(" %dCA", nca);
    lcd_text(rx(mode_s), ay + 6, mode_s, C.cyan, C.widget, 1);

    lcd_text(LX, ay + 18, tr("Band"), C.gray, C.widget, 1);
    let band = l.band ?? "";
    if (band != "" && band != "-")
        lcd_text(VX, ay + 18, tcut(band, 12), C.accent, C.widget, 1);

    // Справа во второй строке: слот и температура одним блоком «SIM1 | 43°C»,
    // цвета разные - считаем ширину пары, рисуем двумя кусками.
    let slot = int(+(l.simslot ?? 0));
    let sim_part = slot > 0 ? sprintf("SIM%d | ", slot) : "";
    let ts = temp > 0
        ? sprintf("%d°C%s", temp, int(+(l.therm ?? 0)) > 0 ? " !" : "")
        : "-";
    let tc = temp >= 70 ? C.red : (temp >= 55 ? C.orange : (temp > 0 ? C.white : C.dim));
    let combo_x = REDGE - (tlen(sim_part) + tlen(ts)) * 6;
    if (sim_part != "")
        lcd_text(combo_x, ay + 18, sim_part, C.gray, C.widget, 1);
    lcd_text(combo_x + tlen(sim_part) * 6, ay + 18, ts, tc, C.widget, 1);

    let phone = phone_fmt(l.phone);
    let oper = l.operator ?? "";
    if (oper != "" && oper != "-")
        lcd_text(LX, ay + 30, tcut(oper, 16), C.white, C.widget, 1);
    if (phone != "")
        lcd_text(rx(phone), ay + 30, phone, C.white, C.widget, 1);

    // Четвёртая строка: слева подпись (при роуминге - ROAM), само качество
    // сигнала CSQ - в правый угол.
    let roam_on = int(+(l.roaming ?? 0)) > 0;
    lcd_text(LX, ay + 42, roam_on ? tr("ROAM") : tr("Signal qual"),
             roam_on ? C.orange : C.gray, C.widget, 1);
    if (csq > 0) {
        let cs = sprintf("CSQ %d/31", csq);
        lcd_text(rx(cs), ay + 42, cs, C.gray, C.widget, 1);
    }

    // Карточка 2: сигнал - четыре метрики теми же шкалами, что на дашборде.
    // Заголовка и CSQ тут больше нет - они переехали строкой выше.
    let by = ay + 62;
    gcard(X, by, GW, 54, C.cyan);
    draw_metric_row(X + 10, by + 6,  GW - 20, "rsrp", "RSRP", rsrp);
    draw_metric_row(X + 10, by + 18, GW - 20, "rsrq", "RSRQ", int(+(l.rsrq ?? 0)));
    draw_metric_row(X + 10, by + 30, GW - 20, "sinr", "SINR", int(+(l.sinr ?? 0)));
    draw_metric_row(X + 10, by + 42, GW - 20, "rssi", "RSSI", int(+(l.rssi ?? 0)));

    // Карточка 3: сота и подключение - заголовок плюс три строки.
    let cy = by + 62;
    gcard(X, cy, GW, 54, "#D2A8FF");
    lcd_text(LX, cy + 6, tr("CELL / NETWORK"), C.gray, C.widget, 1);
    // Ноль тут - это «модем не сказал», а не «нулевая сота»: SIM7100E, например,
    // PCI и EARFCN не отдаёт вовсе. Показываем прочерк, иначе выглядит как
    // настоящее значение.
    let cell_id = function(label, v) {
        let n = int(+(v ?? 0));
        return sprintf("%s %s", label, n > 0 ? sprintf("%d", n) : "-");
    };
    let enb_s = cell_id("eNB", u?.enb_id);
    lcd_text(LX, cy + 18, cell_id("PCI", u?.pci), C.white, C.widget, 1);
    lcd_text(rx(enb_s), cy + 18, enb_s, C.white, C.widget, 1);
    lcd_text(LX, cy + 30, cell_id("EARFCN", l.earfcn), C.white, C.widget, 1);

    let mcc = int(+(u?.mcc ?? 0)), mnc = int(+(u?.mnc ?? 0));
    if (mcc > 0) {
        let pop = lc(trim(l.operator ?? ""));
        let plmn_name = get_plmn_name(mcc, mnc);
        let plmn_s = sprintf("%d-%02d", mcc, mnc);
        if (plmn_name && lc(plmn_name) != pop)
            plmn_s += " " + plmn_name;
        lcd_text(rx(plmn_s), cy + 30, plmn_s, C.gray, C.widget, 1);
    }

    let conn_s = conn_fmt(l.conn_time);
    lcd_text(LX, cy + 42, l.ip ?? "-", C.green, C.widget, 1);
    lcd_text(rx(conn_s), cy + 42, conn_s, C.gray, C.widget, 1);

    draw_back();
    lcd_flush();
}

// Полноэкранный интерфейс «Трафика» (issue #2): крупные RX/TX и график
// на весь экран. Тап по карточке разворачивает, повторный сворачивает.
function draw_traffic_zoom(i) {
    lcd_clear(C.bg);
    let wwan = (i == 0);
    draw_header(wwan ? "MODEM - wwan0" : sprintf(tr("UPLINK - %s"), default_iface() ?? "none"));

    let hrx = wwan ? hist.rx : hist.wan_rx;
    let htx = wwan ? hist.tx : hist.wan_tx;
    let rx_last = length(hrx) > 0 ? hrx[length(hrx) - 1] : 0;
    let tx_last = length(htx) > 0 ? htx[length(htx) - 1] : 0;

    lcd_text(12, 34, "RX", C.green, C.bg, 2);
    lcd_text(44, 30, fmt_bytes(rx_last) + "/s", C.white, C.bg, 3);
    lcd_text(12, 66, "TX", C.red, C.bg, 2);
    lcd_text(44, 62, fmt_bytes(tx_last) + "/s", C.white, C.bg, 3);

    let rm = arr_minmax(hrx);
    let tm = arr_minmax(htx);
    let mx = rm.max > tm.max ? rm.max : tm.max;
    if (mx < 10240) mx = 10240;
    let gy = 96, gh = 100, gx = 12, gw = 296;
    draw_graph_compact(gx, gy, gw, gh, hrx, C.green, 0, mx, true);
    let n = length(htx);
    if (n >= 2) {
        let pts = n > HIST_LEN ? HIST_LEN : n;
        let start = n - pts;
        let step_x = (gw - 2) / (pts - 1);
        let prev_px = -1, prev_py = -1;
        for (let k = 0; k < pts; k++) {
            let val = htx[start + k];
            let px = gx + 1 + int(k * step_x);
            let py = gy + gh - 1 - int(log_frac(val, mx) * (gh - 2) / 1000);
            if (py < gy) py = gy;
            if (py > gy + gh - 1) py = gy + gh - 1;
            let sw = int(step_x); if (sw < 1) sw = 1;
            if (px + sw > gx + gw - 1) sw = gx + gw - 1 - px;
            if (sw < 1) sw = 1;
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

// Линия TX поверх графика RX: своя, потому что draw_graph_compact рисует
// заливку, а TX нужен контуром. gtop/gbot - границы графика внутри карточки.
function traffic_tx_line(cx, cw, y, gtop, gbot, data, mx) {
    let n = length(data);
    if (n < 2) return;
    let pts = n > HIST_LEN ? HIST_LEN : n;
    let start = n - pts;
    let step_x = ((cw - 8) - 2) / (pts - 1);
    let span = gbot - gtop;
    let prev_px = -1, prev_py = -1;
    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = cx + 5 + int(i * step_x);
        let py = y + gbot - int(log_frac(val, mx) * span / 1000);
        if (py < y + gtop) py = y + gtop;
        if (py > y + gbot) py = y + gbot;
        let sw = int(step_x); if (sw < 1) sw = 1;
        if (px + sw > cx + cw - 5) sw = cx + cw - 5 - px;
        if (sw < 1) sw = 1;
        lcd_rect(px, py, sw, 1, C.red);
        if (prev_px >= 0) {
            let dy = py - prev_py;
            let ys = dy > 0 ? prev_py : py;
            if (dy != 0) lcd_rect(px, ys, 1, (dy > 0 ? dy : -dy), C.red);
        }
        prev_px = px; prev_py = py;
    }
}

function draw_traffic_page() {
    if (st.tzoom != null) { draw_traffic_zoom(st.tzoom); return; }
    lcd_clear(C.bg);
    draw_header(tr("Traffic"));

    // Fixed coordinates here: avoid burn-in shifting artifacts
    let cx = GX;
    let cw = GW;

    // LTE / WWAN
    let rx_last = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
    let tx_last = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
    // Карточки трафика растянуты вниз до кнопки «назад» (86px), графики выше и
    // почти во всю ширину - иначе снизу и справа пустовало.
    let TGH = 86, GTOP = 34, GBOT = 79;   // высота карточки, верх/низ графика
    let y1 = GY;
    gcard(cx, y1, cw, TGH, C.cyan);
    lcd_text(cx + 10, y1 + 6, "MODEM - wwan0", C.gray, C.widget, 1);
    lcd_text(cx + 10, y1 + 20, "RX", C.green, C.widget, 1);
    lcd_text(cx + 32, y1 + 20, fmt_bytes(rx_last) + "/s", C.white, C.widget, 1);
    lcd_text(cx + 165, y1 + 20, "TX", C.red, C.widget, 1);
    lcd_text(cx + 187, y1 + 20, fmt_bytes(tx_last) + "/s", C.white, C.widget, 1);

    let rm = arr_minmax(hist.rx);
    let tm = arr_minmax(hist.tx);
    let mx1 = rm.max > tm.max ? rm.max : tm.max;
    if (mx1 < 10240) mx1 = 10240;
    draw_graph_compact(cx + 4, y1 + GTOP, cw - 8, GBOT - GTOP, hist.rx, C.green, 0, mx1, true);
    traffic_tx_line(cx, cw, y1, GTOP, GBOT, hist.tx, mx1);

    // WAN / Ethernet
    let wan_rx = length(hist.wan_rx) > 0 ? hist.wan_rx[length(hist.wan_rx) - 1] : 0;
    let wan_tx = length(hist.wan_tx) > 0 ? hist.wan_tx[length(hist.wan_tx) - 1] : 0;
    let y2 = y1 + TGH + GG;
    gcard(cx, y2, cw, TGH, C.yellow);
    lcd_text(cx + 10, y2 + 6, sprintf(tr("UPLINK - %s"), default_iface() ?? "none"), C.gray, C.widget, 1);
    lcd_text(cx + 10, y2 + 20, "RX", C.green, C.widget, 1);
    lcd_text(cx + 32, y2 + 20, fmt_bytes(wan_rx) + "/s", C.white, C.widget, 1);
    lcd_text(cx + 165, y2 + 20, "TX", C.red, C.widget, 1);
    lcd_text(cx + 187, y2 + 20, fmt_bytes(wan_tx) + "/s", C.white, C.widget, 1);

    let brm = arr_minmax(hist.wan_rx);
    let btm = arr_minmax(hist.wan_tx);
    let mx2 = brm.max > btm.max ? brm.max : btm.max;
    if (mx2 < 10240) mx2 = 10240;
    draw_graph_compact(cx + 4, y2 + GTOP, cw - 8, GBOT - GTOP, hist.wan_rx, C.green, 0, mx2, true);
    traffic_tx_line(cx, cw, y2, GTOP, GBOT, hist.wan_tx, mx2);

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
    let base = sprintf("%s|%d|%s|%d|%s", st.page, st.mpg, clock_str(),
                       int(+(d.sms_new ?? 0)), uplink_kind());
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
    case "wificlients":
        return base + sprintf("|%s|%d|%J", st.wcli_band ?? "", st.wcli_pg ?? 0,
                              d.wifi?.clients);
    case "traffic":
        return base + sprintf("|%J|%J|%J|%J", hist.rx, hist.tx, hist.wan_rx, hist.wan_tx);
    case "weather":
        return base + sprintf("|%J", d.weather);
    case "geopick": {
        let gs = fs.stat(GEO_JSON);
        return base + sprintf("|%d|%d", gs ? gs.mtime : 0, st.geo_wait ?? 0);
    }
    case "speedtest":
        return base + sprintf("|%J", st.spd);
    case "spdcfg":
        return base + sprintf("|%J", st.spd_cfg);
    case "services": {
        // mtime кэша + флаг проверки в подписи: перерисуемся, когда svcping
        // допишет результат (даже если статусы те же), и снимем «Проверка...».
        let cs = fs.stat("/tmp/lcd_services.json");
        return base + sprintf("|%J|%d|%d", d.services, cs ? cs.mtime : 0,
                              st.svc_check ? 1 : 0);
    }
    case "sms":
    case "sms1": {
        // mtime кэша читаем прямо из ФС, а не из st.sms_ts: иначе появление
        // файла после фонового recv не триггерило перерисовку (st.sms_ts
        // обновляется только внутри отрисовки - замкнутый круг, страница
        // вечно висела на «Читаю ящик...»).
        let cs = fs.stat(SMS_CACHE);
        return base + sprintf("|%d|%d|%d|%d", st.sms_pg, st.sms_i,
                              cs ? cs.mtime : 0, st.sms_nobridge ? 1 : 0);
    }
    case "netpri":
        return base + sprintf("|%J", netpri_list());
    case "battery":
        return base + sprintf("|%J|%d", st.data?.battery, anim_phase);
    case "stascan":
        return base + sprintf("|%d", sta.nets == null ? -1 : length(sta.nets));
    case "kbd":
        return base + sprintf("|%s|%s|%d", sta.pass, sta.kb.pg, sta.kb.caps ? 1 : 0);
    case "display":
    case "night":
        return base + sprintf("|%d|%s|%d|%d|%J", saver_cfg(), saver_style(),
                              bright_cfg(), burnin_cfg() ? 1 : 0, night_cfg());
    }
    return base + sprintf("|%d", st.frame);
}

function draw_current() {
    // Идёт выключение/перезагрузка - на экране заставка «Выключаю...» /
    // «Перезагружаюсь...», и перерисовывать поверх неё нельзя: reboot лишь
    // сигналит procd и возвращает управление, а тот ещё несколько секунд
    // гасит службы - без этого гварда таймеры успевали нарисовать меню
    // поверх заставки, и пользователь видел интерфейс перед ребутом.
    if (st.halting) return;

    // Пока на экране заставка, страницы не рисуем. Иначе длинная операция
    // (переключение аплинка занимает секунды) заканчивалась уже под заставкой
    // и дорисовывала страницу поверх неё - на экране получалась каша.
    if (st.screen != "active") return;

    switch (st.page) {
    case "dashboard": draw_dashboard(); break;
    case "menu":      draw_menu(); break;
    case "wifi":      draw_wifi_page(); break;
    case "wificlients": draw_wifi_clients_page(); break;
    case "info":      draw_info_page(); break;
    case "weather":   draw_weather_page(); break;
    case "wcity":     draw_wcity_page(); break;
    case "geopick":   draw_geopick_page(); break;
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
    case "settings":  draw_settings_page(); break;
    case "led":       draw_led_page(); break;
    case "battery":   draw_battery_page(); break;
    case "savercfg":  draw_savercfg_page(); break;
    case "saver":     draw_saver_page(); break;
    case "debug":     draw_debug_page(); break;
    case "iconedit":  draw_iconedit_page(); break;
    case "zigbee":    draw_zigbee_page(); break;
    case "games":     draw_games_page(); break;
    case "gset":      draw_gset_page(); break;
    case "gqr":       draw_gqr_page(); break;
    case "gkeys":     draw_gkeys_page(); break;
    case "vpn":       draw_vpn_page(); break;
    case "speedtest": draw_speedtest_page(); break;
    case "spdcfg":    draw_speedtest_settings_page(); break;
    case "alarm":     draw_alarm_page(); break;
    case "stascan":   draw_stascan_page(); break;
    case "kbd":       draw_kbd_page(); break;
    case "term":      draw_term_page(); break;
    }
}


// =============================================
//  SCREENSAVER
// =============================================

function draw_screensaver() {
    if (st.halting) return;
    if (st.saver_scene != null) return;   // сцену рисует kmod, ui.uc не вмешивается
    let t = localtime();
    // Зелёный «ночной терминал» раньше был зашит намертво; теперь это
    // настройка на странице «Ночь».
    let night = night_now() && night_act("night_green");
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
    let bchg = (bat?.charging || bat?.full) && !bat?.no_battery;
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
        // Та же сетка, что у страницы «Погода»: часы+дата сверху, ниже -
        // герой/условие/метрики карточками (чтобы страница и заставка читались
        // как одна система). Цвета - ночные (primary/secondary/accent).
        draw_status_row(3, row_o);
        let w2 = d?.weather;

        // Часы и дата - по центру экрана, сразу под статус-строкой (y3-19), так
        // что 4G+ и конвертик нового SMS не пересекаются с первой цифрой часов.
        // Прозрачный фон ("none"): под цифрами остаётся подложка-градиент, а не
        // чёрная плашка. В ночном режиме под ними всё равно ровный чёрный.
        // Часы/дата были прижаты к статус-строке, а внизу карточек - пустоты.
        // Опускаем верх (воздух берём из низа): часы 20->26, дата 50->58.
        lcd_text(int((LCD_W - tlen(ts) * 24) / 2), 26, ts, primary, "none", 4);
        if (fl.date)
            lcd_text(int((LCD_W - tlen(ds) * 12) / 2), 58, ds, secondary, "none", 2);

        if (!w2) {
            let c = gcard_pos(GX, 80, GW, 76);
            lcd_text(c.ix, c.iy + 20, tr("No data yet"), secondary, "none", 2);
            lcd_text(c.ix, c.iy + 44, tr("Open menu > Weather to fetch"), secondary, "none", 1);
            lcd_flush();
            return;
        }

        let desc = w2.desc ?? "";
        // Высоту героя держит иконка (72px), поэтому текст слева прижимаем к
        // верху, а город ставим сразу под цифрами - иначе под ними дыра.
        let h = gcard_pos(GX, 84, GW, 76);
        draw_weather_icon(h.r - 82, h.y + 2, desc, 3, night ? primary : null);
        lcd_text(h.ix, h.y + 6, w2.temp ?? "?", primary, "none", 4);
        lcd_text(h.ix, h.y + 40, city_name(w2.city) ?? "", secondary, "none", 1);

        // Условие подтянуто к герою и ужато по высоте: над и под словом было
        // поровну пусто.
        let cc = gcard_pos(GX, 162, GW, 24);
        lcd_text(cc.ix, cc.y + 5, tcut(wcond_tr(desc), 24), accent, "none", 2);

        let mw = int((GW - 2 * GG) / 3);
        let mets = [ [ tr("Feels"), w2.feels ?? "?" ],
                     [ tr("Humidity"), w2.humidity ?? "?" ],
                     [ tr("Wind"), wind_fmt(w2.wind ?? "") ] ];
        for (let i = 0; i < 3; i++) {
            let mx = GX + i * (mw + GG);
            let mc = gcard_pos(mx, 194, (i < 2) ? mw : (GX + GW - mx), 44);
            lcd_text(mc.ix, mc.y + 8, mets[i][0], secondary, "none", 1);
            let mv = split_unit(mets[i][1]);
            lcd_text(mc.ix, mc.y + 21, mv[0], primary, "none", 2);
            if (mv[1] != "")
                lcd_text(mc.ix + tlen(mv[0]) * 12 + 1, mc.y + 20, mv[1], secondary, "none", 1);
        }
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
        lcd_text(tx0 + 12, wy + 90, wcond_tr(desc), accent, bg, 2);
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
// Ночной режим как СОБЫТИЕ. Раньше night_now() просто вычислялся по часам в
// момент отрисовки, и «наступления ночи» не существовало - для Wi-Fi этого
// мало, нужен именно переход.
// Состояние задаём ЦЕЛИКОМ, а не «если включено». Раньше обе ветки стояли
// под условием самой настройки, и выключение её ночью ничего не возвращало:
// снимаешь «Wi-Fi ночью» в час ночи - точки так и остаются погашенными, а
// «Тепло» в ноль - панель остаётся тёплой до утра, которое тоже ничего не
// сделает. Теперь любой вызов приводит систему к тому виду, который положен
// прямо сейчас; обе операции идемпотентны, лишний вызов ничего не стоит.
function night_apply(on) {
    let warm = (on && nwarm_cfg() > 0) ? nwarm_cfg() : warm_cfg();
    system(sprintf("almond3s-lcd warm %d >/dev/null 2>&1", warm));

    let ap_off = on && night_act("night_wifi");
    system(sprintf("%s/night_wifi.sh %s >/dev/null 2>&1 &", SCRIPTS, ap_off ? "off" : "on"));
}

function night_tick() {
    let n = night_now();
    if (st.night_was == null) {
        // Применяем в ОБЕ стороны. Раньше при старте днём не делалось ничего -
        // и если ночь застала перезагрузка (или падение интерфейса), точки
        // доступа оставались выключенными на весь день: восстановить их было
        // некому. Скрипт при этом ничего не делает, если гасить было нечего.
        st.night_was = n;
        night_apply(n);
        return;
    }
    if (n == st.night_was) return;
    st.night_was = n;
    night_apply(n);
}

function night_dim(lvl) {
    // Ночная яркость действует везде - в меню, на страницах и на заставке.
    // Раньше она ограничивалась заставкой; ограничение снято.
    if (!night_now()) return lvl;
    // Ночная яркость задаётся так же, как дневная: процент от полной шкалы.
    // Подрезание дневным уровнем убрано - оно делало настройку относительной
    // и непредсказуемой: при дневных 10% ночные 15 молча превращались в 10.
    // Раз уж значение выбрано ночным, оно и применяется.
    // Порог снят: выбранный процент применяется как есть. Шкала ШИМ целая,
    // 0..255, поэтому 3% - это 7 отсчётов (2.75%), точнее панель не умеет.
    return int(255 * night_cfg().bright / 100);
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
    // Второй порог тоже снят - иначе он поднимал бы до 8 всё, что ночная
    // яркость честно опустила ниже. Ноль остаётся ровно одним случаем:
    // экран выключен.

    // Цифрового затемнения нет ни на одном уровне. Раньше ниже 20% ШИМ
    // упирался в пол, а остаток добирался рисованием тёмных пикселей - и
    // цвета вымывались, картинка становилась блёклой вместо тёмной.
    // Гибрид держался на том, что короткое окно света рвала передача кадра.
    // Причина была не в скважности: фаза ШИМ сбрасывалась в ноль на каждой
    // передаче, а после неё таймер просыпался с задержкой. Обе границы теперь
    // сшиты по абсолютным часам, окно света держится и на глубокой
    // скважности - значит и добирать цифрой больше нечего.
    system("almond3s-lcd gray 255 >/dev/null 2>&1");
    warm_apply();   /* уровень живёт в драйвере и сбрасывается при перезагрузке */
    system(sprintf("almond3s-lcd dim %d >/dev/null 2>&1", on ? lvl : 0));
    // Классу светодиодов оставляем согласованное состояние, чтобы очередная
    // перезагрузка триггеров не зажгла панель мимо нас.
    let p = backlight_path();
    if (p != "")
        system(sprintf("echo %d > %s", on ? 1 : 0, p));
}

// Любая правка на ночной странице применяется сразу, если время уже ночное -
// ждать следующего перехода незачем. Состояние пересобираем с нуля
// (st.night_was = null), затем пересчитываем яркость: night_dim сам решит,
// ночная она или дневная, по тому, что сейчас на экране. Пока открыта сама
// страница, экран активен - и он не темнеет, иначе настройку не было бы видно.
function night_refresh() {
    st.night_was = null;
    night_tick();
    backlight_write(true);
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

function go_page(p, is_back) {
    if (st.page == "term" && p != "term") term_stop();   // уходим - гасим шелл
    if (st.page == "alarm" && p != "alarm") alarm_save(); // сохраняем будильник
    // Стек переходов для честного «назад»: вперёд - кладём текущую страницу,
    // «назад» (is_back) - не кладём. Меню - корень: сбрасываем стек.
    if (!is_back) {
        st.nav ??= [];
        if (p == "menu") {
            st.nav = [];
        } else if (p != st.page && st.page != null) {
            if (length(st.nav) == 0 || st.nav[length(st.nav) - 1] != st.page)
                push(st.nav, st.page);
            if (length(st.nav) > 8) st.nav = slice(st.nav, length(st.nav) - 8);
        }
    }
    st.page = p;
    st.page_sig = "";   /* смена страницы - подпись заведомо другая */
    st.izoom = null;    /* полноэкранные карточки не переживают переходы */
    st.tzoom = null;
    draw_current();
}

// «Назад» по стеку переходов: снимаем родителя, а не прыгаем в меню. Пустой
// стек (зашли извне/после сброса) уводит в меню - безопасный корень.
function go_back() {
    st.nav ??= [];
    let p = length(st.nav) > 0 ? pop(st.nav) : "menu";
    go_page(p, true);
}

// Тост — неблокирующий оверлей с авто-скрытием. Раньше в конце был
// system("sleep N"), который замораживал ВЕСЬ uloop (ни тача, ни анимаций, ни
// обновления данных) на N секунд. Теперь запоминаем срок: полосу поверх кадра
// держит lcd_flush, а idle_t снимает её по истечении.
function toast(msg, color, bg_color, wait_sec) {
    color ??= C.white;
    bg_color ??= "#1082";
    wait_sec ??= 0;
    st.toast = { msg: msg, color: color, bg: bg_color,
                 until: wait_sec > 0 ? time() + wait_sec : 0 };
    lcd_flush();                          // lcd_flush дорисует полосу тоста
    if (wait_sec <= 0) st.toast = null;   // мгновенный: вызывающий перерисует
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

// Вдавленная полоса «Назад»: голубой фон, текст +2 пикселя.
// Паузы «вдавливания» урезаны 120-150 -> 50 мс: замер 16.08 показал, что
// они были главным вором отзывчивости (тап -> страница доходил до 450 мс).
// Вдавленное состояние всё равно остаётся на экране, пока рисуется и
// уезжает кадр новой страницы, - глазу хватает.
function back_press_fx(label) {
    lcd_rect(0, BACK_Y, LCD_W, 32, C.back_press);
    if (label != null)
        lcd_text(int((LCD_W - tlen(label) * 12) / 2), BACK_Y + 11, label, C.white, C.back_press, 2);
    else
        lcd_text(122, BACK_Y + 11, tr("< BACK"), C.white, C.back_press, 2);
    lcd_flush();
    sock_poll(50);
}

// Оптимистично показать новый город СРАЗУ. refresh_data каждый цикл берёт город
// из кэш-файла, поэтому пишем плейсхолдер (город + «…» вместо метрик) и туда, и в
// st.data - иначе на экране висит старый город, пока фетч в пути (баг «открылся не
// тот город»). Фетч тут же перезапишет реальными данными. city_name() локализует.
function weather_optimistic(name) {
    fs.writefile("/tmp/lcd_weather.txt",
                 sprintf("%s|%s|%s|%s|%s|%s\n", "", "…", "", "", "", name));
    if (st.data)
        st.data.weather = { desc: "", temp: "…", feels: "", humidity: "", wind: "", city: name };
}

// Применить выбранный/введённый город: пишем в uci, фоном фетчим (скрипт сам
// геокодит имя), уходим на «Погоду». Общее для пресетов и клавиатурного ввода.
// ВНИЗУ файла намеренно: зовёт go_page/toast, а ucode не хойстит - функция видит
// лишь объявленное ВЫШЕ. См. память ucode-no-hoisting.
function apply_city(name) {
    name = trim(name ?? "");
    if (name == "") return;
    if (!ucur) { toast(tr("uci unavailable"), C.red, "#200000", 2); return; }
    ucur.set("almond3s", "weather", "city", name);
    // Пресет геокодится по имени - снимаем закреплённые координаты пикера.
    ucur.delete("almond3s", "weather", "lat");
    ucur.delete("almond3s", "weather", "lon");
    ucur.delete("almond3s", "weather", "name");
    ucur.commit("almond3s");
    fs.unlink("/tmp/lcd_weather.geo");
    weather_optimistic(name);
    // Координаты/город - через env, без гонки uci-commit (см. weather_fetch.sh).
    // Пресет: WLAT/WLON пустые -> геокод по имени.
    system(sprintf("WCITY=%s WLAT= WLON= /etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1 &",
                   sh_quote(name)));
    go_page("weather");
    toast(tr("Updating..."), C.yellow, "#201406", 2);
}

// Выбранное в пикере совпадение: закрепляем координаты+имя в uci (переживает
// ребут), фетчим, уходим на «Погоду». weather_fetch.sh увидит lat/lon и не геокодит.
function apply_city_coords(name, lat, lon) {
    if (!ucur) return;
    name = trim(name ?? "");
    ucur.set("almond3s", "weather", "city", name);
    ucur.set("almond3s", "weather", "name", name);
    ucur.set("almond3s", "weather", "lat", "" + lat);
    ucur.set("almond3s", "weather", "lon", "" + lon);
    ucur.commit("almond3s");
    fs.unlink("/tmp/lcd_weather.geo");
    weather_optimistic(name);
    // Координаты/имя - через env: ucur.commit не сразу виден фону, фетч успевал
    // прочитать СТАРЫЙ город (баг «открылся Воронеж»). uci-commit выше - для ребута.
    system(sprintf("WCITY=%s WLAT=%s WLON=%s WNAME=%s /etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1 &",
                   sh_quote(name), sh_quote("" + lat), sh_quote("" + lon), sh_quote(name)));
    // Снимаем транзитные клавиатуру/пикер из стека: «назад» с погоды - к списку.
    st.nav ??= [];
    while (length(st.nav) && (st.nav[length(st.nav) - 1] == "kbd" ||
                              st.nav[length(st.nav) - 1] == "geopick"))
        pop(st.nav);
    go_page("weather", true);
    toast(tr("Updating..."), C.yellow, "#201406", 2);
}

// Ввод города с клавиатуры: пускаем фоновый геокод и уходим на страницу пикера,
// которая покажет совпадения (одно/несколько - с уточнением).
function geo_search(name) {
    name = trim(name ?? "");
    if (name == "") { go_back(); return; }
    fs.unlink(GEO_JSON);
    st.geo_wait = time();
    st.geo_res = [];
    system(SCRIPTS + "/weather_geo.sh " + sh_quote(name) + " >/dev/null 2>&1 &");
    go_page("geopick");
}

// Нажатая плитка меню: перерисовать меню с вдавленной кнопкой её же кодом.
function menu_press_fx(idx) {
    menu_pressed = idx;
    draw_menu();
    menu_pressed = null;
    sock_poll(50);
}

// Сброс модема: лестница 5gmodem (GPIO питание слота -> деавторизация USB ->
// unbind/bind драйвера). Своего скрипта не дублируем.
function menu_do_reset() {
    // Лестница сброса (питание слота -> USB -> unbind/bind) уходит в фон одним
    // скриптом (~14с) - меню остаётся живым, плитка «Модем» обновится сама, когда
    // модем поднимется. Короткий тост для отклика вместо пошаговой заглушки.
    run_script("lte_reset.sh", true);
    toast(tr("Resetting modem..."), C.yellow, "#201406", 3);
    draw_menu();
}

// Питание: модалка «Перезагрузка/Выключить/Отмена», ждём НОВОЕ нажатие.
function menu_do_power() {
    for (let d = 0; d < 5 && read_touch(); d++);
    let wx = 24, wy = 36, ww = 272;
    lcd_rect(wx, wy, ww, 168, C.back);
    let tt = tr("POWER");
    lcd_text(int((LCD_W - tlen(tt) * 18) / 2), wy + 12, tt, C.white, C.back, 3);
    let bl = [ tr("Restart"), tr("Shut down"), tr("Cancel") ];
    for (let i = 0; i < 3; i++) {
        let by = wy + 44 + i * 40;
        lcd_rect(40, by, 240, 34, C.btn);
        lcd_rect(40, by + 31, 240, 3, C.border);
        lcd_text(40 + int((240 - tlen(bl[i]) * 12) / 2), by + 9, bl[i], C.white, C.btn, 2);
    }
    lcd_flush();
    while (true) {
        let p = fs.popen("/usr/bin/almond3s-lcd waittouch 2000", "r");
        if (!p) { sock_poll(500); draw_menu(); return; }
        let line = p.read("line");
        p.close();
        let m = line ? match(trim(line), /^(\d+)\s+(\d+)/) : null;
        if (!m) continue;
        let cx = +m[1], cy = +m[2];
        for (let d = 0; d < 5 && read_touch(); d++);
        if (cx < 40 || cx > 280) continue;
        let bi = -1;
        for (let i = 0; i < 3; i++) {
            let by = wy + 44 + i * 40;
            if (cy >= by && cy < by + 34) { bi = i; break; }
        }
        if (bi == 0) {
            st.halting = true;
            action_splash(tr("Reboot"), tr("Rebooting..."), C.red);
            lcd_flush();
            run_script("reboot.sh");
            return;
        }
        if (bi == 1) {
            let pbat = st.data?.battery;
            if (pbat?.charging && !pbat?.no_battery) {
                toast(tr("Unplug charger first"), C.orange, "#201406", 2);
                draw_menu();
                return;
            }
            st.halting = true;
            action_splash(tr("Power off"), tr("Powering off..."), C.red);
            lcd_flush();
            run_script("poweroff.sh");
            return;
        }
        if (bi == 2) { draw_menu(); return; }
    }
}

function wifi_toggle_radio(radio, sec) {
    if (!ucur) return;
    let disabled = wifi_is_disabled(radio, sec);
    let new_state = disabled ? "0" : "1";
    if (new_state == "0") {
        ucur.set("wireless", radio, "disabled", "0");
        ucur.set("wireless", sec, "disabled", "0");
    } else {
        // Гасим ТОЛЬКО точку доступа, само радио оставляем: иначе падает весь
        // диапазон - нельзя ни сканировать, ни быть клиентом на нём.
        ucur.set("wireless", sec, "disabled", "1");
    }
    ucur.commit("wireless");
    // Фоново, без заглушки: uci уже сменён, поэтому кнопка сразу показывает новое
    // состояние; `wifi reload` в фоне применяет его к радио, не вешая uloop.
    system("wifi reload >/dev/null 2>&1 &");
    draw_wifi_page();
}

function handle_touch(tx, ty, tmove) {
    // Идёт выключение/перезагрузка - касания игнорируем совсем. Иначе палец,
    // ещё лежащий на стекле после выбора «Перезагрузка», давал второй
    // тач-евент, тот повторно входил сюда и, попав в координату пункта
    // «Питание», перерисовывал красный диалог поверх заставки «Перезагружаюсь».
    if (st.halting) return;
    // Кнопка скана Wi-Fi на «Сети» - раньше общих правил, иначе полоса «низ -
    // назад» съедала её нижний край.
    if (st.page == "dashboard" && fs.stat(NETPRI_SH) &&
        in_rect(tx, ty, 10, BACK_Y - 36, 300, 30)) {
        sta.band = tx < 160 ? 2 : 5;
        sta.nets = null;
        // Радио диапазона выключено - включаем его и сканируем (а не «сетей
        // нет»): кнопка скана поднимает диапазон.
        let radio = radio_for_band(sta.band);
        if (wifi_is_disabled(radio, "default_" + radio)) {
            action_splash(sta.band == 5 ? "Wi-Fi 5GHz" : "Wi-Fi 2.4GHz",
                          tr("Enabling..."), C.green);
            wifi_ensure_band_up(sta.band);
        }
        wifi_scan_start(sta.band);
        go_page("stascan");
        return;
    }

    // У сервисов внизу две кнопки, поэтому общее правило «низ - назад» для
    // этой страницы не годится: левая половина запускает проверку.
    // Порог по видимой полосе, без 6px запаса выше: 3-й ряд карточек
    // (5-6 хостов) кончается на 168, а SVC_BAR_Y-6=166 съедал их низ.
    if (st.page == "services" && ty >= SVC_BAR_Y) {
        if (tx >= svc_back_btn().x) {
            go_page("menu");
            return;
        }
        // Фоновая проверка без заглушки: svcping пишет кэш, страница обновится
        // сама, когда статусы приедут. Отклик - мелкая надпись «Проверка...» под
        // кнопкой «Пинг» (внутри неё), снимается по смене mtime кэша.
        let cs = fs.stat("/tmp/lcd_services.json");
        st.svc_check = { ts: time(), mt: cs ? cs.mtime : 0 };
        system("/etc/almond3s/scripts/svcping.sh >/dev/null 2>&1 &");
        draw_services_page();
        return;
    }

    // Строка состояния - быстрые переходы с любой страницы: конвертик ->
    // Входящие, батарейка (правый край) -> Батарея, часы (центр) ->
    // Заставка, сигнал (левый край) -> Модем. Клавиатура и редактор
    // исключены: там тап по верху - часть их собственной вёрстки, и
    // случайный уход со страницы терял бы несохранённый ввод.
    if (ty < HDR_H && st.page != "kbd" && st.page != "iconedit" && st.page != "term" && !tmove) {
        // Конвертик: зона считается ТОЙ ЖЕ формулой, что и отрисовка
        // (раньше зона жила у часов, а рисовался он за ярлыком технологии).
        if (int(st.data?.sms_new ?? 0) > 0 &&
            st.page != "sms" && st.page != "sms1") {
            let rat = tcut(rat_label(st.data?.lte?.mode ?? ""), 4);
            let t_x = int((LCD_W - tlen(clock_str()) * 12) / 2);
            let ex = 50 + (rat == "" || rat == "-" ? 0 : tlen(rat) * 12 + 8);
            if (ex + ENV_W + 8 > t_x) ex = t_x - ENV_W - 8;
            if (in_rect(tx, ty, ex - 4, 0, ENV_W + 8, HDR_H)) {
                st.sms_pg = 0;
                st.sms_i = -1;
                sms_refresh();
                go_page("sms");
                return;
            }
        }
        if (tx >= 235 && st.page != "battery") {
            go_page("battery");
            return;
        }
        if (tx >= 120 && tx < 200 && st.page != "saver") {
            // Часы -> страница настроек «Заставка».
            go_page("saver");
            return;
        }
        if (tx < 110 && st.page != "lte") {
            go_page("lte");
            return;
        }
    }

    // Список клиентов Wi-Fi: своя листалка в нижней полосе - обрабатываем до
    // общего правила «низ - назад», иначе тап по стрелкам уводил бы в меню.
    if (st.page == "wificlients" && ty >= BACK_Y) {
        let list = wifi_band_list(st.wcli_band ?? "2G");
        let per = 5;
        let pages = int((length(list) + per - 1) / per);
        if (pages < 1) pages = 1;
        let hit = pager_hit(tx, ty, st.wcli_pg ?? 0, pages);
        if (hit == 2) { back_press_fx(); go_back(); return; }
        if (hit != 0) {
            st.wcli_pg = (st.wcli_pg ?? 0) + hit;
            draw_wifi_clients_page();
            return;
        }
        return;
    }

    // Back button (all sub-pages except menu). Страницы со своей листалкой сюда
    // не попадают: у них нижняя полоса поделена на стрелки и «назад», а общее
    // правило «низ - это назад» съедало нажатия по стрелкам целиком.
    // Порог ровно по видимой полосе «Назад» (BACK_Y=208, бар 32px), без
    // прежних 10px запаса выше неё: этот запас (198..208) съедал нижние
    // пиксели кнопок всех страниц со своим нижним рядом - стрелки листания
    // «Соты»/«Города», размер часов, ШИМ, ночная яркость, 6-я строка сетей.
    if (st.page != "menu" && st.page != "sms" && st.page != "sms1" &&
        st.page != "kbd" && st.page != "term" &&
        ty >= BACK_Y) {
        // Из развёрнутой карточки «назад» ведёт к списку карточек, а не
        // сразу в меню: разворот - это подстраница.
        if (st.page == "info" && st.izoom != null) {
            back_press_fx();
            st.izoom = null;
            draw_info_page();
            return;
        }
        if (st.page == "traffic" && st.tzoom != null) {
            back_press_fx();
            st.tzoom = null;
            draw_traffic_page();
            return;
        }
        // Раскрытая группа VPN: «назад» сворачивает к списку групп, не выходит.
        if (st.page == "vpn" && st.vpn_exp != null) {
            back_press_fx();
            st.vpn_exp = null;
            draw_vpn_page();
            return;
        }
        back_press_fx();
        go_back();
        return;
    }

    // Menu button detection
    if (st.page == "sms") {
        let list = sms_list();
        let n = type(list) == "array" ? length(list) : 0;
        let pages = n > 0 ? int((n + SMS_ROWS - 1) / SMS_ROWS) : 1;
        let hit = pager_hit(tx, ty, st.sms_pg, pages);
        if (hit == 2) { back_press_fx(); go_page("menu"); return; }
        if (hit != 0) { st.sms_pg += hit; draw_sms_page(); return; }
        for (let r = 0; r < SMS_ROWS; r++) {
            let idx = st.sms_pg * SMS_ROWS + r;
            if (idx >= n) break;
            let y = 32 + r * 44;
            // Красный минус справа - удалить сообщение СРАЗУ (без попапа).
            if (in_rect(tx, ty, 310 - 34, y, 34, 40)) {
                sms_delete(list[idx]);
                // Мгновенно убираем из списка - фоновый recv потом подтвердит.
                let nl = [];
                for (let k = 0; k < length(st.sms ?? []); k++)
                    if (k != idx) push(nl, st.sms[k]);
                st.sms = nl;
                draw_sms_page();
                return;
            }
            if (in_rect(tx, ty, 10, y, 300 - 34, 40)) {
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
        if (hit == 2) { back_press_fx(); go_page("sms"); return; }
        if (hit != 0) { st.sms_tp += hit; draw_sms_one(); return; }
        return;
    }

    if (st.page == "menu") {
        let items = menu_items();
        let pages = int((length(items) + 4) / 5); if (pages < 1) pages = 1;
        for (let i = 1; i <= 6; i++) {
            let b = btn_pos(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            menu_press_fx(i);
            if (i == 6) {
                // Пейджер: левая треть - страница назад, остальное - вперёд.
                let bp = btn_pos(6), third = int(bp.w / 3);
                if (tx - bp.x < third) st.mpg = st.mpg > 1 ? st.mpg - 1 : pages;
                else st.mpg = st.mpg < pages ? st.mpg + 1 : 1;
                draw_menu();
                return;
            }
            let idx = (st.mpg - 1) * 5 + (i - 1);
            if (idx >= length(items)) { draw_menu(); return; }
            switch (items[idx].act) {
            case "dashboard": netpri_refresh(); go_page("dashboard"); return;
            case "wifi":      go_page("wifi"); return;
            case "lte":       go_page("lte"); return;
            case "vpn":       st.vpn_exp = null; st.vpn_gpg = 0; st.vpn_ping = null; st.vpn_gwait = 0; vpn_refresh(true); go_page("vpn"); return;
            case "services":  go_page("services"); return;
            case "speedtest": speedtest_read(); st.spd_poll = int(+(st.spd?.running ?? 0)) > 0; go_page("speedtest"); return;
            case "traffic":   go_page("traffic"); return;
            case "sms":       st.sms_pg = 0; st.sms_i = -1; sms_refresh(); go_page("sms"); return;
            case "led":       go_page("led"); return;
            case "settings":  go_page("settings"); return;
            case "display":   go_page("display"); return;
            case "saver":     go_page("saver"); return;
            case "weather":   run_script("weather_fetch.sh", true); go_page("weather"); return;
            case "alarm":     alarm_load(); go_page("alarm"); return;
            case "battery":   go_page("battery"); return;
            case "iconedit":  ed_armed = false; go_page("iconedit"); return;
            case "term":      term_start(); go_page("term"); return;
            case "zigbee":    go_page("zigbee"); return;
            case "games":     go_page("games"); return;
            case "info":      go_page("info"); return;
            case "reset":     menu_do_reset(); return;
            case "power":     menu_do_power(); return;
            }
            draw_menu();
            return;
        }
        return;
    }

    // WiFi page - card touch handling
    // Тап по карточке погоды -> выбор города
    if (st.page == "lte") {
        // Карточка «СИГНАЛ» - вход в подробности о соте.
        let sx = GX + st.ox, sy = GY + st.oy + 62;
        if (in_rect(tx, ty, sx, sy, GW, 54)) {
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
                lcd_rect(b.x, b.y, 3, b.h, C.yellow);
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
        let dir = in_rect(tx, ty, a.x, a.y, a.w, a.h) ? -1
                : (in_rect(tx, ty, z.x, z.y, z.w, z.h) ? 1 : 0);
        if (dir != 0) {
            cell_arrow_pressed = dir;      // показать вдавленной
            draw_cell_page();
            cell_arrow_pressed = null;
            sock_poll(50);
            st.cpage = (st.cpage + CELL_PAGES + dir) % CELL_PAGES;
            draw_cell_page();
        }
        return;
    }

    if (st.page == "vpn") {
        let v = st.vpn ?? {};
        if (int(+(v.installed ?? 1)) == 0) return;   // не установлен - тапать нечего
        let groups = type(v.groups) == "array" ? v.groups : [];

        // Раскрытая группа: выбор сервера + листалка.
        if (st.vpn_exp != null && st.vpn_exp < length(groups)) {
            let g = groups[st.vpn_exp];
            let items = vpn_items(g);
            let n = length(items);
            let pages = int((n + VPN_MPP - 1) / VPN_MPP); if (pages < 1) pages = 1;
            if (pages > 1) {
                let a = vpn_pg_rect(-1), z = vpn_pg_rect(1);
                if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) { st.vpn_mpg = ((st.vpn_mpg ?? 0) + pages - 1) % pages; draw_vpn_page(); return; }
                if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) { st.vpn_mpg = ((st.vpn_mpg ?? 0) + 1) % pages; draw_vpn_page(); return; }
            }
            let base = (st.vpn_mpg ?? 0) * VPN_MPP;
            for (let i = 0; i < VPN_MPP && base + i < n; i++) {
                let r = vpn_member_rect(i), it = items[base + i];
                let db = vpn_dbtn(r);
                // Кнопка-задержка = пинг узла: вдавливаем её и меряем, без
                // полноэкранной заглушки.
                if (it != "__AUTO__" && in_rect(tx, ty, db.x, db.y, db.w, db.h)) {
                    let prov = (st.vpn?.provider ?? {})[it];
                    let cmd = prov
                        ? (SCRIPTS + "/vpn_clash.sh ndelay " + sh_quote(prov) + " " + sh_quote(it))
                        : (SCRIPTS + "/vpn_clash.sh delay " + sh_quote(it));
                    vpn_ping_bg(cmd, "m" + i);      // фоновый замер, UI не виснет
                    return;
                }
                if (in_rect(tx, ty, r.x, r.y, r.w, r.h)) {
                    if (it == "__AUTO__") {
                        system(SCRIPTS + "/vpn_clash.sh unfix " + sh_quote(g.name) + " >/dev/null 2>&1");
                        vpn_refresh(false);
                        st.vpn_exp = null;
                        draw_vpn_page();
                        toast(tr("Auto (URL-test)"), C.green, "#08210f", 2);
                    } else {
                        let nm = vpn_flag(it)[1];
                        system(SCRIPTS + "/vpn_clash.sh select " + sh_quote(g.name) + " " + sh_quote(it) + " >/dev/null 2>&1");
                        vpn_refresh(false);
                        st.vpn_exp = null;   // назад к списку групп
                        draw_vpn_page();
                        toast(sprintf(tr("Selected: %s"), tcut(nm, 22)), C.green, "#08210f", 2);
                    }
                    return;
                }
            }
            return;
        }

        // Тумблер старт/стоп. Без полноэкранной заглушки: команду пускаем ФОНОМ
        // и сразу переключаемся в лог-режим. Ядро поднимается 15-30с - его
        // прогресс виден в логе, а как поднимется, таймер данных сам покажет
        // карточки. При остановке оптимистично гасим running - лог виден сразу.
        let tg = vpn_tog_rect();
        if (in_rect(tx, ty, tg.x, tg.y, tg.w, tg.h)) {
            let run = int(+(v.running ?? 0)) > 0;
            system(SCRIPTS + "/vpn_clash.sh " + (run ? "stop" : "start") + " >/dev/null 2>&1 &");
            if (st.vpn) st.vpn.running = 0;
            // При остановке ядро умирает не мгновенно - держим лог несколько
            // секунд, чтобы поздний опрос статуса не мигнул карточками. При
            // старте держать нельзя: надо показать карточки СРАЗУ как поднимется.
            st.vpn_loghold = run ? (time() + 8) : 0;
            st.vpn_gwait = 0;             // счётчик ожидания групп - заново
            st.vpn_exp = null;
            st.vpn_sig = null;
            fs.unlink("/tmp/.vpn_log");   // старый лог не путаем со свежим процессом
            vpn_log_refresh();
            draw_vpn_page();
            return;
        }

        // Карточки групп + листалка.
        let ng = length(groups);
        if (int(+(v.running ?? 0)) > 0 && ng > 0) {
            let gpages = int((ng + VPN_GPP - 1) / VPN_GPP); if (gpages < 1) gpages = 1;
            if (gpages > 1) {
                let a = vpn_pg_rect(-1), z = vpn_pg_rect(1);
                if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) { st.vpn_gpg = ((st.vpn_gpg ?? 0) + gpages - 1) % gpages; draw_vpn_page(); return; }
                if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) { st.vpn_gpg = ((st.vpn_gpg ?? 0) + 1) % gpages; draw_vpn_page(); return; }
            }
            let gbase = (st.vpn_gpg ?? 0) * VPN_GPP;
            for (let i = 0; i < VPN_GPP && gbase + i < ng; i++) {
                let r = vpn_group_rect(i), db = vpn_dbtn(r);
                // Кнопка-задержка = тест всей группы в фоне; иначе раскрыть.
                if (in_rect(tx, ty, db.x, db.y, db.w, db.h)) {
                    vpn_ping_bg(SCRIPTS + "/vpn_clash.sh gdelay " + sh_quote(groups[gbase + i].name),
                                "g" + i);
                    return;
                }
                if (in_rect(tx, ty, r.x, r.y, r.w, r.h)) {
                    st.vpn_exp = gbase + i; st.vpn_mpg = 0;
                    draw_vpn_page();
                    return;
                }
            }
        }
        return;
    }

    if (st.page == "speedtest") {
        let sb = spd_settings_btn();
        if (in_rect(tx, ty, sb.x, sb.y, sb.w, sb.h)) {
            spd_cfg_read();
            go_page("spdcfg");
            return;
        }
        // Тап по карточке - старт/стоп теста.
        let c = spd_card_rect();
        if (in_rect(tx, ty, c.x, c.y, c.w, c.h)) {
            if (int(+(st.spd?.running ?? 0)) > 0) speedtest_stop();
            else speedtest_start();
            draw_speedtest_page();
            return;
        }
        return;
    }

    if (st.page == "spdcfg") {
        for (let i = 0; i < length(SPD_DL); i++) {
            let r = spd_dl_rect(i);
            if (in_rect(tx, ty, r.x, r.y, r.w, r.h)) {
                spd_cfg_set("speedtest_url", SPD_DL[i][1]);
                draw_speedtest_settings_page();
                return;
            }
        }
        for (let i = 0; i < length(SPD_UL); i++) {
            let r = spd_ul_rect(i);
            if (in_rect(tx, ty, r.x, r.y, r.w, r.h)) {
                spd_cfg_set("speedtest_up_url", SPD_UL[i][1]);
                draw_speedtest_settings_page();
                return;
            }
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
            for (let i = 0; i < length(l) && i < 3; i++) {
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
                // Фоновое переключение БЕЗ заглушки на весь экран: ставим метрику
                // и тут же освежаем кэш netpri одной фоновой командой - uloop не
                // виснет. Карточку помечаем «переключаю» для мгновенной обратной
                // связи; на следующем тике netpri покажет новый приоритет и
                // карточка обновится сама (page_sig видит смену списка).
                system("( " + NETPRI_SH + " set " + sh_quote(ifn) +
                       "; " + NETPRI_SH + " list > " + NETPRI_CACHE + ".new 2>/dev/null" +
                       " && mv " + NETPRI_CACHE + ".new " + NETPRI_CACHE + " ) >/dev/null 2>&1 &");
                st.np_switch = { ifn: ifn, ts: time() };
                draw_dashboard();
                return;
            }
        }
        // Зону кнопки скана считаем так же, как в draw_dashboard, не полагаясь
        // на st.stabtn: он мог не установиться, если аплинки в тот момент ещё
        // читались.
        return;
    }

    if (st.page == "alarm") {
        if (ty >= BACK_Y) {
            alarm_save();                       // сохраняем настройки на выходе
            st.page = "menu"; st.mpg = 4; draw_menu();
            return;
        }
        let a = st.alarm, R = alarm_rects();
        let hit = function(r) { return in_rect(tx, ty, r.x, r.y, r.w, r.h); };
        if      (hit(R.hup))  a.h = (a.h + 1) % 24;
        else if (hit(R.hdn))  a.h = (a.h + 23) % 24;
        else if (hit(R.mup))  a.m = (a.m + 1) % 60;
        else if (hit(R.mdn))  a.m = (a.m + 59) % 60;
        else if (hit(R.sprev)) a.si = (a.si + length(ALARM_SOUNDS) - 1) % length(ALARM_SOUNDS);
        else if (hit(R.snext)) a.si = (a.si + 1) % length(ALARM_SOUNDS);
        else if (hit(R.sname)) { alarm_preview(); return; }   // тап по имени = играть
        else if (hit(R.mode))  a.mode = (a.mode == "daily") ? "once" : "daily";
        else if (hit(R.rep)) {
            let idx = 0;
            for (let i = 0; i < length(ALARM_REPEATS); i++)
                if (ALARM_REPEATS[i] == a.rep) idx = i;
            a.rep = ALARM_REPEATS[(idx + 1) % length(ALARM_REPEATS)];
        }
        else if (hit(R.vol))  a.vol = a.vol % 3 + 1;
        else if (hit(R.tog)) {
            a.en = !a.en;
            alarm_save();   // ВКЛ ставит cron-запись, ВЫКЛ - убирает её
            if (!a.en) system("/etc/almond3s/scripts/alarm_stop.sh >/dev/null 2>&1 &");
            draw_alarm_page();
            return;
        }
        else return;
        draw_alarm_page();
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
                sta.pass = ""; sta.kb = { pg: "abc", caps: false };
                st.kbmode = "sta";
                go_page("kbd");
            } else {
                // Открытая - подключаемся сразу, в фоне (sta_apply уже пускает
                // `network reload` фоном). Пунктирная карточка sta_pending на
                // дашборде - обратная связь; netpri обновит её как подключимся.
                sta_apply(nets[i].ssid, "", nets[i].band);
                sta_pending = { ssid: nets[i].ssid, since: time() };
                netpri_refresh();
                go_page("dashboard");
                st.nav = [];   // мастер завершён - «назад» с дашборда ведёт в меню, не в пароль
            }
            return;
        }
        return;
    }

    if (st.page == "kbd") {
        // Полоса «назад» внизу = отмена ввода, возврат к списку сетей. go_back()
        // СНИМАЕТ со стека (было go_page — оно КЛАДЁТ kbd обратно, отсюда петля
        // kbd<->stascan, из которой не выйти).
        if (ty >= BACK_Y) { if (st.kbmode == "city") st.kbmode = "sta"; go_back(); return; }
        let e = kb_key_at(tx, ty);
        if (!e) return;
        // Режим города: свой буфер/клавиатура, ↵ = применить город (геокод в фетче).
        if (st.kbmode == "city") {
            kb_press_show(e, st.citykb, 92);
            let a = kb_apply(e, st.citykb);
            if (a.t == "char") st.citybuf = (st.citybuf ?? "") + a.ch;
            else if (a.t == "del") st.citybuf = substr(st.citybuf ?? "", 0, length(st.citybuf ?? "") - 1);
            else if (a.t == "space") st.citybuf = (st.citybuf ?? "") + " ";
            else if (a.t == "enter") {
                let name = trim(st.citybuf ?? "");
                st.kbmode = "sta";
                if (name != "") geo_search(name); else go_back();
                return;
            }
            draw_kbd_page();
            return;
        }
        kb_press_show(e, sta.kb, 92);   // вдавить клавишу
        let a = kb_apply(e, sta.kb);
        if (a.t == "char") sta.pass += a.ch;
        else if (a.t == "del") sta.pass = substr(sta.pass, 0, length(sta.pass) - 1);
        else if (a.t == "space") sta.pass += " ";
        else if (a.t == "enter") {
            let n = sta.nets[sta.sel];
            // В фоне, без заглушки (sta_apply пускает `network reload` фоном).
            sta_apply(n.ssid, sta.pass, n.band);
            sta_pending = { ssid: n.ssid, since: time() };
            netpri_refresh();
            go_page("dashboard");
            st.nav = [];   // мастер завершён - «назад» с дашборда ведёт в меню, не в пароль
            return;
        }
        draw_kbd_page();
        return;
    }

    if (st.page == "term") {
        let t = st.term;
        if (ty >= BACK_Y && !tmove) {
            // Нижняя панель: слева Fn (страница стрелок), справа (>=278) клава,
            // между - выход. Fn всегда показывает клаву в режиме ext.
            if (tx < 52) {
                t.kbd = true; st.term_rows_sent = -1;
                t.kb.pg = (t.kb.pg == "ext") ? "abc" : "ext";
                draw_term_page(); return;
            }
            if (tx >= 278) { t.kbd = !t.kbd; t.scroll = 0; st.term_rows_sent = -1; draw_term_page(); return; }
            back_press_fx(tr("Exit"));
            term_stop();
            st.page = "menu"; st.mpg = 4; draw_menu();
            return;
        }
        // Область вывода (весь экран без клавы, либо над клавой при ty<92)
        // листается перетаскиванием. Тянем вниз (dy>0) - назад в историю.
        let out_area = !t.kbd || ty < 92;
        if (out_area) {
            if (!tmove) { t.drag_y = ty; return; }
            let dy = ty - (t.drag_y ?? ty);
            let ad = dy < 0 ? -dy : dy;
            if (ad >= 8) {
                t.scroll = (t.scroll ?? 0) + int(dy / 8);
                t.drag_y = ty;
                draw_term_page();
            }
            return;
        }
        let e = kb_key_at(tx, ty);
        if (tmove) {
            // Палец держат: драйвер шлёт move каждые 50мс. Уехали с клавиши -
            // отжимаем; та же клавиша - остаётся вдавленной, повторяемая -
            // автоповтор (задержка ~400мс, затем каждые ~100мс).
            if (!e || !t.hold || t.hold.x != e.x || t.hold.y != e.y) {
                t.hold = null;
                if (kb_pressed != null) { kb_pressed = null; draw_term_page(); }
                return;
            }
            if (!term_key_repeatable(e)) return;   // держим вдавленной, но не повторяем
            t.hold.n = (t.hold.n ?? 0) + 1;
            if (t.hold.n >= 8 && (t.hold.n % 2) == 0) { term_send_key(e, t); draw_term_page(); }
            return;
        }
        if (!e) {
            t.hold = null;
            if (kb_pressed != null) { kb_pressed = null; draw_term_page(); }
            return;
        }
        t.hold = { x: e.x, y: e.y, n: 0 };
        kb_pressed = e;               // вдавлена, пока палец не отпущен (снимет touch_t)
        term_send_key(e, t);          // char/seq эхом придут опросом; nav - только клава
        draw_term_page();
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

    if (st.page == "info") {
        if (st.izoom != null) { st.izoom = null; draw_info_page(); return; }
        let oy = st.oy;
        if (ty >= 28 + oy && ty < 80 + oy)  { st.izoom = 0; draw_info_page(); return; }
        if (ty >= 86 + oy && ty < 138 + oy) { st.izoom = 1; draw_info_page(); return; }
        if (ty >= 144 + oy && ty < 196 + oy){ st.izoom = 2; draw_info_page(); return; }
        return;
    }

    if (st.page == "traffic") {
        if (st.tzoom != null) { st.tzoom = null; draw_traffic_page(); return; }
        if (ty >= 28 && ty < 100)  { st.tzoom = 0; draw_traffic_page(); return; }
        if (ty >= 106 && ty < 178) { st.tzoom = 1; draw_traffic_page(); return; }
        return;
    }

    if (st.page == "debug") {
        let ib = dbg_inv_btn();
        if (in_rect(tx, ty, ib.x, ib.y, ib.w, ib.h)) {
            pancfg_set("pinv", pancfg().inv ? "0" : "1");
            panel_apply();
            draw_debug_page();
            return;
        }
        let pnb = dbg_pinit_btn();
        if (in_rect(tx, ty, pnb.x, pnb.y, pnb.w, pnb.h)) {
            let nv = pancfg().init == "kernel" ? "boot" : "kernel";
            pancfg_set("pinit", nv);
            // Ре-инит выполняет поток отрисовки с задержкой до сотни мс и
            // сбрасывает панельные регистры к дефолтам таблицы - ждём его
            // и накатываем инверсию/гамму/CABC заново.
            system(sprintf("almond3s-lcd reinit %s >/dev/null 2>&1; sleep 1", nv));
            panel_apply();
            draw_debug_page();
            return;
        }
        for (let i = 0; i < 4; i++) {
            let b = dbg_gamma_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                pancfg_set("pgamma", i + 1);
                panel_apply();
                draw_debug_page();
                return;
            }
        }
        for (let i = 0; i < 4; i++) {
            let b = dbg_cabc_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                pancfg_set("pcabc", i);
                panel_apply();
                draw_debug_page();
                return;
            }
        }
        for (let i = 0; i < length(PWM_STEPS); i++) {
            let b = dbg_pwm_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                pancfg_set("pwmhz", PWM_STEPS[i]);
                panel_apply();
                draw_debug_page();
                return;
            }
        }
        return;
    }

    if (st.page == "iconedit") {
        ed_init();
        if (ed_cpick) {
            if (tmove) return;
            for (let i = 0; i < length(ED_COLORS); i++) {
                let px = ED_X + (i % 6) * 28;
                let py = ED_Y + 14 + int(i / 6) * 30;
                if (!in_rect(tx, ty, px, py, 26, 26)) continue;
                let want = ED_COLORS[i];
                // Цвет уже в палитре - просто выбрать его слот.
                let slot = 0;
                for (let k = 0; k < 8; k++)
                    if (ED_PAL[k] == want) slot = k + 1;
                if (slot == 0) {
                    // Иначе занять слот, которым на холсте не нарисовано ни
                    // пикселя: нарисованное не перекрашивается (формат
                    // иконки держит до 8 цветов одновременно).
                    let used = [ false, false, false, false,
                                 false, false, false, false ];
                    for (let r = 0; r < ed_h; r++)
                        for (let c = 0; c < ed_w; c++)
                            if (ed_grid[r][c])
                                used[ed_grid[r][c] - 1] = true;
                    for (let k = 7; k >= 0; k--)
                        if (!used[k]) slot = k + 1;
                    if (slot == 0) {
                        toast(tr("8 colors max"), C.orange, "#201406", 1);
                        ed_cpick = false;
                        ed_armed = false;
                        draw_iconedit_page();
                        return;
                    }
                    ED_PAL[slot - 1] = want;
                }
                ed_color = slot;
                ed_cpick = false;
                ed_armed = false;
                draw_iconedit_page();
                return;
            }
            ed_cpick = false;
            ed_armed = false;
            draw_iconedit_page();
            return;
        }
        if (ed_pick) {
            if (tmove) return;
            for (let i = 0; i < length(ED_SLOTS); i++) {
                let px = ED_X + (i % 6) * 34;
                let py = ED_Y + 14 + int(i / 6) * 36;
                if (in_rect(tx, ty, px, py, 32, 32)) {
                    ed_load(ED_SLOTS[i].name);
                    ed_pick = false;
                    ed_armed = false;
                    draw_iconedit_page();
                    return;
                }
            }
            ed_pick = false;
            ed_armed = false;
            draw_iconedit_page();
            return;
        }
        if (tx >= ED_X && tx < ED_X + ed_w * ED_CELL &&
            ty >= ED_Y && ty < ED_Y + ed_h * ED_CELL) {
            // Пока палец не оторвался после открытия холста - не рисуем.
            if (!ed_armed) { ed_last = null; return; }
            let c = int((tx - ED_X) / ED_CELL);
            let r = int((ty - ED_Y) / ED_CELL);
            let changed = ed_paint(r, c);
            // Движение: доливаем клетки между прошлой и текущей точкой,
            // иначе быстрый штрих оставляет пунктир.
            if (tmove && ed_last != null) {
                let dr = r - ed_last.r, dc = c - ed_last.c;
                let steps = (dr < 0 ? -dr : dr) > (dc < 0 ? -dc : dc)
                          ? (dr < 0 ? -dr : dr) : (dc < 0 ? -dc : dc);
                for (let i = 1; i < steps; i++) {
                    if (ed_paint(ed_last.r + int(dr * i / steps),
                                 ed_last.c + int(dc * i / steps)))
                        changed = true;
                }
            }
            ed_last = { r: r, c: c };
            if (changed) {
                ed_preview();
                lcd_flush();
            }
            return;
        }
        if (tmove) return;
        ed_last = null;
        let b0 = ed_btn(0);
        if (in_rect(tx, ty, b0.x, b0.y, b0.w, b0.h)) {
            let out = "";
            for (let r = 0; r < ed_h; r++) {
                for (let c = 0; c < ed_w; c++)
                    out += ed_grid[r][c] ? sprintf("%d", ed_grid[r][c]) : ".";
                out += "\n";
            }
            out += "colors:";
            for (let i = 0; i < 8; i++)
                out += sprintf(" %d=%s", i + 1, ED_PAL[i]);
            out += "\n";
            if (ed_target != null) {
                // Правка иконки меню: переопределение на флеш и сразу в
                // работу - меню перерисует её при следующем показе.
                system("mkdir -p /etc/almond3s/icons");
                fs.writefile("/etc/almond3s/icons/" + ed_target + ".txt", out);
                let copy = [];
                for (let r = 0; r < ed_h; r++) {
                    let row = [];
                    for (let c = 0; c < ed_w; c++) push(row, ed_grid[r][c]);
                    push(copy, row);
                }
                let palc = [];
                for (let i = 0; i < 8; i++) push(palc, ED_PAL[i]);
                MICON_CUSTOM[ed_target] = { g: copy, w: ed_w, h: ed_h, pal: palc };
                ed_saved = ed_target + ".txt";
                toast(ed_saved, C.green, "#002000", 1);
                draw_iconedit_page();
                return;
            }
            // Свободный рисунок: новый нумерованный файл, ничего не затирает.
            system("mkdir -p /etc/almond3s/art");
            let n = 0;
            let names = fs.lsdir("/etc/almond3s/art") ?? [];
            for (let f in names) {
                let mm = match(f, /^art_([0-9]+)\.txt$/);
                if (mm && int(mm[1]) > n) n = int(mm[1]);
            }
            ed_saved = sprintf("art_%03d.txt", n + 1);
            fs.writefile("/etc/almond3s/art/" + ed_saved, out);
            toast(ed_saved, C.green, "#002000", 1);
            draw_iconedit_page();
            return;
        }
        let b1 = ed_btn(1);
        if (in_rect(tx, ty, b1.x, b1.y, 62, b1.h)) {
            ed_grid = null;
            ed_target = null;
            draw_iconedit_page();
            return;
        }
        if (in_rect(tx, ty, 260, b1.y, 50, 24)) {
            ed_pick = true;
            draw_iconedit_page();
            return;
        }
        if (in_rect(tx, ty, 280, 92, 34, 20)) {
            ed_cpick = true;
            draw_iconedit_page();
            return;
        }
        for (let i = 0; i < 9; i++) {
            let b = ed_pal_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                ed_color = i < 8 ? i + 1 : 0;
                draw_iconedit_page();
                return;
            }
        }
        return;
    }

    if (st.page == "night") {
        for (let i = 0; i < length(NIGHT_WARM_STEPS); i++) {
            let b = nwarm_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            night_set("night_warm_lvl", sprintf("%d", NIGHT_WARM_STEPS[i]));
            night_refresh();
            draw_night_page();
            return;
        }
        for (let i = 0; i < length(NIGHT_ACTS); i++) {
            let b = nact_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            let k = NIGHT_ACTS[i].key;
            night_act_set(k, !night_act(k));
            night_refresh();
            draw_night_page();
            return;
        }
        let c = night_cfg();
        for (let i = 0; i < length(NIGHT_BRIGHT_STEPS); i++) {
            let b = nbright_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                night_set("night_bright", NIGHT_BRIGHT_STEPS[i]);
                night_refresh();
                if (!st.blank) backlight_write(true);
                draw_night_page();
                return;
            }
        }
        let nb = night_btn();
        if (in_rect(tx, ty, nb.x, nb.y, nb.w, nb.h)) {
            night_set("night", c.on ? "0" : "1");
            night_refresh();
            draw_night_page();
            return;
        }
        for (let r = 0; r < 2; r++) {
            let key = r == 0 ? "night_from" : "night_to";
            let val = r == 0 ? c.from : c.to;
            let m = hour_btn(r, -1), pl = hour_btn(r, 1);
            if (in_rect(tx, ty, m.x, m.y, m.w, m.h)) {
                night_set(key, (val + 23) % 24);
                night_refresh();
                draw_night_page();
                return;
            }
            if (in_rect(tx, ty, pl.x, pl.y, pl.w, pl.h)) {
                night_set(key, (val + 1) % 24);
                night_refresh();
                draw_night_page();
                return;
            }
        }
        return;
    }

    if (st.page == "settings") {
        for (let i = 0; i < length(SETTINGS); i++) {
            let b = settings_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            go_page(SETTINGS[i].act);
            return;
        }
        return;
    }

    if (st.page == "display") {
        let wb = warm_btn();
        if (in_rect(tx, ty, wb.x, wb.y, wb.w, wb.h)) {
            warm_next();
            draw_display_page();
            return;
        }
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
        let mb = micons_btn();
        if (in_rect(tx, ty, mb.x, mb.y, mb.w, mb.h)) {
            MICONS_ON = !MICONS_ON;
            ucur.set("almond3s", "display", "micons", MICONS_ON ? "1" : "0");
            ucur.commit("almond3s");
            draw_display_page();
            return;
        }
        let gb = grad_btn();
        if (in_rect(tx, ty, gb.x, gb.y, gb.w, gb.h)) {
            GRAD_ON = !GRAD_ON;
            ucur.set("almond3s", "display", "gradient", GRAD_ON ? "1" : "0");
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
                saver_style_set(SAVER_STYLES[i]);
                if (saver_scene_of(SAVER_STYLES[i]) != null || SAVER_STYLES[i] == "off") {
                    // Сцена (Матрица/Лого) или «Выкл»: просто выбираем, без
                    // подменю - у выключенной заставки настраивать нечего.
                    draw_saver_page();
                } else {
                    // Обычный стиль: открываем состав элементов.
                    go_page("savercfg");
                }
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

    if (st.page == "geopick") {
        if (ty >= BACK_Y) { back_press_fx(); go_page("wcity"); return; }
        let r = st.geo_res ?? [];
        let n = length(r); if (n > 6) n = 6;
        for (let i = 0; i < n; i++) {
            let b = geopick_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                let e = r[i];
                lcd_rect(b.x, b.y, b.w, b.h, C.press);
                lcd_text(b.x + 10, b.y + 3, tcut(e.name ?? "", 24), C.white, C.press, 1);
                lcd_flush();
                apply_city_coords(e.name, e.latitude, e.longitude);
                return;
            }
        }
        return;
    }

    if (st.page == "gset") {
        for (let i = 0; i < length(GSET); i++) {
            let b = gset_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            gset_next(i);
            draw_gset_page();
            return;
        }
        let q = gqr_btn();
        if (in_rect(tx, ty, q.x, q.y, q.w, q.h)) { go_page("gqr"); return; }
        let kb = gkeys_btn();
        if (in_rect(tx, ty, kb.x, kb.y, kb.w, kb.h)) { go_page("gkeys"); return; }
        return;
    }

    if (st.page == "gkeys") {
        for (let i = 0; i < length(KEYS); i++) {
            let b = gkey_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            gkey_learn(i);
            return;
        }
        return;
    }

    if (st.page == "gqr")
        return;

    if (st.page == "games") {
        let roms = rom_list();
        let cb = games_cfg_btn();
        if (in_rect(tx, ty, cb.x, cb.y, cb.w, cb.h)) { go_page("gset"); return; }
        let pages = length(roms) > 4 ? int((length(roms) + 3) / 4) : 1;
        let base = (st.gpg ?? 0) * 4;
        if (pages > 1) {
            let a = games_arrow(-1), z = games_arrow(1);
            if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) {
                st.gpg = (st.gpg + pages - 1) % pages; draw_games_page(); return;
            }
            if (in_rect(tx, ty, z.x, z.y, z.w, z.h)) {
                st.gpg = (st.gpg + 1) % pages; draw_games_page(); return;
            }
        }
        for (let i = 0; i < 4 && base + i < length(roms); i++) {
            let r = games_btn(i);
            if (!in_rect(tx, ty, r.x, r.y, r.w, r.h)) continue;
            if (!fs.stat(NES_BIN)) {
                toast(tr("emulator not installed"), C.red, "#200000", 3);
                return;
            }
            lcd_rect(r.x, r.y, r.w, r.h, C.press);
            lcd_text(r.x + 12, r.y + 9, tcut(roms[base + i].name, 46), C.white, C.press, 1);
            lcd_flush();
            // setsid: скрипт гасит нашу же службу, и без отвязки умрёт вместе с нами.
            system(sprintf("setsid %s/nes_run.sh %s >/dev/null 2>&1 &",
                           SCRIPTS, sh_quote(roms[base + i].path)));
            return;
        }
        return;
    }

    if (st.page == "wcity") {
        let list = wcity_list();
        let n = length(list); if (n > WCITY_PER_PAGE) n = WCITY_PER_PAGE;
        for (let i = 0; i < n; i++) {
            let b = wcity_btn(i);
            if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                lcd_rect(b.x, b.y, b.w, b.h, C.press);
                let ct = city_name(list[i]);
                lcd_text(b.x + int((b.w - tlen(ct) * 6) / 2) + 2, b.y + 10 + 2,
                         ct, C.white, C.press, 1);
                lcd_flush();
                apply_city(list[i]);
                return;
            }
        }
        // «Свой город» — клавиатура в режиме города.
        let k = wcity_kbd_btn();
        if (in_rect(tx, ty, k.x, k.y, k.w, k.h)) {
            st.kbmode = "city";
            st.citybuf = "";
            st.citykb = { pg: "abc", caps: false };
            go_page("kbd");
            return;
        }
        // «Источник» — переключить провайдера, перефетчить в фоне.
        let p = wcity_prov_btn();
        if (in_rect(tx, ty, p.x, p.y, p.w, p.h)) {
            if (!ucur) { toast(tr("uci unavailable"), C.red, "#200000", 2); return; }
            ucur.set("almond3s", "weather", "provider",
                     weather_provider() == "wttr" ? "openmeteo" : "wttr");
            ucur.commit("almond3s");
            system("/etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1 &");
            draw_wcity_page();
            toast(tr("Source") + ": " + weather_provider_name(), C.cyan, "#06202a", 2);
            return;
        }
        return;
    }

    if (st.page == "wifi") {
        let ox = st.ox, oy = st.oy;
        let cx = GX + ox;
        let cw = GW;

        // Card 1: 2.4GHz (radio1)
        let y1 = GY + oy;
        let q1 = qr_box(y1);
        if (in_rect(tx, ty, q1.x, q1.y, q1.w, q1.h)
            && ucur && !wifi_is_disabled("radio1", "default_radio1")) {
            st.qr_sec = "default_radio1"; st.qr_band = "2.4 GHz";
            go_page("qr");
            return;
        }
        // Кнопка ВКЛ/ВЫКЛ - радио переключаем ТОЛЬКО по её области.
        let br1 = wifi_onoff_rect(y1);
        if (in_rect(tx, ty, br1.x, br1.y, br1.w, br1.h)) {
            wifi_toggle_radio("radio1", "default_radio1");
            return;
        }
        // Тап по числу клиентов - список подключённых устройств диапазона.
        let cr1 = wifi_cli_rect(y1);
        if (in_rect(tx, ty, cr1.x, cr1.y, cr1.w, cr1.h)
            && length(wifi_band_list("2G")) > 0) {
            st.wcli_band = "2G"; st.wcli_pg = 0;
            go_page("wificlients");
            return;
        }

        // Card 2: 5GHz (radio0)
        let y2 = y1 + 80 + GG;
        let q2 = qr_box(y2);
        if (in_rect(tx, ty, q2.x, q2.y, q2.w, q2.h)
            && ucur && !wifi_is_disabled("radio0", "default_radio0")) {
            st.qr_sec = "default_radio0"; st.qr_band = "5 GHz";
            go_page("qr");
            return;
        }
        let br2 = wifi_onoff_rect(y2);
        if (in_rect(tx, ty, br2.x, br2.y, br2.w, br2.h)) {
            wifi_toggle_radio("radio0", "default_radio0");
            return;
        }
        let cr2 = wifi_cli_rect(y2);
        if (in_rect(tx, ty, cr2.x, cr2.y, cr2.w, cr2.h)
            && length(wifi_band_list("5G")) > 0) {
            st.wcli_band = "5G"; st.wcli_pg = 0;
            go_page("wificlients");
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
        if (st.saver_scene != null) {
            // Останавливаем kmod-сцену, возвращаем экран интерфейсу.
            system("almond3s-lcd scene stop >/dev/null 2>&1");
            st.saver_scene = null;
        }
        set_blank(false);
        backlight_write(true);   /* вернуть полный уровень после ночной заставки */
        // Просыпаемся на ту же страницу, с которой ушли в заставку:
        // человек продолжает с места, где остановился.
        refresh_data();
        st.page_sig = "";
        draw_current();
    } else if (s == "screensaver") {
        st.saver_frame = 0;
        let sc = saver_scene_of();
        if (saver_style() == "off") {
            set_blank(true);
        } else if (sc != null) {
            // Сцена-заставка: анимирует kmod. ui.uc НЕ рисует кадры (иначе его
            // flush сбросит splash_active и убьёт сцену) - гвард в
            // draw_screensaver и в таймерах перерисовки по st.saver_scene.
            backlight_write(true);
            st.saver_scene = sc;
            system(sprintf("almond3s-lcd scene %d >/dev/null 2>&1", sc));
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
    st.nav = [];              // прыжок извне - корень: «назад» отсюда ведёт в меню
    st.izoom = null;          // не тащим развёрнутую карточку/зум в новую страницу
    st.tzoom = null;
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

    // Настройки панели живут в параметрах модуля и после перезагрузки
    // сбросились бы: восстанавливаем выбранное.
    gset_apply_all();

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

    // Настройки панели из uci - раньше комментарий у страницы «Дебаг»
    // обещал «накатываются при старте», но вызова здесь не было, и после
    // перезапуска службы инверсия/гамма/CABC/ШИМ молча слетали в дефолт.
    if (pancfg().init == "kernel")
        system("almond3s-lcd reinit kernel >/dev/null 2>&1; sleep 1");
    panel_apply();

    // Stop splash: ioctl(0) via flush
    system("printf '\\0' > /dev/lcd 2>/dev/null");

    // Initial data + draw. Стартуем на «Модем» - там же, куда попадаем из
    // заставки: иначе после каждого перезапуска демона экран молча уезжал
    // на «Сеть», и выглядело это как «страница сама перескакивает».
    refresh_data();
    st.alarm_on = alarm_is_on();   // статус-иконка будильника с первого кадра
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
            if (bar_moving && st.screen == "active" &&
                (st.page == "lte" || st.page == "cell")) {
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
            // Терминал: подтягиваем сетку демона и держим размер окна в согласии
            // с состоянием клавиатуры (fifo появляется не мгновенно - шлём, как
            // только готов).
            if (st.screen == "active" && st.page == "term") {
                let g = term_grid();
                if (g != st.tgrid) { st.tgrid = g; draw_term_page(); }
                let want = term_rows();
                if (st.term_rows_sent != want && term_resize())
                    st.term_rows_sent = want;
                // Шелл жив? Печать `exit`/Ctrl+D завершает его - тогда закрываем
                // терминал в меню (как кнопка «Выход»). was_alive отсекает гонку
                // старта, когда демон ещё не поднялся.
                if (term_alive()) st.term_was_alive = true;
                else if (st.term_was_alive) {
                    st.term_was_alive = false;
                    term_stop();
                    st.page = "menu"; st.mpg = 4; draw_menu();
                }
            }
            bar_t.set(90);
        });

        let anim_t, anim_tick = 0;
        anim_t = uloop_mod.timer(700, function() {
            // Спидтест: живой опрос кэша + перерисовка карточки (заливка/цифры)
            // пока тест идёт. Кэш пишет бэкенд ~раз в секунду; тик 250мс + счётчик
            // подтиков (spd_eticks) дают плавную заливку между обновлениями.
            if (st.page == "speedtest" && st.spd_poll) {
                speedtest_read();
                let ne = int(+(st.spd?.elapsed ?? 0));
                if (ne != (st.spd_ebase ?? -1)) { st.spd_ebase = ne; st.spd_eticks = 0; }
                else st.spd_eticks = (st.spd_eticks ?? 0) + 1;
                if (int(+(st.spd?.running ?? 0)) == 0) st.spd_poll = false;
                if (st.screen == "active") draw_speedtest_page();
            }
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
            // Пока идёт тест скорости - тикаем чаще (плавная заливка).
            anim_t.set((st.page == "speedtest" && st.spd_poll) ? 250 : 700);
        });

        // Data refresh + redraw (every 2s)
        let data_t;
        data_t = uloop_mod.timer(T.data * 1000, function() {
            refresh_data();
            st.alarm_on = alarm_is_on();   // статус-иконка будильника
            night_tick();
            st.vpn_tick = (st.vpn_tick ?? 99) + 1;
            if (st.vpn_tick >= 5) {          // ~раз в 10 с, чаще незачем
                st.vpn_tick = 0;
                st.vpn_on = clash_running();
            }
            // Матрица-заставка: снизу живой logread (kmsg после буста молчит).
            // Срезаем дату+facility, режем по ширине, фоном чтоб не блокировать.
            if (st.saver_scene == 0)
                system("almond3s-lcd matrixline \"$(logread 2>/dev/null | tail -1 | " +
                       "sed -E 's/^.* [0-9]{4} [a-z0-9.]+ //' | cut -c1-52)\" >/dev/null 2>&1 &");
            // На открытой «Сети» список аплинков освежаем раз в три тика:
            // подключение STA или смена метрик иначе не видны, пока не выйдешь
            // и не зайдёшь через меню.
            if (st.screen == "active") {
                st.np_tick = (st.np_tick ?? 0) + 1;
                // На «Сети» освежаем часто (виден список), иначе реже - только
                // чтобы значок аплинка в статус-строке был свежим на всех страницах.
                let every = (st.page == "dashboard") ? 3 : 8;
                if (st.np_tick % every == 0) netpri_refresh();
            }
            // Результат скана Wi-Fi: подхватываем, как только готов.
            if (st.page == "stascan" && sta.nets == null) {
                let r = wifi_scan_read();
                if (r != null) sta.nets = r;
            }
            // Фоновый пинг VPN завершился (есть done-файл) или завис (8с) -
            // подтягиваем свежие задержки и дорисовываем цифру.
            if (st.page == "vpn" && st.vpn_ping) {
                if (fs.stat("/tmp/.vpn_ping_done") || (time() - st.vpn_ping.ts) > 8) {
                    fs.unlink("/tmp/.vpn_ping_done");
                    st.vpn_ping = null;
                    vpn_refresh(true);
                    if (st.screen == "active") draw_vpn_page();
                }
            }
            // На «логовой» фазе VPN (служба не поднялась) держим живой опрос:
            // тянем свежий лог и статус. vpn_refresh(false) при running уже
            // отдаёт группы - показываем карточки СРАЗУ (без синхронного тянуть
            // /providers на 8с, иначе флип «лог->карточки» вешал UI); задержки
            // подтянутся по пингу или при возврате в меню.
            else if (st.page == "vpn" && int(+(st.vpn?.installed ?? 1)) != 0) {
                // Держим опрос, пока служба не поднялась ЛИБО поднялась, но
                // группы ещё не подгрузились (баг «Нет групп» сразу после
                // старта: /version отвечает раньше, чем ядро отдаёт proxies).
                // Флип на карточки - только когда группы реально есть; иначе
                // остаёмся в логе. Сдаёмся, если групп нет за ~30с (vpn_gwait).
                let run0 = int(+(st.vpn?.running ?? 0)) > 0;
                let ng0 = length(st.vpn?.groups ?? []);
                if (!run0 || (ng0 == 0 && (st.vpn_gwait ?? 0) < 15)) {
                    vpn_log_refresh();
                    vpn_refresh(false);
                    if (st.vpn_loghold && time() < st.vpn_loghold && st.vpn)
                        st.vpn.running = 0;
                    let nowrun = int(+(st.vpn?.running ?? 0)) > 0;
                    let nowg = length(st.vpn?.groups ?? []);
                    st.vpn_gwait = (nowrun && nowg == 0) ? (st.vpn_gwait ?? 0) + 1 : 0;
                    let sig = (nowrun && nowg > 0) ? "run"
                            : nowrun ? ("wait|" + (st.vpn_gwait ?? 0))
                            : ("log|" + (fs.readfile("/tmp/.vpn_log") ?? ""));
                    if (st.screen == "active" && sig != st.vpn_sig) {
                        st.vpn_sig = sig;
                        draw_vpn_page();
                    }
                }
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
        let touch_t, term_null = 0;
        touch_t = uloop_mod.timer(100, function() {
            screen_req();
            goto_req();
            let t = read_touch();
            if (t) {
                term_null = 0;
                st.ltch = time();
                if (st.screen != "active")
                    set_screen("active");
                else if (!t.move || st.page == "iconedit" || st.page == "term") {
                    // Тачскрин резистивный и дребезжит: одно нажатие нередко
                    // приходит дважды подряд, и страницы листались через одну
                    // по всему интерфейсу. Гасим повтор, если он пришёл в
                    // пределах 250мс и почти в ту же точку. Рисование в
                    // редакторе и терминал не трогаем - там важен каждый тик.
                    let drop = false;
                    if (!t.move && st.page != "iconedit" && st.page != "term") {
                        let c = clock(true);
                        let ms = c[0] * 1000 + int(c[1] / 1000000);
                        let dx = t.x - (st.tap_x ?? -999); if (dx < 0) dx = -dx;
                        let dy = t.y - (st.tap_y ?? -999); if (dy < 0) dy = -dy;
                        if (st.tap_t != null && (ms - st.tap_t) < 250 &&
                            dx < 24 && dy < 24)
                            drop = true;
                        st.tap_t = ms; st.tap_x = t.x; st.tap_y = t.y;
                    }
                    if (!drop) handle_touch(t.x, t.y, t.move ?? false);
                }
            } else {
                // Палец оторван - взводим редактор (теперь холст можно рисовать).
                if (st.page == "iconedit") ed_armed = true;
                if (st.page == "term" && kb_pressed != null) {
                    // Пока держат, драйвер шлёт move каждые 50мс. Пара пустых
                    // опросов подряд - отжимаем клавишу. Один пропуск не считаем:
                    // опрос и запись драйвера могут разойтись по фазе.
                    if (++term_null >= 2) {
                        term_null = 0;
                        kb_pressed = null;
                        st.term.hold = null;
                        draw_term_page();
                    }
                }
            }
            // На редакторе опрашиваем чаще: непрерывное рисование. Базовый
            // опрос 60мс (было 100): тап реагирует заметно живее, а лишние
            // 6 опросов/с - это лишь пара чтений пустых файлов, шум по CPU.
            touch_t.set(st.screen == "off" ? 500
                        : (st.page == "iconedit" ? 40 : (st.page == "term" ? 50 : 60)));
        });

        // Idle check (every 1s)
        let idle_t;
        idle_t = uloop_mod.timer(1000, function() {
            // Истёк тост - снимаем и перерисовываем страницу (стираем полосу).
            if (st.toast && st.toast.until && time() >= st.toast.until) {
                st.toast = null;
                if (st.screen == "active") draw_current();
            }
            let idle = time() - st.ltch;
            if (st.screen == "active" && idle >= saver_timeout()
                && !screen_keep_awake())
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
            if (st.screen == "active" && idle >= saver_timeout()
                && !screen_keep_awake())
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
