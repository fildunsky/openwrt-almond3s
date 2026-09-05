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
let BOARD_NAME = fs.readfile("/tmp/sysinfo/board_name") ?? "";
let IS_ALMONDPLUS = index(BOARD_NAME, "almondplus") >= 0;
let IS_ALMOND3 = fs.access("/sys/class/leds/red:status") ||
                 (index(BOARD_NAME, "almond-3") >= 0 && index(BOARD_NAME, "almond-3s") < 0);
let LCD_W = IS_ALMONDPLUS ? 480 : 320, LCD_H = IS_ALMONDPLUS ? 320 : 240;
let HAS_BATTERY = !IS_ALMONDPLUS && !IS_ALMOND3;
let HAS_LED = !IS_ALMONDPLUS;      // над экраном Almond+ индикатора нет
let HAS_SOUND = !IS_ALMONDPLUS;    // нет зуммера/звука - будильник бессмыслен
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
    green:   "#10B981", // изумруд - единый «хорошо»: заряд, уровень, «включено»
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
    cloud_hi:   "#C2CBD6", // cloud, top rim highlight
    cloud_lit:  "#9BA7B4", // cloud, lit top
    cloud_mid:  "#79838F", // cloud, mid tone (мягкий переход лит->тень)
    cloud_shd:  "#5A6270", // cloud, shadowed underside
    bolt:       "#FFF176", // lightning bolt
};

// Светлая тема - подмена НЕЙТРАЛЬНЫХ цветов: фон, плашки, текст, рамки. Акценты
// (зелёный, красный, оранжевый, голубой) и пиксель-арт остаются прежними. Это
// принципиально не «Инверсия» со страницы «Дебаг»: та переключает регистры
// самой панели и выворачивает всё подряд, включая иконки и акценты.
let THEME_SET = {
    dark: {
        bg: "#0D1117", hdr: "#161B22", widget: "#161B22", white: "#C9D1D9",
        gray: "#8B949E", dim: "#484F58", border: "#30363D", btn: "#21262D",
        press: "#0B0E13", graph: "#0A1016", empty: "#484F58",
    },
    light: {
        bg: "#EBEFF4", hdr: "#FFFFFF", widget: "#FFFFFF", white: "#1F2328",
        gray: "#57606A", dim: "#9AA4AE", border: "#CDD5DE", btn: "#E3E8EE",
        press: "#D5DCE4", graph: "#EDF2F8", empty: "#E3E8EE",
    },
};
let THEME = "dark";

function theme_apply(mode) {
    THEME = (mode == "light") ? "light" : "dark";
    let t = THEME_SET[THEME];
    for (let k in t) C[k] = t[k];
}

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

// Экран Almond+ нативный 480x320 - вдвое-втрое больше пикселей, чем 320x240 у
// 3S, поэтому пиксельный шрифт того же кегля выглядит мелким. FSCALE поднимает
// кегль (целочисленно, чтобы растр остался чётким), а расчёты ширины ниже все
// идут через twpx()/fsz(), чтобы центрирование не разъехалось. На 3S карта
// единичная - там ничего не меняется.
let FSMAP = IS_ALMONDPLUS ? [ 0, 1, 3, 4, 6 ] : [ 0, 1, 2, 3, 4 ];
function fsz(sz) {
    sz ??= 2;
    return (sz >= 1 && sz <= 4) ? FSMAP[sz] : sz;
}
// Ширина строки в пикселях для ЛОГИЧЕСКОГО кегля sz (моноширинно, 6px на клетку).
function twpx(s, sz) {
    return tlen(s) * 6 * fsz(sz);
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


let HDR_H   = IS_ALMONDPLUS ? 24 : 22;
let TG_LINK = "t.me/openwrt_fun";

let COLS    = 2;
let BTN_PAD = 4;
let BTN_W   = ((LCD_W - (BTN_PAD * 3)) / 2); // 154
let BTN_H   = 58;   // три ряда над общей полосой навигации
let START_Y = HDR_H + BTN_PAD;
let BACK_H  = IS_ALMONDPLUS ? 34 : 32;  // полоса навигации: под палец, а не под статус-полосу
let BACK_Y  = LCD_H - BACK_H;
let GEO_JSON = "/tmp/lcd_geo.json";   // ответ геокодера для пикера выбора города

// --- Единая сетка страниц (8px модуль) ---
// Контент живёт в безопасной зоне между шапкой (22) и полосой «назад» (208):
// x 8→312 (304 шир.), y 24→206. Зазор/модуль 8. Две колонки по 148 c гаттером 8.
// Помогает: gcard() рисует карточку с акцентной полосой и возвращает координаты
// для контента (ix/iy - левый-верх с внутренним отступом 10/8).
// Эталон - сетка заставки «Виджеты»: поля по 7, зазор 6, колонка 150.
// Раньше страницы жили на модуле 8 и начинались на GY=24, впритык к шапке.
let GX = 7, GY = 28, GG = 6;
let GR = LCD_W - GX, GW = LCD_W - 2 * GX, GB = LCD_H - BACK_H - GG;
let ZIG_ROWS = 6;
// Вертикальные отступы текста в плитке. Под нативный 480x320 шрифт крупнее
// (см. fzoom в render.c), поэтому строки разводим шире, иначе налезают. На 3S
// прежние значения. Клетка кегля: size1->16px, size2->24px на Almond+.
let TILE_TTL_Y  = IS_ALMONDPLUS ? 25 : 19;  // заголовок (size2)
let TILE_BOT_OFF = IS_ALMONDPLUS ? 13 : 13; // нижняя подпись, отступ от низа
let TILE_ICO_Y  = IS_ALMONDPLUS ? 20 : 14;  // иконка
let GCOL = int((GW - GG) / 2);  // ширина колонки в 2-колоночной раскладке
// Вертикальные границы полезной области. По горизонтали сетка общая давно, а по
// вертикали ритма не было: контент начинался на GY=24, впритык к шапке (просвет
// 2px), а вся невыбранная высота сваливалась вниз одним большим пустым полем.
// GVT/GVB задают такой же отступ GG сверху и снизу, как между карточками.
let GVT = HDR_H + GG;           // верх полезной области (28)
let GVB = BACK_Y - GG;          // низ полезной области (212)
// Высота карточки, когда N штук делят полезную область поровну.
function gcard_h(n) {
    return int((GVB - GVT - (n - 1) * GG) / n);
}
let GH = { xs: 40, s: 64, m: 88, l: 176 };   // набор высот карточек

// Стопка карточек, РОВНО заполняющая полезную область. Веса задают пропорции
// (обычно прежние высоты), помощник растягивает их до низа - раньше страницы
// набирались фиксированными высотами и снизу оставалась пустая полка.
function stack_rects(weights) {
    let n = length(weights), sum = 0;
    for (let w in weights) sum += w;
    if (sum <= 0) sum = 1;
    let avail = GVB - GVT - (n - 1) * GG;
    let out = [], y = GVT, used = 0;
    for (let i = 0; i < n; i++) {
        let h = (i == n - 1) ? (avail - used) : int(avail * weights[i] / sum);
        used += h;
        push(out, { x: GX, y: y, w: GW, h: h });
        y += h + GG;
    }
    return out;
}

// Ряды одной высоты. Если поровну выходит слишком жирно (hmax), остаток
// уходит поровну вверх и вниз: блок стоит по центру, а не липнет к шапке.
// Вертикальный центр строки в плашке. Клетка кегля - 8px на ступень, как в
// остальном коде (size 3 = 24, size 4 = 32). Раньше отступ подбирали руками,
// и в соседних блоках текст стоял на разной высоте.
function mid_y(b, sz) {
    return b.y + int((b.h - fsz(sz ?? 1) * 8) / 2);
}

function fpx(sz) {
    return fsz(sz) * 8;
}

function vfit(top, bot, n, gap) {
    let g = gap ?? GG;
    let h = int((bot - top - (n - 1) * g) / n);
    return { h: h, step: h + g, y0: top };
}

function rows_rect(i, n, hmax) {
    let h = gcard_h(n);
    if (hmax != null && h > hmax) h = hmax;
    let total = n * h + (n - 1) * GG;
    let top = GVT + int((GVB - GVT - total) / 2);
    return { x: GX, y: top + i * (h + GG), w: GW, h: h };
}
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
// Шрифты интерфейса: встроенный 5x7 и три пиксельных. Порядок в списке = то,
// как их перебирает кнопка на странице «Экран».
// Ключ - имя в конфиге, mode - номер шрифта для рендерера (fontmode).
// Парные режимы (комбо) рендерер разбирает сам по масштабу строки.
let FONTS = [
    { key: "std",     label: "FONT STD",     mode: 0 },
    { key: "flipper", label: "FONT FLIPPER", mode: 1 },
    { key: "bitcell", label: "FONT BITCELL", mode: 2 },
    { key: "thin",    label: "FONT THIN",    mode: 3 },
    // Комбо: крупное - плотным bitcell, мелкое - нашим встроенным 5x7.
    { key: "combo",   label: "FONT COMBO",   mode: 4 },
    { key: "lcd",     label: "FONT LCD",     mode: 7 },
    { key: "hard",    label: "FONT HARD",    mode: 8 },
    // Pixel: крупное - Hardpixel, мелкое - тонким thin.
    { key: "pixel",   label: "FONT PIXEL",   mode: 11 },
];
let FONT_MODE = 0;
function font_load() {
    let v = ucur ? ucur.get("almond3s", "display", "font") : null;
    // Умолчание - «Комбо»: крупное плотным bitcell, мелкое встроенным 5x7.
    if (v == null || v == "") v = "combo";
    FONT_MODE = 0;
    for (let i = 0; i < length(FONTS); i++)
        if (FONTS[i].key == v) FONT_MODE = i;
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

// Текст, лежащий прямо на подложке (заголовки секций, подпись страницы
// заставки), берёт отдельный цвет. В светлой теме цвет текста плашек почти
// чёрный, а подложка - насыщенный синий: серые надписи на нём терялись.
// Когда градиент выключен, фон снова спокойный, и цвета возвращаются к обычным.
function ontop_apply() {
    let onblue = (THEME == "light" && GRAD_ON);
    C.ontop_hi  = onblue ? "#FFFFFF" : C.white;
    C.ontop     = onblue ? "#EAF3FF" : C.gray;
    C.ontop_dim = onblue ? "#C3DBF7" : C.dim;
}

// Скругление углов плашек: 0 - выкл, 1-2 пикселя срезаем у каждого угла.
// Свечение акцентом в углу карточек. Общее на весь интерфейс, выключается
// на странице «Экран».
let GLOW_ON = true;
let glow_pend = [];
function glow_load() {
    GLOW_ON = (ucur ? ucur.get("almond3s", "display", "glow") : null) != "0";
}

// Боковые акцентные полосы (3px слева у карточек, кнопок, строк). Тумблер на
// странице «Экран»; по умолчанию включены. Свечения угла это НЕ касается.
let BARS_ON = true;
function bars_load() {
    BARS_ON = (ucur ? ucur.get("almond3s", "display", "bars") : null) != "0";
}
bars_load();

// Интервал опроса тача, мс. Драйвер опрашивает координаты вручную; чем чаще,
// тем «легче» ловится короткий тап (заводской чип семплировал непрерывно на
// 300cps, а мы раз в 60мс - оттого казалось, что надо давить дольше). Вынесен
// в uci для калибровки под конкретный экземпляр экрана.
let TOUCH_MS = 60;
function touch_load() {
    let v = ucur ? ucur.get("almond3s", "display", "touch_ms") : null;
    TOUCH_MS = (v == null || v == "") ? 60 : int(+v);
    if (TOUCH_MS < 20) TOUCH_MS = 20;
    if (TOUCH_MS > 200) TOUCH_MS = 200;
}
touch_load();
// astripe() определён ниже, СРАЗУ после lcd_rect: ucode не хойстит, и функция
// видит только объявленное выше её строки.

let RADIUS = 0;
function radius_load() {
    let v = ucur ? ucur.get("almond3s", "display", "radius") : null;
    RADIUS = (v == null || v == "") ? 0 : int(+v);
    if (RADIUS < 0) RADIUS = 0;
    if (RADIUS > 4) RADIUS = 4;
}
radius_load();
glow_load();

// Оттенок подложки: тумблер «Оттенок фона» на странице «Экран».
//   dark  - исходная схема: фон темнее плашек, карточки «всплывают» над ним;
//   light - обратная: фон чуть СВЕТЛЕЕ C.widget, и плашки читаются утопленными.
// Это не дневная тема: подсвечивается только подложка, цвета текста и плашек
// те же, поэтому C.white/C.gray на обоих вариантах остаются контрастными.
// Светлую пару держим выше C.widget (#161B22) даже в самой тёмной точке -
// иначе внизу экрана карточки слились бы с фоном.
// Пары градиента отдельно для каждой темы: на светлой подложка должна быть
// светлее плашек, иначе карточки на ней тонут.
let BG_TINTS = {
    // На тёмной теме светлый вариант - РОВНАЯ заливка верхним цветом, без
    // растяжки книзу: градиент там читался как грязь, а плоская подложка
    // честно держит плашки над собой.
    dark:  { dark:  { top: "#182C40", bot: "#070A0E" },
             light: { top: "#2B3444", bot: "#2B3444" } },
    // Светлая тема: подложка из нашего акцентного синего (#58A6FF), уведённого
    // книзу в тёмно-синий. Белые плашки на таком фоне читаются как вырезанные.
    light: { dark:  { top: "#529CEA", bot: "#2A66AC" },
             light: { top: "#74B6FF", bot: "#3F7FC9" } },
};
let BG_TINT = "light";
function bg_tint_apply(mode) {
    // Умолчание - светлый: на нём плашки читаются как утопленные панели по
    // всей высоте, а тёмный градиент в середине экрана сливался с ними.
    BG_TINT = (mode == "dark") ? "dark" : "light";
    // Правим саму палитру, а не копию: lcd_clear читает C.bg_top/C.bg_bot на
    // каждом кадре, поэтому переключение видно с первой же перерисовки.
    let pair = BG_TINTS[THEME][BG_TINT];
    C.bg_top = pair.top;
    C.bg_bot = pair.bot;
    ontop_apply();
}
function theme_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "theme") : null;
    return (v == "light") ? "light" : "dark";
}
function theme_load() {
    theme_apply(theme_cfg());
}
// Тему применяем ПЕРЕД оттенком: пары градиента у тем разные.
theme_load();

function bg_tint_load() {
    bg_tint_apply(ucur ? ucur.get("almond3s", "display", "bg") : null);
}
bg_tint_load();

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
    if (LANG == null) {
        LANG = (ucur ? (ucur.get("almond3s", "display", "lang") ?? "ru") : "ru");
        // Кладём язык в /tmp для render: карточку «Прошивка…» он рисует сам
        // (наш uloop к тому моменту заблокирован), а язык взять больше неоткуда.
        fs.writefile("/tmp/.lcd_lang", LANG);
    }
    return LANG;
}

function lang_set(v) {
    LANG = v;
    fs.writefile("/tmp/.lcd_lang", v);
    if (ucur) {
        ucur.set("almond3s", "display", "lang", v);
        ucur.commit("almond3s");
    }
}

let TR_RU = {
    "%d cl.": "%d кл.",
    "about short": "о системе",
    "AP short": "точка",
    "no package": "нет",
    "vpn is on": "включен",
    "vpn is off": "выключен",
    "screen, LED, night": "экран, диод, ночь",
    "screen, night, update": "экран, ночь, обновление",
    "Update": "Обновление",
    "packages": "пакеты",
    "Almond kmod": "Almond kmod",
    "Almond lcd": "Almond lcd",
    "Almond nes": "Almond nes",
    "Checking…": "Проверяю…",
    "Installing…": "Устанавливаю…",
    "Check": "Проверить",
    "Install": "Обновить",
    "Release notes": "Что нового",
    "Loading…": "Загрузка…",
    "Could not load": "Не удалось загрузить",
    "Flashing…": "Прошивка…",
    "Do not power off": "Не выключайте питание",
    "Screen will freeze for a few minutes": "Экран замрёт на несколько минут",
    "Kernel module": "Модуль ядра",
    "Router will reboot": "Роутер перезагрузится",
    "right after install": "сразу после установки",
    "OK": "OK",
    "Cancel": "Отмена",
    "No build for your OpenWrt": "Нет сборки под ядро",
    "Download failed": "Ошибка загрузки",
    "Version unchanged": "Версия не изменилась",
    "Build not ready yet": "Сборка ещё не готова",
    "Could not check": "Ошибка проверки",
    "System Info": "Система",
    "SYSTEM": "СИСТЕМА",
    "POWER": "ПИТАНИЕ",
    "SOFTWARE": "ПРОШИВКА",
    "Uptime %s": "Работает %s",
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
    "LTE restart": "Связь пропадёт на ~15 секунд",
    "Network name": "Имя сети",
    "Type network name": "Введите имя сети",
    "Clients will reconnect": "Устройства переподключатся",
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
    "free RAM %d/%dM": "ОЗУ %d/%dМБ",
    "free RAM %dM": "ОЗУ %dМБ",
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
    "Color": "Цвет",
    "led white": "белый",
    "led red": "красный",
    "led green": "зелёный",
    "led blue": "синий",
    "led yellow": "жёлтый",
    "led cyan": "бирюзовый",
    "led magenta": "пурпурный",
    "led orange": "оранжевый",
    "Widgets": "Виджеты",
    "Air": "Эфир",
    "Peers": "Соседи",
    "Signal": "Сигнал",
    "Key": "Ключ",
    "plain": "без шифра",
    "ms": "мс",
    "heard": "услышан",
    "link": "линк",
    "Beacon": "Маячок",
    "every 10 sec": "раз в 10 с",
    "no peers heard": "соседей не слышно",
    "beacon off": "маячок выключен",
    "Networks": "Сети",
    "Scanning...": "Сканирую...",
    "quietest": "тише всего",
    "no networks found": "сетей не найдено",
    "PAN ID": "PAN ID",
    "Channel": "Канал",
    "TX power": "Мощность",
    "Form network": "Поднять сеть",
    "Leave network": "Выйти из сети",
    "random": "случайный",
    "chip silent": "чип молчит",
    "own network": "своя сеть",
    "coordinator": "координатор",
    "this one": "это устройство",
    "more devices": "ещё, показать:",
    "router role": "маршрутизатор",
    "Overview": "Обзор",
    "Corners": "Углы",
    "uplink": "аплинк",
    "access point": "точка доступа",
    "on battery": "от батареи",
    "charging": "заряжается",
    "about device": "об устройстве",
    "Glow": "Свечение",
    "Bars": "Полосы",
    "Aggregation": "Агрегация",
    "+ Hidden": "+ Скрытая",
    "more": "ещё",
    "Hidden network": "Скрытая сеть",
    "Period": "Период",
    "Topic": "Тема",
    "Node": "Узел",
    "Control": "Управление",
    "both": "оба",
    "Load": "Нагрузка",
    "1 min": "1 мин",
    "Machine": "Система",
    "Memory": "Память",
    "Disk": "Диск",
    "Uptime short": "Аптайм",
    "Operator": "Оператор",
    "Cell": "Сота",
    "Online": "На связи",
    "Quality": "Качество",
    "Temp": "Темп",
    "charging": "заряжается",
    "online": "на связи",
    "on battery": "от батареи",
    "clients": "клиентов",
    "Telemetry": "Телеметрия",
    "Permit short": "Приём",
    "pairing window open": "Приём открыт на 4 минуты",
    "looking for a network": "ищу сеть в эфире…",
    "chip free for other software": "выкл, чип свободен для другого ПО",
    "Broker": "Брокер",
    "Port": "Порт",
    "User": "Логин",
    "Password": "Пароль",
    "адрес или имя": "адрес или имя",
    "по умолчанию 1883": "по умолчанию 1883",
    "если брокер требует": "если брокер требует",
    "хранится в настройках": "хранится в настройках",
    "publishing on": "публикация включена",
    "publishing off": "публикация выключена, нажмите",
    "joined the network": "вступил в сеть",
    "join failed": "вступить не вышло",
    "network not found": "сеть не найдена",
    "key not received": "ключ не получен",
    "rejected": "координатор отказал",
    "MQTT broker": "Брокер MQTT",
    "Type value": "Введите значение",
    "Form short": "Поднять",
    "Join short": "Вступить",
    "Leave short": "Выйти",
    "Flash short": "Прошить",
    "set broker address first": "Сначала задайте адрес брокера",
    "MQTT on": "MQTT включён:",
    "MQTT off": "MQTT выключен",
    "Join network": "Вступить",
    "beacon": "маячок",
    "network": "по сети",
    "via Zigbee network": "через сеть Zigbee",
    "standalone, no network": "сама по себе, без сети",
    "tap to enable": "нажмите, чтобы включить",
    "Update chip": "Прошить",
    "Update Zigbee chip?": "Прошить чип Zigbee?",
    "Takes about a minute.": "Займёт около минуты.",
    "Factory version cannot be restored.": "Вернуть заводскую версию будет нельзя.",
    "Do not power off.": "Не выключайте питание.",
    "Updating chip...": "Прошиваю",
    "Chip updated": "Чип прошит",
    "no firmware in image": "прошивки нет в образе",
    "VPN off": "ВПН выкл",
    "VPN on": "ВПН вкл",
    "Sent": "Отправлено",
    "new msgs": "новых",
    "signal": "сигнал",
    "blink on SMS": "мигание при SMS",
    "above the screen": "над экраном",
    "below the screen": "под экраном",
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
    "Reboot the router": "Аппарат перезапустится",
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
    "Updated": "Обновлено",
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
    "Icons": "Иконки",
    "Theme": "Тема",
    "Background": "Фон",
    "Background tint": "Оттенок фона",
    "Dark": "тёмный",
    "Light": "светлый",
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
    "Choose servers": "Выбор серверов",
    "Net key": "Ключ сети",
    "forming network": "поднимаю сеть",
    "network up, joining open": "сеть поднята, приём открыт на 4 минуты",
    "leaving network": "выхожу из сети",
    "Zigbee networks": "Сети Zigbee",
    "no networks": "сетей не слышно",
    "open joining on the hub": "откройте приём на координаторе",
    "joining open": "приём открыт",
    "joining closed": "приём закрыт",
    "telemetry disabled": "телеметрия выключена",
    "enable telemetry hint": "данные не обновляются - включите в настройках",
    "not in network yet": "в сети не состою",
    "join or form hint": "нажмите Вступить или Поднять",
    "command running": "выполняю команду…",
    "in network": "в сети",
    "ch": "канал",
    "nodes": "узла",
    "waiting for peers": "жду соседей",
    "each announces once a period": "каждый объявляется раз в полминуты",
    "off fem": "выключена",
    "chip free": "чип свободен",
    "Reboot modem": "Ребут модема",
    "Reboot router": "Ребут роутера",
    "Language": "Язык",
    "Font": "Шрифт",
    "custom": "свой",
    "by default": "по умолчанию",
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
    "Custom widgets": "Виджеты Зигби",
    "Custom": "Зигби",
    "Custom 2": "Зигби 2",
    "Custom 3": "Зигби 3",
    "Custom 4": "Зигби 4",
    "tap a cell to assign": "тап по клетке — назначить виджет",
    "pick a device": "выбери устройство",
    "pick a metric": "выбери метрику",
    "pick a size": "выбери размер",
    "clear slot": "убрать",
    "Free RAM": "ОЗУ свободно",
    "Flash free": "Флеш свободно",
    "Kernel": "Ядро",
    "Driver": "Драйвер",
    "Night mode": "НОЧНОЙ РЕЖИМ",
    "FONT FLIPPER": "Flipper",
    "FONT BITCELL": "Bitcell",
    "FONT THIN": "Thin Pixel",
    "FONT COMBO": "Комбо",
    "FONT LCD": "LCD",
    "FONT HARD": "Hardpixel",
    "FONT PIXEL": "Pixel",
    "FONT STD": "Стандарт",
    "LIGHT": "ЯРКОСТЬ",
    "Shift": "Сдвиг",
    "Night": "Ночь",
    "NIGHT MODE": "НОЧНОЙ РЕЖИМ",
    "From": "С",
    "To": "ДО",
    "Weather": "Погода",
    "Clock": "Часы",
    "Status bar": "Статусбар",
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
    "Zigbee": "Zigbee",
    "Games": "Игры",
    "Setup": "Настройки",
    "tap to change": "тап по строке - следующее значение",
    "Gamepad": "Пульт",
    "Settings": "Настройки",
    "screen, saver, night": "экран, заставка, ночь",
    "LIGHT, %": "ЯРКОСТЬ",
    "WARM, %": "ТЕПЛО",
    "brightness, warm, language": "яркость, тепло, язык",
    "timeout and look": "время и вид",
    "schedule and actions": "расписание и действия",
    "driver debug": "отладка драйвера",
    "Warm": "Тепло",
    "Wi-Fi off": "Wi-Fi",
    "Dark theme at night": "Тёмная",
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
    "%d ROMs": "%d ромов",
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
    "active fem": "активна",
    "reserve": "резерв",
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
    glow_pend = [];
    // Фон по умолчанию - вертикальный градиент-подложка под все плашки. Явный
    // цветной clear (сплэши, спец-экраны) остаётся плоской заливкой.
    if (GRAD_ON && (c == null || c == C.bg))
        Q(sprintf('{"cmd":"vgrad","x":0,"y":0,"w":%d,"h":%d,"color":"%s","color2":"%s"}',
                  LCD_W, LCD_H, C.bg_top, C.bg_bot));
    else
        Q(sprintf('{"cmd":"clear","color":"%s"}', c ?? C.bg));
}

// Прямоугольник, скруглённый только с одной стороны: "l" - левые углы,
// "r" - правые. Радиус задаём явно, автоправило сюда не лезет.
function lcd_rect_side(x, y, w, h, c, r, side) {
    Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s","%s":%d}',
              x, y, w, h, c, side == "r" ? "rr" : "rl", r));
}

function lcd_rect(x, y, w, h, c) {
    // Скругляем только плашки: широкий и достаточно высокий прямоугольник, не
    // растянутый на весь экран (шапка - не карточка). Акцентную полоску (узкую
    // и высокую) вместо скругления укорачиваем с обоих концов - её квадратный
    // угол иначе торчал бы из скруглённого угла карточки.
    let r = 0, rs = 0;
    if (RADIUS > 0) {
        // Акцентная полоска (ровно 3px) идёт вдоль закругления - её сдвигает
        // рендерер. Волосяные линии в 1-2 пикселя обрезать нечему, их просто
        // укорачиваем на радиус, иначе угол торчит за пределы плашки.
        if (w == 3 && h >= 14) rs = RADIUS;
        else if (w <= 2 && h >= 14) { y += RADIUS; h -= RADIUS * 2; }
        else if (h <= 2 && w >= 24) { x += RADIUS; w -= RADIUS * 2; }
        else if (w >= 24 && h >= 14 && !(x <= 0 && x + w >= LCD_W)) r = RADIUS;
    }
    if (rs > 0)
        Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s","rs":%d}',
                  x, y, w, h, c, rs));
    else if (r > 0)
        Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s","r":%d}',
                  x, y, w, h, c, r));
    else
        Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s"}', x, y, w, h, c));
}

// Прямоугольник БЕЗ разбора скруглений: столбики графиков узкие и высокие,
// и общий обработчик укорачивал их с обоих концов на радиус.
function lcd_rect_raw(x, y, w, h, c) {
    Q(sprintf('{"cmd":"rect","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s"}', x, y, w, h, c));
}

// Единая точка отрисовки боковой акцентной полосы (3px): выключатель BARS_ON
// гасит её во всём интерфейсе разом. Определён ЗДЕСЬ, после lcd_rect - ucode
// не хойстит, из строки 402 lcd_rect ещё не виден и демон падал.
function astripe(x, y, h, col) {
    if (BARS_ON) lcd_rect(x, y, 3, h, col);
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

let SEG_W = 5, SEG_GAP = 2;

function seg_geom(len, sw) {
    let n = int(len / ((sw ?? SEG_W) + SEG_GAP));
    if (n < 1) n = 1;
    let pitch = int(len / n);
    let sz = pitch - SEG_GAP;
    if (sz < 1) sz = pitch;
    return { n: n, pitch: pitch, sz: sz };
}

function seg_lit(n, pct) {
    let on = int((n * pct + 50) / 100);
    if (pct > 0 && on < 1) on = 1;
    if (on > n) on = n;
    return on;
}

// Приглушённый вариант цвета: смешиваем его с цветом плашки. Нужен пустым
// секциям прогрессбаров, батарейки и уровня сигнала - серый там выглядел
// чужим, а тот же оттенок вполсилы читается как «место под заполнение».
function tint(col, pct, base) {
    if (type(col) != "string" || substr(col, 0, 1) != "#" || length(col) < 7)
        return col;
    let b = (type(base) == "string" && substr(base, 0, 1) == "#" && length(base) >= 7)
          ? base : C.widget;
    let out = "#";
    for (let i = 0; i < 3; i++) {
        let cv = hex(substr(col, 1 + i * 2, 2));
        let bv = hex(substr(b, 1 + i * 2, 2));
        let v = int((cv * pct + bv * (100 - pct)) / 100);
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out += sprintf("%02x", v);
    }
    return out;
}

// Цвет пустой секции: если вызывающий не задал свой (ночной монорежим задаёт),
// берём приглушённый цвет самой полосы.
function seg_empty(col, bg) {
    if (bg != null && bg != C.btn) return bg;
    return tint(col, 26, C.widget);
}

function seg_bar(x, y, w, h, pct, col, bg, key) {
    let p = clampi(int(pct), 0, 100);
    if (key != null) p = clampi(bar_ease(key, p), 0, 100);
    let g = seg_geom(w);
    let on = seg_lit(g.n, p);
    let eb = seg_empty(col, bg);
    for (let i = 0; i < g.n; i++)
        lcd_rect(x + i * g.pitch, y, g.sz, h, i < on ? col : eb);
}

function seg_vbar(x, y, w, h, pct, col, bg, key, sw) {
    let p = clampi(int(pct), 0, 100);
    if (key != null) p = clampi(bar_ease(key, p), 0, 100);
    let g = seg_geom(h, sw);
    let on = seg_lit(g.n, p);
    let eb = seg_empty(col, bg);
    for (let i = 0; i < g.n; i++)
        lcd_rect(x, y + h - i * g.pitch - g.sz, w, g.sz, i < on ? col : eb);
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

// Текст, прижатый к правому краю: x - это правый край, а ширину считает сам
// рендерер. Шрифт пропорциональный и с кернингом, поэтому прежняя прикидка
// «знаков на шесть» промахивалась - у строк с двоеточиями на пять пикселей.
function lcd_text_r(xr, y, text, color, bg, sz) {
    text = strip_ctrl(replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    let b = bg ?? C.bg;
    if (GRAD_ON && b == C.bg) b = "none";
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d,"anchor":"r"}',
        xr, y, text, color ?? C.white, b, sz ?? 2));
}

// Текст, который сам ужмётся на ступень, если не влезает в ширину. Размер
// подбирает рендерер по настоящей ширине строки - в ui.uc её не измерить.
function lcd_text_fit(x, y, text, color, bg, sz, fit) {
    text = strip_ctrl(replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    let b = bg ?? C.bg;
    if (GRAD_ON && b == C.bg) b = "none";
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d,"fit":%d}',
        x, y, text, color ?? C.white, b, sz ?? 2, fit));
}

// Строка служебной статус-полосы: в режиме «Комбо» просим тонкий шрифт.
// Часы и заряд там второго размера, и общее правило уводило их в плотный
// bitcell - для мелкой полосы наверху это слишком жирно.
function lcd_text_thin(x, y, text, color, bg, sz, anch, noz) {
    text = strip_ctrl(replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    let b = bg ?? C.bg;
    if (GRAD_ON && b == C.bg) b = "none";
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d,"fnt":-1,"anchor":"%s","noz":%d}',
        x, y, text, color ?? C.white, b, sz ?? 2, anch ?? "l", noz ?? 0));
}

// Текст по центру: центр задаёт x, ширину считает рендерер. Прикидка
// «длина * 6» врала на пропорциональном шрифте с кернингом - цифры в клетках
// яркости стояли заметно левее середины.
function lcd_text_noz(x, y, text, color, bg, sz, anch) {
    text = strip_ctrl(replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    let b = bg ?? C.bg;
    if (GRAD_ON && b == C.bg) b = "none";
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d,"anchor":"%s","noz":1}',
        x, y, text, color ?? C.white, b, sz ?? 2, anch ?? "l"));
}

function text_fit2(x, y, text, color, bg, room) {
    if (!IS_ALMONDPLUS) { lcd_text_fit(x, y, text, color, bg, 2, room); return; }
    if (twpx(text, 2) <= room) { lcd_text(x, y, text, color, bg, 2); return; }
    if (tlen(text) * 12 <= room) { lcd_text_noz(x, y + 4, text, color, bg, 2); return; }
    lcd_text(x, y + 8, text, color, bg, 1);
}

function lcd_text_c(xc, y, text, color, bg, sz) {
    text = strip_ctrl(replace(replace(replace(text ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    let b = bg ?? C.bg;
    if (GRAD_ON && b == C.bg) b = "none";
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":%d,"anchor":"c"}',
        xc, y, text, color ?? C.white, b, sz ?? 2));
}

// Лёгкое свечение акцентного цвета в нижнем правом углу карточки. Рисует
// рендерер одной командой: смешивание с фоном в ucode стоило бы десятка
// прямоугольников на карточку. В ночном монорежиме не трогаем - там вся
// палитра одноцветная и подсветка угла только грязнит.
function dash_glow(b, o, acc) {
    if (!GLOW_ON || o?.mono || !acc) return;
    let gw = int(b.w * 2 / 3), gh = int(b.h * 2 / 3);
    if (gw < 8 || gh < 8) return;
    // Свечение не рисуем сразу, а копим: уходит оно последним, уже поверх
    // надписей. Иначе текст со своей фоновой плашкой вырезал бы из градиента
    // прямоугольники - ровно то, что было видно на карточках виджетов.
    push(glow_pend,
         sprintf('{"cmd":"corner","x":%d,"y":%d,"w":%d,"h":%d,"color":"%s","a":%d,"lft":1}',
                 b.x, b.y + b.h - gh, gw, gh, acc, 32));
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
    if (accent) {
        astripe(x, y, h, accent);   // полоска тоньше (3px), гасится тумблером
        dash_glow({ x: x, y: y, w: w, h: h }, null, accent);
    }
    // ix - отступ текста от полоски (13px), чтобы не липло к акценту.
    return { x: x, y: y, w: w, h: h, ix: x + 13, iy: y + 9, r: x + w };
}

// Те же координаты, что gcard, но БЕЗ отрисовки плашки/акцента - для заставки
// «Погода»: раскладка карточек, но без фоновых прямоугольников (текст поверх
// градиента-подложки).
function empty_msg(text, col, sz, x3s, y3s) {
    if (!IS_ALMONDPLUS) { lcd_text(x3s ?? 20, y3s ?? 100, text, col, C.bg, sz ?? 2); return; }
    lcd_text_c(int(LCD_W / 2), int((HDR_H + BACK_Y - fpx(sz ?? 2)) / 2), text, col, C.bg, sz ?? 2);
}

function gcard_pos(x, y, w, h) {
    return { x: x, y: y, w: w, h: h, ix: x + 13, iy: y + 9, r: x + w };
}

// Native socket — connect/send/close per flush (fast, no deadlock)
function lcd_raw(cmd) {
    let s;
    try {
        s = create_socket(AF_UNIX, SOCK_STREAM, 0);
        s.connect(SOCK_PATH);
        s.send(cmd + "\n");
        s.close();
    } catch(e) {
        try { s.close(); } catch(e2) {}
    }
}

function lcd_flush() {
    for (let g in glow_pend) Q(g);
    glow_pend = [];
    // Активный тост дорисовываем поверх любого кадра: так неблокирующая полоса
    // держится, даже если вызывающий после toast() сразу перерисовал страницу.
    if (st.toast && st.toast.until && time() < st.toast.until) {
        let t = st.toast;
        lcd_rect(0, LCD_H - 36, LCD_W, 36, t.bg);
        lcd_rect(0, LCD_H - 37, LCD_W, 1, t.color);
        lcd_text(10, LCD_H - 30, t.msg, t.color, t.bg, 2);
    }
    if (!length(cmds)) return;
    unshift(cmds, sprintf('{"cmd":"fontmode","mode":%d}', FONTS[FONT_MODE].mode ?? 0));
    if (!st.no_flush) push(cmds, '{"cmd":"flush"}');
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
    let ec = empty ?? tint(col, 26, C.hdr);
    for (let i = 0; i < 5; i++) {
        let bh = 4 + i * 3;
        lcd_rect(x + i * 8, y + 16 - bh, 6, bh, i < bars ? col : ec);
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
    let ec = empty ?? tint(sc, 26, bg);
    // Крайние деления скругляем с внешней стороны - вслед за рамкой, иначе
    // внутри закруглённой батарейки торчат квадратные углы. Хватает 1 пикселя:
    // деление всего пять точек шириной.
    let sr = RADIUS >= 3 ? 2 : (RADIUS > 0 ? 1 : 0);
    for (let i = 0; i < 4; i++) {
        let on = i >= 4 - sections;
        if (i == blink_idx && (anim_phase % 2) == 1) on = false;
        let col = on ? sc : ec;
        let sx = x + 3 + i * pitch, sw = pitch - 2;
        if (sr && i == 0)      lcd_rect_side(sx, y + 2, sw, h - 4, col, sr, "l");
        else if (sr && i == 3) lcd_rect_side(sx, y + 2, sw, h - 4, col, sr, "r");
        else                   lcd_rect(sx, y + 2, sw, h - 4, col);
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
    lcd_rect(x, y, w, h, C.graph);

    // Threshold lines (dashed — draw every 4px)
    if (thresholds) {
        for (let t in thresholds) {
            let ty2 = y + h - int((t.val - mn) * h / range);
            if (ty2 > y && ty2 < y + h) {
                for (let dx = 0; dx < w; dx += 8)
                    lcd_rect(x + dx, ty2, 4, 1, t.color ?? C.gray);
                // Label on right
                lcd_text(x + w - 30, ty2 - 4, t.label ?? "", t.color ?? C.gray, C.graph, 1);
            }
        }
    }

    // Scale labels (left: max, bottom: min)
    lcd_text(x + 1, y + 1, sprintf("%d", mx), C.gray, C.graph, 1);
    lcd_text(x + 1, y + h - 9, sprintf("%d", mn), C.gray, C.graph, 1);

    // Plot line: connect points
    let pts = n > HIST_LEN ? HIST_LEN : n;
    let start = n - pts;
    // В ucode целые делятся НАЦЕЛО: шаг вида (w-2)/(pts-1) округлялся вниз,
    // и накопленная потеря оставляла справа пустую полосу до двух десятков
    // пикселей - тем шире, чем меньше точек. Считаем позицию каждой точки от
    // начала: умножаем сперва, делим потом.
    let span = w - 2, last_i = pts - 1;
    if (last_i < 1) last_i = 1;

    let prev_px = -1, prev_py = -1;
    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * span / last_i);
        let nx = x + 1 + int((i + 1) * span / last_i);
        let step_x = nx - px; if (step_x < 1) step_x = 1;
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
    // Графики лежат на плашке - фон берём её же. Отдельная тёмная заливка
    // выглядела чёрной дырой посреди светлой карточки.
    lcd_rect(x, y, w, h, C.widget);
    let n = length(data);
    if (n < 2) return;
    if (mx <= mn) mx = mn + 1;
    let range = mx - mn;
    // Каждый массив истории сам ограничивает свою длину (трафик 60,
    // батарея 120) - рисуем всё, что есть.
    let pts = n;
    let start = 0;
    // Та же беда с целочисленным делением, что и в draw_graph.
    let span = w - 2, last_i = pts - 1;
    if (last_i < 1) last_i = 1;
    let prev_px = -1, prev_py = -1;

    for (let i = 0; i < pts; i++) {
        let val = data[start + i];
        let px = x + 1 + int(i * span / last_i);
        let nx = x + 1 + int((i + 1) * span / last_i);
        let step_x = nx - px; if (step_x < 1) step_x = 1;
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

function dash_spark(x, y, w, h, data, color, mn, mx) {
    let n = length(data);
    if (n < 2 || mx <= mn) return;
    let cap = int((w - 2) / 2);
    let from = n > cap ? n - cap : 0, cnt = n - from;
    if (cnt < 2) return;
    // Позицию точки считаем от начала: при целочисленном делении шаг
    // округлялся вниз, и линия не доходила до правого края.
    let span = w - 2, last_i = cnt - 1;
    if (last_i < 1) last_i = 1;
    let prev = -1, prevx = -1;
    for (let i = 0; i < cnt; i++) {
        let v = data[from + i];
        if (v > mx) v = mx;
        if (v < mn) v = mn;
        let px = x + 1 + int(i * span / last_i);
        let py = y + h - 2 - int((v - mn) * (h - 4) / (mx - mn));
        if (prev >= 0) {
            let dy = py - prev, ys = dy > 0 ? prev : py;
            if (dy != 0) lcd_rect(px, ys, 1, dy > 0 ? dy : -dy, color);
            lcd_rect(prevx, prev, px - prevx, 1, color);
        }
        lcd_rect(px, py, 1, 1, color);
        prev = py;
        prevx = px;
    }
}

// Единый график интерфейса: цветные столбики на пиксельной сетке - тот же
// язык, что у замера скорости. Столбик = один отсчёт, ширина постоянная,
// высота шагом в 2px.
//
// Две величины в одном поле (приём и отдача) рисуем зеркально от средней
// линии: приём вверх, отдача вниз. Наложить их друг на друга нельзя - верхний
// закрывает нижний, а рядом в клетке по паре столбиков при ширине окна
// в один-два пикселя не разглядеть.
function bar_graph(x, y, w, h, series, mn, mx) {
    let nseries = length(series ?? []);
    if (nseries < 1 || w < 6 || h < 6) return;
    mn ??= 0;
    if (mx == null || mx <= mn) {
        mx = mn;
        for (let sr in series)
            for (let v in (sr.data ?? [])) { let f = +v; if (f > mx) mx = f; }
    }
    if (mx <= mn) return;

    // Сетка столбиков - ТА ЖЕ, что у прогрессбаров: seg_geom делит поле на
    // равные клетки, столбик 5px, просвет 2. Раньше ширина считалась от числа
    // точек и у каждого графика выходила своя.
    let g = seg_geom(w);

    // Колонка -> отсчёт: истории больше клеток - берём последние, меньше -
    // растягиваем, чтобы поле было заполнено целиком.
    let pick = function(n, i) {
        if (n >= g.n) return n - g.n + i;
        return int(i * n / g.n);
    };

    if (nseries == 1) {
        let d = series[0].data ?? [], n = length(d);
        if (n < 1) return;
        for (let i = 0; i < g.n; i++) {
            let v = +d[pick(n, i)];
            if (v > mx) v = mx;
            if (v < mn) v = mn;
            let bh = int((v - mn) * h / (mx - mn));
            bh = int(bh / 2) * 2;
            if (bh < 2) bh = 2;
            lcd_rect_raw(x + i * g.pitch, y + h - bh, g.sz, bh, series[0].color);
        }
        return;
    }

    // Две величины - от средней линии в разные стороны.
    let half = int((h - 1) / 2), my = y + half;
    lcd_rect_raw(x, my, w, 1, C.border);
    for (let k = 0; k < 2; k++) {
        let d = series[k].data ?? [], n = length(d);
        if (n < 1) continue;
        for (let i = 0; i < g.n; i++) {
            let v = +d[pick(n, i)];
            if (v > mx) v = mx;
            if (v < mn) v = mn;
            let bh = int((v - mn) * (half - 1) / (mx - mn));
            bh = int(bh / 2) * 2;
            if (bh < 2) bh = 2;
            let bx = x + i * g.pitch;
            if (k == 0) lcd_rect_raw(bx, my - bh, g.sz, bh, series[k].color);
            else        lcd_rect_raw(bx, my + 1, g.sz, bh, series[k].color);
        }
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


let LED_COLORS = [ [ "ffffff", "led white" ], [ "ff0000", "led red" ],
                   [ "00ff00", "led green" ], [ "0000ff", "led blue" ],
                   [ "ffff00", "led yellow" ], [ "00ffff", "led cyan" ],
                   [ "ff00ff", "led magenta" ], [ "ff4000", "led orange" ] ];

function led_rgb() {
    return fs.access("/sys/class/leds/red:status/brightness");
}

function led_color_name(hex) {
    for (let c in LED_COLORS)
        if (c[0] == hex) return tr(c[1]);
    return hex;
}

function led_color_next(hex) {
    for (let i = 0; i < length(LED_COLORS); i++)
        if (LED_COLORS[i][0] == hex)
            return LED_COLORS[(i + 1) % length(LED_COLORS)][0];
    return LED_COLORS[0][0];
}

function led_cfg() {
    let st_ = ucur ? ucur.get("almond3s", "led", "state") : null;
    let sm = ucur ? ucur.get("almond3s", "led", "sms_blink") : null;
    let col = ucur ? ucur.get("almond3s", "led", "color") : null;
    return {
        on:  (st_ == null || st_ == "") ? true : (st_ == "1"),
        sms: (sm == "1"),
        color: (col == null || col == "") ? "ffffff" : col,
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
    system(sprintf("almond3s-lcd led %s %s >/dev/null 2>&1", mode, led_cfg().color));
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
    // Этим страницам uptime/wan не нужны, опрос пропускаем. И на время окна
    // после переключения Wi-Fi (netifd перезагружает радио) - тоже: иначе
    // ubus-вызов ниже блокируется на всю перезагрузку и вешает UI.
    let wifi_busy = st.wifi_cd != null && (time() - st.wifi_cd) < 8;
    if (uconn && !st.blank && !wifi_busy && st.page != "kbd" && st.page != "stascan") {
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
    if (d > 0) {
        let w = lang() == "ru" ? plural_ru(d, "день", "дня", "дней")
                               : (d == 1 ? "day" : "days");
        // С днями секунды - шум, зато часы обязательны: «1 день, 17:15» без
        // них читалось бы как семнадцать часов, а не семнадцать минут.
        return sprintf("%d %s, %d:%02d", d, w, hh, mm);
    }
    if (hh > 0) return sprintf("%d:%02d:%02d", hh, mm, ss);
    return sprintf("%d:%02d", mm, ss);
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

// Компактный аптайм для узких клеток виджетов: там колонка ~74 пикселя, а
// «1 день 0ч 3м» занимает больше и вылезала за карточку. Минуты рядом с сутками
// всё равно шум, поэтому в этом виде их не показываем.
function fmt_uptime_c(s) {
    s = int(+(s ?? 0));
    let d = int(s / 86400);
    let h = int((s % 86400) / 3600);
    let m = int((s % 3600) / 60);
    let ru = (lang() == "ru");
    if (d > 0) return sprintf(ru ? "%dд %dч" : "%dd %dh", d, h);
    if (h > 0) return sprintf(ru ? "%dч %dм" : "%dh %dm", h, m);
    return sprintf(ru ? "%dм" : "%dm", m);
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
let SAVER_STYLES = [ "full", "clock", "line", "dash", "matrix", "logo", "off" ];
// Стили-сцены заставки -> индекс сцены в kmod (almond3s-lcd scene N).
// Матрица = 0, наш баннер-лого = 1. Остальные сцены вырезаны из драйвера.
let SAVER_SCENE_MAP = { "matrix": 0, "logo": 1 };

function saver_style() {
    let v = ucur ? ucur.get("almond3s", "display", "saver_style") : null;
    for (let x in SAVER_STYLES) if (x == v) return v;
    return "dash";
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

// Страница «Экран»: четыре ряда настроек по 28 с зазором 6 и ряд яркости,
// прижатый к низу полезной области. Одна арифметика на всю страницу.
function disp_row(i) {
    if (!IS_ALMONDPLUS) return { x: GX, y: GVT + i * 34, w: GW, h: 28 };
    let v = vfit(GVT, GVB, 5);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}
function disp_half(i, right) {
    let r = disp_row(i);
    return { x: right ? GX + GCOL + GG : GX, y: r.y, w: GCOL, h: r.h };
}

// «+» и «−» на кнопках рисуем прямоугольниками: у глифа есть правый вынос,
// и по центру плашки он не встаёт ни при каком якоре - знаки уезжали влево
// и вверх.
function draw_pm(b, plus, col) {
    let cx = b.x + int(b.w / 2), cy = b.y + int(b.h / 2);
    // Плечо знака - по меньшей стороне кнопки, но не длиннее прежних 19px:
    // на маленьких квадратах фиксированный размер упирался в рамку.
    let side = b.w < b.h ? b.w : b.h;
    let arm = int(side * 55 / 100);
    if (arm > 19) arm = 19;
    if (arm < 7) arm = 7;
    if (arm % 2 == 0) arm++;
    let half = int(arm / 2);
    lcd_rect_raw(cx - half, cy - 1, arm, 3, col);
    if (plus) lcd_rect_raw(cx - 1, cy - half, 3, arm, col);
}

let DISP_ROT_W = IS_ALMONDPLUS ? 72 : 56;
let DISP_LANG_W = IS_ALMONDPLUS ? 84 : 62;

function rot_btn() {
    let r = disp_row(0);
    return { x: GX, y: r.y, w: DISP_ROT_W, h: r.h };
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

// Страница «Ночь» на той же сетке: тумблер, пара часов, два ряда уровней и
// ряд действий. Ряды считаются от полезной области, а не от чисел.
function night_row(i) {
    let ys = [ GVT, GVT + 34, GVT + 72, GVT + 106, GVT + 140 ];
    let hs = [ 28, 32, 28, 28, 34 ];
    if (IS_ALMONDPLUS) {
        ys = [ GVT, GVT + 46, GVT + 98, GVT + 144, GVT + 190 ];
        hs = [ 38, 44, 38, 38, 50 ];
    }
    return { x: GX, y: ys[i], w: GW, h: hs[i] };
}

let NIGHT_LAB_W = IS_ALMONDPLUS ? 96 : 56;

function nbright_btn(i) {
    let r = night_row(2);
    if (!IS_ALMONDPLUS) return { x: GX + 56 + i * 51, y: r.y, w: 47, h: r.h };
    let w = int((GW - NIGHT_LAB_W - 4 * GG) / 5);
    return { x: GX + NIGHT_LAB_W + i * (w + GG), y: r.y, w: w, h: r.h };
}

// Что именно делать ночью. Раньше режим влиял только на экран, поэтому и жил
// внутри «Заставки»; теперь это расписание для устройства целиком.
let NIGHT_ACTS = [
    { key: "night_wifi",  label: "Wi-Fi off" },
    { key: "night_green", label: "Green saver", def: true },
    { key: "night_theme", label: "Dark theme at night" },
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
    let r = night_row(3);
    if (!IS_ALMONDPLUS) return { x: GX + 56 + i * 64, y: r.y, w: 60, h: r.h };
    let w = int((GW - NIGHT_LAB_W - 3 * GG) / 4);
    return { x: GX + NIGHT_LAB_W + i * (w + GG), y: r.y, w: w, h: r.h };
}

// Три переключателя в ряд: свободной вертикали на странице нет, а значение
// рисуется справа, поэтому в 96 пикселей помещается короткая подпись плюс
// «вкл/выкл». Отсюда и укороченные названия.
function nact_btn(i) {
    let r = night_row(4);
    if (!IS_ALMONDPLUS) return { x: GX + i * 104, y: r.y, w: 98, h: r.h };
    let w = int((GW - 2 * GG) / 3);
    return { x: GX + i * (w + GG), y: r.y, w: w, h: r.h };
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
    let c = i % 4, r = int(i / 4);
    if (!IS_ALMONDPLUS) return { x: GX + c * 78, y: GVT + 64 + r * 36, w: 72, h: 30 };
    let w = int((GW - 3 * GG) / 4);
    return { x: GX + c * (w + GG), y: GVT + 76 + r * 54, w: w, h: 48 };
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
    if (v == "line")   return tr("Status bar");
    if (v == "dash")   return tr("Widgets");
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
let SV_TOP_H = IS_ALMONDPLUS ? 56 : 44;
let SV_PM_W = IS_ALMONDPLUS ? 108 : 72;
let SV_BOT_H = IS_ALMONDPLUS ? 48 : 36;

function saver_box() {
    return { x: GX, y: GVT, w: GCOL, h: SV_TOP_H };
}

function saver_btn(which) {
    return which > 0 ? { x: GX + GCOL + GG, y: GVT, w: SV_PM_W, h: SV_TOP_H }
                     : { x: GX + GCOL + GG + SV_PM_W + GG, y: GVT, w: SV_PM_W, h: SV_TOP_H };
}

function svshift_btn() {
    return { x: GX, y: GVB - SV_BOT_H, w: int(GW / 2) - 3, h: SV_BOT_H };
}

function svcust_btn() {
    return { x: GX + int(GW / 2) + 3, y: GVB - SV_BOT_H, w: GW - int(GW / 2) - 3, h: SV_BOT_H };
}

function svnight_btn() {
    return { x: GX, y: GVB - SV_BOT_H, w: int(GW / 2) - 3, h: SV_BOT_H };
}

// Язык - одной кнопкой в правом верхнем углу: флаг и код языка.
// Язык - компактная кнопка в правом краю ряда 0 (флаг + код), освобождает
// правую половину ряда 3 под тумблер «Полосы».
function lang_btn() {
    let r = disp_row(0);
    return { x: GR - DISP_LANG_W, y: r.y, w: DISP_LANG_W, h: r.h };
}
function bars_btn() { return disp_half(3, true); }
function lang_btn_old() {
    return { x: GR - 74, y: 28, w: 74, h: 28 };
}

function font_btn() {
    let r = disp_row(0);
    // Язык уехал компактной кнопкой в правый край ряда 0 - шрифт не тянем на
    // всю ширину, оставляем ему место.
    let x = GX + DISP_ROT_W + GG;
    return { x: x, y: r.y, w: (GR - DISP_LANG_W) - x - GG, h: r.h };
}
function font_btn_old() {
    return { x: GX + 64, y: 28, w: GR - 74 - GG - (GX + 64), h: 28 };
}

// Два тумблера в одной строке: иконки меню слева, фон-градиент справа - по
// колонкам сетки.
// Тумблер «Иконки» временно убран со страницы: сама возможность осталась и
// живёт в almond3s.display.micons, но кнопки нет, пока не доделаем иконки.
function theme_btn()  { return disp_half(1, true); }
// Фон одной кнопкой на три состояния: выкл / светлый / тёмный. Раньше их было
// две - выключатель градиента и оттенок отдельной строкой, - и строка съедала
// высоту, из-за которой всё остальное на странице приходилось жать.
function bg_btn()     { return disp_half(1, false); }

// Переключатели: гашение, сдвиг, ночь. Состояние показывает цвет полоски,
// поэтому слова «вкл/выкл» на кнопках не нужны.
// Семь шагов в ряд: ряд занимает всю ширину, подпись уезжает строкой выше -
// иначе на кнопку остаётся 28 пикселей, это уже уже пальца.
let DISP_BR_LAB = IS_ALMONDPLUS ? 84 : 0;

function bright_btn(i) {
    if (!IS_ALMONDPLUS) return { x: GX + 4 + i * 43, y: GVB - 28, w: 40, h: 28 };
    let r = disp_row(4);
    let w = int((GW - DISP_BR_LAB - 6 * GG) / 7);
    return { x: GX + DISP_BR_LAB + i * (w + GG), y: r.y, w: w, h: r.h };
}

function tog_btn(i) {
    if (i == 0) return { x: GX, y: 64, w: GCOL, h: 38 };
    return { x: GX + GCOL + GG, y: 64, w: GCOL, h: 38 };
}

// Часы «с» и «до» живут на своей странице: две группы «минус - значение - плюс».
// Две группы часов стоят в одном ряду: «с» слева, «до» справа - раньше они
// занимали два ряда и страница уходила вниз.
function hour_btn(row, which) {
    let r = night_row(1);
    let x0 = GX + row * (GCOL + GG);
    if (IS_ALMONDPLUS) {
        if (which > 0) return { x: x0 + 40, y: r.y, w: 56, h: r.h };
        if (which < 0) return { x: x0 + 168, y: r.y, w: 56, h: r.h };
        return { x: x0 + 102, y: r.y, w: 60, h: r.h };
    }
    if (which > 0) return { x: x0 + 20, y: r.y, w: 40, h: r.h };
    if (which < 0) return { x: x0 + 108, y: r.y, w: 42, h: r.h };
    return { x: x0 + 64, y: r.y, w: 40, h: r.h };
}

function night_btn() {
    return night_row(0);
}

// Флажок 14x10: у RU три полосы, у EN синее поле с крестом. Рисуем
// прямоугольниками - в шрифте таких символов нет и не будет.
let FLAG_GB = [
    "WW...WRRRW...WW",
    ".WW..WRRRW..WW.",
    "..WW.WRRRW.WW..",
    "WWWWWWRRRWWWWWW",
    "RRRRRRRRRRRRRRR",
    "RRRRRRRRRRRRRRR",
    "WWWWWWRRRWWWWWW",
    "..WW.WRRRW.WW..",
    ".WW..WRRRW..WW.",
    "WW...WRRRW...WW",
];

// Юнион Джек 15x10 по клеткам. Прежний рисовался тремя прямоугольниками -
// синее поле да крест из белой и красной полосы, и косого креста не было
// вовсе. Красные диагонали на такой сетке превращаются в шум, поэтому косой
// крест белый, а красным остаётся прямой - так флаг узнаётся.
function draw_flag_gb(x, y) {
    for (let r = 0; r < length(FLAG_GB); r++) {
        let row = FLAG_GB[r], w = length(row), c = 0;
        while (c < w) {
            let ch = substr(row, c, 1), c0 = c;
            while (c < w && substr(row, c, 1) == ch) c++;
            lcd_rect_raw(x + c0, y + r, c - c0, 1,
                         ch == "W" ? "#FFFFFF" : (ch == "R" ? "#C8102E" : "#012169"));
        }
    }
}

function draw_flag(x, y, code) {
    if (code == "ru") {
        lcd_rect(x, y,     14, 3, "#FFFFFF");
        lcd_rect(x, y + 3, 14, 4, "#0039A6");
        lcd_rect(x, y + 7, 14, 3, "#D52B1E");
    } else {
        draw_flag_gb(x, y);
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
        draw_flag_gb(x, y);
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


// Раскладка меню - та же сетка, что у виджетов заставки: четыре колонки по
// 72 пикселя, три ряда по 52, зазор 6. Плитка занимает столько клеток,
// сколько ей есть чем заполнить: у «Сети» и «Модема» под названием живёт
// метрика, а «VPN» или «СМС» хватает одной клетки.
// Сетка меню = сетка заставки по ширине; высота ряда добирает полезную
// область до полосы навигации, чтобы снизу не оставалось пустой полки.
let MG = 6, MMX = GX, MMY = GVT;
let MCW = int((GW - 3 * MG) / 4);
let MCH = int((GVB - GVT - 2 * MG) / 3);

let MENU_LAYOUT = [
    [
        { act: "dashboard", c: 0, r: 0, cw: 2 },
        { act: "lte",       c: 2, r: 0, cw: 2 },
        { act: "wifi",      c: 0, r: 1, cw: 1 },
        { act: "vpn",       c: 1, r: 1, cw: 1 },
        { act: "traffic",   c: 2, r: 1, cw: 2 },
        { act: "services",  c: 0, r: 2, cw: 1 },
        { act: "speedtest", c: 1, r: 2, cw: 2 },
        { act: "sms",       c: 3, r: 2, cw: 1 },
    ],
    [
        { act: "settings",  c: 0, r: 0, cw: 2 },
        { act: "battery",   c: 2, r: 0, cw: 2 },
        { act: "weather",   c: 0, r: 1, cw: 2 },
        { act: "alarm",     c: 2, r: 1, cw: 1 },
        { act: "power",     c: 3, r: 1, cw: 1 },
        { act: "zigbee",    c: 0, r: 2, cw: 1 },
        { act: "term",      c: 1, r: 2, cw: 1 },
        { act: "games",     c: 2, r: 2, cw: 1 },
        { act: "info",      c: 3, r: 2, cw: 1 },
    ],
];
if (!HAS_BATTERY)
    for (let gi = 0; gi < length(MENU_LAYOUT); gi++) {
        if (!length(filter(MENU_LAYOUT[gi], (t) => t.act == "battery"))) continue;
        MENU_LAYOUT[gi] = filter(MENU_LAYOUT[gi], (t) => t.act != "battery");
        for (let t in MENU_LAYOUT[gi])
            if (t.act == "settings") t.cw = 4;
    }


// Almond+: нет батареи и звука - на их место (будильник+батарея) ставим Z-Wave,
// раскладку 2-й страницы задаём явно.
if (IS_ALMONDPLUS) {
    MENU_LAYOUT[1] = [
        { act: "settings", c: 0, r: 0, cw: 2 },
        { act: "weather",  c: 2, r: 0, cw: 2 },
        { act: "power",    c: 0, r: 1, cw: 1 },
        { act: "term",     c: 1, r: 1, cw: 1 },
        { act: "games",    c: 2, r: 1, cw: 1 },
        { act: "info",     c: 3, r: 1, cw: 1 },
        { act: "zigbee",   c: 0, r: 2, cw: 2 },
        { act: "zwave",    c: 2, r: 2, cw: 2 },
    ];
}

function menu_cell(t) {
    let cw = t.cw ?? 1, ch = t.ch ?? 1;
    return {
        x: MMX + t.c * (MCW + MG),
        y: MMY + t.r * (MCH + MG),
        w: cw * MCW + (cw - 1) * MG,
        h: ch * MCH + (ch - 1) * MG,
    };
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

function confirm_geo(s) {
    if (!IS_ALMONDPLUS)
        return { x: s.x, y: s.y, w: s.w, h: s.h, tx: s.x + 16, ty: s.y + 15, lh: 20,
                 yes: { x: s.x1, y: s.by, w: s.bw, h: s.bh },
                 no:  { x: s.x2, y: s.by, w: s.bw, h: s.bh } };
    let w = 400, h = 210, x = int((LCD_W - w) / 2), y = int((LCD_H - h) / 2);
    let bw = 150, bh = 50, by = y + h - bh - 18;
    return { x: x, y: y, w: w, h: h, tx: x + 24, ty: y + 18, lh: 30,
             yes: { x: x + 34, y: by, w: bw, h: bh },
             no:  { x: x + w - bw - 34, y: by, w: bw, h: bh } };
}

function confirm_btn_text(b, label, col, bg) {
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    lcd_text_c(b.x + int(b.w / 2), b.y + int((b.h - fpx(2)) / 2), label, col, bg, 2);
}

// Зажатие кнопки повторяет шаг: первые повторы редкие, дальше чаще. Демон
// касаний, пока палец прижат, каждые 50мс пишет движение - по нему и понимаем,
// что кнопку не отпустили. Без этого PAN ID пришлось бы набирать сотнями
// отдельных тапов.
function hold_repeat(b, fn) {
    // Повтор начинается только после ПОЛСЕКУНДЫ непрерывного удержания.
    // Обычный тап держится 100-300мс, и прежняя схема «подождать 400мс и
    // посмотреть, есть ли движение» засчитывала его как удержание: палец ещё
    // не оторвали, демон писал движение - выходил лишний шаг. Считаем подряд
    // идущие выборки по 100мс: короткий тап их наберёт две-три и уйдёт ни с чем.
    let held = 0, n = 0;
    while (n < 600) {
        // Файлы касаний - уровень, а не событие: чистим перед каждой выборкой,
        // иначе засчитаем то, что демон записал ещё до начала ожидания.
        fs.unlink(TOUCH_PATH);
        fs.unlink(TOUCH_PATH + ".move");
        sock_poll(100);
        let t = read_touch();
        if (t == null || !in_rect(t.x, t.y, b.x, b.y, b.w, b.h)) return;
        held++;
        if (held < 5) continue;
        fn();
        n++;
    }
}

// Ожидание ответа в модальном окне. ЕДИНСТВЕННЫЙ правильный способ ждать
// нажатие в диалоге: файловый путь тача - это УРОВЕНЬ, а не событие, демон
// пишет точку всё время, пока палец на стекле. Наивный цикл sleep+read_touch
// ловил остаток того же тапа, которым открыли окно, и окно закрывалось само
// (баг с исчезающим подтверждением прошивки Zigbee). Ждём драйверным
// waittouch - он ловит именно фронт «отпущено->нажато», тем же примитивом
// пользуется меню питания. Возвращает {x,y} свежего касания или null по
// таймауту (секунды, по умолчанию 10). Все диалоги с кнопками обязаны звать
// его, а не read_touch напрямую.
function modal_touch(timeout) {
    for (let d = 0; d < 5 && read_touch(); d++);       // сбросить хвост файлового пути
    let deadline = time() + (timeout ?? 10);
    while (time() < deadline) {
        let p = fs.popen("/usr/bin/almond3s-lcd waittouch 1000", "r");
        if (!p) { sock_poll(400); continue; }
        let line = p.read("line");
        p.close();
        let m = line ? match(trim(line), /^(\d+)\s+(\d+)/) : null;
        if (!m) continue;                              // секунда без касания - ждём дальше
        let ct = { x: +m[1], y: +m[2] };
        for (let d = 0; d < 5 && read_touch(); d++);   // сбросить хвост самого нажатия
        return ct;
    }
    return null;
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
// Значок «бейджевой» формы: точка в левом нижнем углу и три дуги, растущие от
// неё вверх-вправо. Старый арт был симметричной «ромашкой» из контуров разной
// толщины - на 21x14 дуги сливались в пятно. Здесь у всех четырёх элементов
// одна толщина (2px) и одинаковые просветы, поэтому секции читаются даже на
// самой мелкой подсветке. Дуги эллиптические: клетка иконки 21x14, на круговых
// четвертях остались бы пустыми шесть колонок справа.
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
    "..............",
    "..............",
    ".############.",
    "##############",
    "#.#.#..##.##.#",
    "#.#.#.#.#.##.#",
    "#.#.#.#.#.##.#",
    "#.#.#..##..#.#",
    "#.#.#.###.#..#",
    "##.##.###.##.#",
    "##############",
    ".############.",
    "..............",
    "..............",
];
let HOME_DEF = [
    ".........",
    "....#....",
    "...###...",
    "..#####..",
    ".#######.",
    ".##...##.",
    ".##...##.",
    ".##...##.",
    ".........",
];

let ROT_DEF = [
    ".............#.",
    "....##########.",
    "...###########.",
    "..###......###.",
    ".###......####.",
    ".##............",
    ".##.........##.",
    ".##.........##.",
    ".##.........##.",
    "............##.",
    ".####......###.",
    ".###......###..",
    ".###########...",
    ".##########....",
    ".#.............",
];

let MOON_ST_DEF = [
    "..............",
    ".......###....",
    "......##......",
    ".....##.......",
    "....###.......",
    "....###.......",
    "....###.......",
    "....###.......",
    "....###.......",
    "....###.......",
    ".....##.......",
    "......##......",
    ".......###....",
    "..............",
];

// Один отрисовщик на все значки статус-строки: правки из редактора лежат в
// MICON_CUSTOM и перекрывают вшитый арт.
// Ширина значка: у правки из редактора своя, у вшитой - по арту. Раньше в
// раскладке стояло жёсткое 21, и обрезанный полумесяц оставил бы после себя
// дыру в полстроки.
function st_icon_w(name, def) {
    let cu = MICON_CUSTOM[name];
    return cu ? cu.w : length(def[0]);
}

function draw_st_icon(x, y, name, def, col, flat) {
    let cu = MICON_CUSTOM[name];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c])
                    lcd_rect(x + c, y + r, 1, 1, flat ? col : cu.pal[cu.g[r][c] - 1]);
        return;
    }
    for (let r = 0; r < length(def); r++) {
        let row = def[r];
        for (let c = 0; c < length(row); c++)
            if (substr(row, c, 1) == "#") lcd_rect(x + c, y + r, 1, 1, col);
    }
}

function draw_wifi_status(x, y, col, flat) {
    let cu = MICON_CUSTOM["wifi_st"];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c])
                    lcd_rect(x + c, y + r, 1, 1, flat ? col : cu.pal[cu.g[r][c] - 1]);
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
function draw_eth_icon(x, y, col, flat) {
    let cu = MICON_CUSTOM["eth"];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c])
                    lcd_rect(x + c, y + r, 1, 1, flat ? col : cu.pal[cu.g[r][c] - 1]);
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
    "##.....########.............##",
    "##.....########.............##",
    "##.....##...................##",
    "##.....##.......##....##....##",
    "##.....######...###...##....##",
    "##.....######...####..##....##",
    "##.....##.......##.##.##....##",
    "##.....##.......##..####....##",
    "##.....##.......##...###....##",
    "##.....##.......##....##....##",
    "##..........................##",
    "##..........................##",
    "##..........................##",
    "##############################",
    "##############################",
];
// flat - как у соседних значков: свой рисунок либо в своей палитре, либо
// одним цветом. Параметр когда-то потеряли при копировании, и страница
// терминала падала у всех, кто нарисовал собственный значок Fn.
function draw_fn_icon(x, y, col, flat) {
    let cu = MICON_CUSTOM["fn"];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c])
                    lcd_rect(x + c, y + r, 1, 1, flat ? col : cu.pal[cu.g[r][c] - 1]);
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
let clash_pid = 0;

function clash_running() {
    if (!vpn_present()) return false;
    if (clash_pid > 0) {
        let c = fs.readfile(sprintf("/proc/%d/comm", clash_pid));
        if (c && trim(c) == "clash") return true;
        clash_pid = 0;
    }
    let p = fs.popen("pidof clash 2>/dev/null", "r");
    if (!p) return false;
    let out = trim(p.read("all") ?? "");
    p.close();
    if (out == "") return false;
    clash_pid = int(+split(out, " ")[0]);
    return clash_pid > 0;
}



function draw_status_row(y, o) {
    let d = st.data;
    let sig = sig_state();
    let bg = o?.bg ?? C.hdr;
    let mono = o?.mono;            /* ночной цвет или null */
    // Пустые деления берут оттенок своей же полосы - об этом заботятся
    // draw_sigbars и draw_batt_icon. Здесь серый больше не навязываем,
    // ночной монорежим по-прежнему задаёт свой цвет явно.
    let empty = o?.empty;

    // Откуда роутер берёт интернет (по netpri): Wi-Fi STA -> значок Wi-Fi,
    // кабель в WAN -> значок RJ45, модем -> ярлык технологии (4G/5G).
    let kind = o?.no_sig ? "" : uplink_kind();

    let has_modem = (d?.lte?.mode ?? "") != "" || int(+(d?.lte?.rsrp ?? 0)) != 0
                 || (d?.lte?.operator ?? "") != "" || int(+(d?.lte?.signal ?? 0)) > 0;

    // Деления сигнала занимают левый край только при живом модеме; иначе значок
    // аплинка (Wi-Fi/RJ45) съезжает в самый угол, а не висит с пустым отступом.
    let ux = has_modem ? 50 : 4;
    if (!o?.no_sig) {
        if (has_modem)
            draw_sigbars(4, y, sig.bars, mono ?? sig.color, empty);
        if (kind == "wifi") {
            // Значок Wi-Fi из редактируемой сетки wifi_st (правки видны вживую).
            // Зелёный, а не голубой: голубым идут «нейтральные» ярлыки аплинка
            // (RJ45, 4G/5G), а живая связь по Wi-Fi - это состояние «хорошо».
            draw_wifi_status(ux, y, mono ?? C.cyan, mono != null);
        } else if (kind == "wan") {
            draw_eth_icon(ux, y, mono ?? C.cyan, mono != null);
        } else {
            let rat = tcut(rat_label(d?.lte?.mode ?? ""), 4);
            if (rat != "" && rat != "-")
                lcd_text_thin(ux, y + 1, rat, mono ?? C.cyan, bg, 2);
        }
    }
    let rat = o?.no_sig ? "" : tcut(rat_label(d?.lte?.mode ?? ""), 4);
    let rat_x = 50;

    let tstr = clock_str();
    // Часы в шапке рисуем без зума (иначе крупноваты) - ширина по «сырому» кеглю.
    let t_x = int((LCD_W - tlen(tstr) * 12) / 2);

    // Конвертик встаёт сразу за ярлыком/значком аплинка: место зависит от его
    // ширины (значки Wi-Fi/RJ45 фиксированы). К часам ближе 8px не идём.
    if (!o?.no_env && int(d?.sms_new ?? 0) > 0) {
        let lead = kind == "wifi" ? 23 : (kind == "wan" ? 17
                 : (rat == "" || rat == "-" ? 0 : twpx(rat, 2)));
        let ex = (o?.no_sig ? 4 : rat_x) + (lead > 0 ? lead + 8 : 0);
        if (o?.time && ex + ENV_W + 8 > t_x) ex = t_x - ENV_W - 8;
        draw_env_icon(ex, y, 1, mono ? "#0A2A16" : null, mono);
    }

    if (o?.time)
        lcd_text_thin(t_x, y + 1, tstr, o?.time_color ?? C.white, bg, 2, "l", 1);

    let bat = d?.battery;
    // full = защёлка «заряд завершён» от коллектора: иконке это «полная
    // под адаптером» - зелёная рамка, мигать нечему (pct уже 100).
    let bchg = (bat?.charging || bat?.full) && !bat?.no_battery;
    let bpct = int(+(bat?.percent ?? 0));
    let b_w = 32, b_h = 16;
    // Без батареи (Almond+): её место у правого края отдаём под будильник/VPN/луну.
    let bat_x = HAS_BATTERY ? (LCD_W - 4 - b_w) : (LCD_W - 4);

    if (o?.pct && HAS_BATTERY) {
        let bstr = (bat?.no_battery || bpct < 0) ? "" : sprintf("%d", bpct);
        // Последние проценты - красным: предупреждение важнее стиля страницы,
        // поэтому цвет перебивает и ночную заставку.
        let pcol = (bpct <= 5 && !bchg && !bat?.no_battery)
                 ? C.red : (o?.time_color ?? C.white);
        lcd_text_thin(bat_x - 6 - twpx(bstr, 2), y + 1, bstr, pcol, bg, 2);
    }
    if (!o?.no_batt && HAS_BATTERY)
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
    // Правый край группы. 11, а не 14: замер показал, что плашка вставала в
    // 3 px от процентов, тогда как все прочие зазоры в строке по 6.
    let cur = st.alarm_on ? bell_x - 9 : bell_x + 11;
    if (st.vpn_on) {
        cur -= st_icon_w("vpn", VPN_ST_DEF);
        draw_st_icon(cur, y + 1, "vpn", VPN_ST_DEF, mono ?? "#FFFFFF", mono != null);
        cur -= 5;
    }
    if (night_now()) {
        cur -= st_icon_w("moon", MOON_ST_DEF);
        draw_st_icon(cur, y + 1, "moon", MOON_ST_DEF, mono ?? "#8B949E", mono != null);
    }
}

function draw_header(title, bg_c) {
    bg_c ??= C.hdr;
    lcd_rect(0, 0, LCD_W, HDR_H, bg_c);
    draw_status_row(3, { bg: bg_c, time: true, pct: true });
}

// Стрелка «назад» одна на весь интерфейс: центр задаём точно, ширину меряет
// рендерер. Раньше её ставили прикидкой «(ширина - 12) / 2», и на разных
// страницах она получалась разного размера.
// Вертикаль в полосе навигации: полоса 32 пикселя, но первые две строки -
// кант, поэтому середина ПОЛЯ, а не полосы. Высоту элемента передаём как
// есть: у текста это 7 пикселей на ступень кегля, у точек 7, у иконок 20.
function bar_y(h) {
    return BACK_Y + 2 + int((BACK_H - 2 - h) / 2);
}

function draw_back_arrow(xc, y, bg) {
    lcd_text_thin(xc, y ?? bar_y(14), "<", C.white, bg ?? C.widget, 2, "c", 1);
}

function draw_back() {
    lcd_rect(0, BACK_Y, LCD_W, BACK_H, C.widget);
    lcd_rect(0, BACK_Y, LCD_W, 2, C.border);
    draw_back_arrow(int(LCD_W / 2));
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
    // Значок поворота экрана со страницы «Экран».
    rot: ROT_DEF,
    // Домик координатора из списка соседей Zigbee.
    home: HOME_DEF,
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
               "#10B981", "#58A6FF", "#B180F0", "#484F58" ],
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
               "#10B981", "#58A6FF", "#B180F0", "#8B949E" ],
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
               "#10B981", "#58A6FF", "#484F58", "#8B949E" ],
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
                   "#10B981", "#58A6FF", "#B180F0", "#8B949E" ];
let ED_PAL = [ "#FFFFFF", "#F85149", "#FFA930", "#FFD866",
               "#10B981", "#58A6FF", "#B180F0", "#8B949E" ];

// Расширенный выбор цвета: перекрашивает текущий слот палитры.
let ED_COLORS = [
    "#FFFFFF", "#C9D1D9", "#8B949E", "#484F58", "#21262D", "#101418",
    "#FFB3AB", "#F85149", "#A40E26", "#FFC680", "#FFA930", "#B25E00",
    "#FFE28A", "#FFD866", "#D29922", "#7EE2A8", "#10B981", "#1F6F3D",
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

// Плитка меню - такой же виджет, как на заставке: мелкая строка сверху,
// название акцентным цветом посередине, мелкая строка снизу. Раньше название
// стояло вверху белым, а под ним теснились две служебные строки - меню жило
// своим языком, не похожим ни на карточки, ни на виджеты.
function draw_btn(b, act, title, subtitle, title_c, sub_c, bg_c, middle, icon, icon_c, top) {
    let pressed = (menu_pressed != null && menu_pressed == act);
    let bg = pressed ? C.press : (bg_c ?? C.widget);
    let o = pressed ? 2 : 0;
    let acc = icon_c ?? C.cyan;
    // В узкой плитке отступ меньше: лишние три пикселя решают, встанет
    // название крупным кеглем или уедет на ступень вниз.
    let ins = b.w < 100 ? 9 : 12;
    let tx = b.x + ins + o;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    astripe(b.x, b.y, b.h, pressed ? C.dim : acc);
    if (!pressed) dash_glow({ x: b.x, y: b.y, w: b.w, h: b.h },
                            { card: bg, mono: null }, acc);
    if (icon && MICONS_ON) {
        draw_micon(b.x + 12 + o, b.y + TILE_ICO_Y + o, icon, acc, 2);
        tx = b.x + 46 + o;
    }
    // Верхняя строка: чем этот пункт занят прямо сейчас. Если нечего сказать -
    // остаётся пустой, название всё равно стоит на своём месте.
    // Строки режем по ширине плитки, а не по общему числу знаков: иначе в
    // одинарной клетке текст вылезал на соседнюю.
    let room = b.w - (tx - b.x) - 6;
    let nch = int(room / 6);
    if (top)
        lcd_text(tx, b.y + 6 + o, tcut(top, nch), C.dim, "none", 1);
    // Название белое: акцент в меню несёт полоска слева и свечение, а цветной
    // заголовок делал экран пёстрым - шесть разноцветных слов подряд.
    text_fit2(tx, b.y + TILE_TTL_Y + o, title, title_c ?? C.white, "none", room);
    // Нижняя строка нужна, только если ей есть что добавить к верхней.
    let bot = middle ?? ((subtitle != top) ? subtitle : null);
    if (bot)
        lcd_text(tx, b.y + b.h - TILE_BOT_OFF + o, tcut(bot, nch), sub_c ?? C.gray, "none", 1);
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
            "...........B............",
            "........................",
            "...........B............",
            "........................",
            "....B..............B....",
            ".....B..AAAAAAA...B.....",
            ".......AAAAAAAAA........",
            "......AAAAAAAAAAA.......",
            ".....AAAAAAAAAAAAA......",
            ".....AAAAAAAAAAAAA......",
            ".....AAAAAAAAAAAAA......",
            "B.B..AAAAAAAAAAAAA..B.B.",
            ".....AAAAAAAAAAAAA......",
            ".....AAAAAAAAAAAAA......",
            ".....AAAAAAAAAAAAA......",
            "......AAAAAAAAAAA.......",
            ".......AAAAAAAAA........",
            "........AAAAAAA.........",
            ".....B............B.....",
            "....B..............B....",
            "...........B............",
            "........................",
            "...........B............",
            "........................",
        ],
        colors: { A: C.sun_core, B: C.sun_ray },
    },
    partly: {
        grid: [
            "........C...............",
            "........................",
            "........C...............",
            "...C.CCCCCC..C..........",
            "....CCCCCCCC............",
            "...CCCCCCCCCC...........",
            "...CCCCCCCCCC...........",
            "...CCCCCCCMMMB..........",
            "C.CCCCCCCMBBBBBBB.......",
            "...CCCCCMBBBBBBBBBB.....",
            "...CCCCMBBBBBBBBBBBB....",
            "....CCMBBBBBBBBBBBBBB...",
            ".....CMBBBBBBBBBBBBBB...",
            "...C..MMMMMMMMMMMMMM....",
            ".......MMMMMMMMMMMM.....",
            "........AAAAAAAAA.......",
            "........C.AAA...........",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, M: C.cloud_mid, C: C.sun_core, D: C.sun_ray },
    },
    cloud: {
        grid: [
            "........................",
            ".......HHHHH............",
            "......HBBBBBH...........",
            ".....HBBBBBBBH..........",
            "....HBBBBBBBBBH.........",
            "...HBBBBBBBBBBB...HHHH..",
            "..HBBBBBBBBBBBBB.HBBBBH.",
            ".HBBBBBBBBBBBBBBBBBBBBBH",
            ".HBBBBBBBBBBBBBBBBBBBBBB",
            ".BBBBBBBBBBBBBBBBBBBBBBB",
            ".BBBBBBBBBBBBBBBBBBBBBBB",
            "..BBBBBBBBBBBBBBBBBBBBBB",
            "..MBMBMBMBMBMBMBMBMBMBM.",
            "...MBMBMBMBMBMBMBMBMBM..",
            "....MAMAMAMAMAMAMAMAM...",
            "......AAAAAAAAAAAAAA....",
            "........AAAAAAAAAA......",
            "..........AAAAA.........",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, M: C.cloud_mid, H: C.cloud_hi },
    },
    rain: {
        grid: [
            "........................",
            ".......BBBBBBB..........",
            "......BBBBBBBBB.........",
            ".....BBBBBBBBBBBB.......",
            "....BBBBBBBBBBBBBBB.....",
            "....BBBBBBBBBBBBBBBB....",
            "....MMMMMMMMMMMMMMMM....",
            "....MMMMMMMMMMMMMMMM....",
            ".....AMAMAMAMAMAMAMA....",
            "......AAAAAAAAAAAAA.....",
            ".......MMMMMMMMMMM......",
            "........................",
            ".......C...C...C........",
            ".......C...C...C........",
            ".....C...C...C..........",
            ".....C...C...C..........",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
            "........................",
        ],
        colors: { A: C.cloud_shd, B: C.cloud_lit, M: C.cloud_mid, C: C.cyan },
    },
    snow: {
        grid: [
            "........................",
            "..........B.............",
            "........BBBBBBB.........",
            ".....BBBBBBBBBBBB.......",
            "....BBBBBBBBBBBBBBB.....",
            "....BBBBBBBBBBBBBBBB....",
            "....MMMMMMMMMMMMMMMM....",
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
        colors: { A: C.cloud_shd, B: C.cloud_lit, M: C.cloud_mid, C: C.white },
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
            "...MMMMMMMMMMMMMMMMMM...",
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
        colors: { A: C.cloud_shd, B: C.cloud_lit, M: C.cloud_mid, C: C.bolt },
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
    // Отредактированная в редакторе версия (wx_<ключ>) перекрывает вшитую.
    let cu = MICON_CUSTOM["wx_" + key];
    if (cu) {
        for (let r = 0; r < cu.h; r++)
            for (let c = 0; c < cu.w; c++)
                if (cu.g[r][c])
                    lcd_rect(x + c * cell, y + r * cell, cell, cell,
                             color_override ?? cu.pal[cu.g[r][c] - 1]);
        return;
    }
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

let NP_MINUS_W = IS_ALMONDPLUS ? 48 : 34;
let SCAN_BTN_H = IS_ALMONDPLUS ? 40 : 30;
let SCAN_BTN_Y = BACK_Y - SCAN_BTN_H - 6;

function netpri_btn(i) {
    if (!IS_ALMONDPLUS) return { x: GX, y: 32 + i * 44, w: GW, h: 40 };
    let v = vfit(GVT, SCAN_BTN_Y - GG, 3);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}


// Две кнопки скана - по диапазону, на фиксированном месте над «Назад»,
// чтобы их положение не зависело от числа аплинков.
function draw_scan_btns() {
    let ny = SCAN_BTN_Y, nh = SCAN_BTN_H;
    let sz = IS_ALMONDPLUS ? 2 : 1;
    let ty = ny + int((nh - fpx(sz)) / 2);
    lcd_rect(GX, ny, GCOL, nh, C.widget);
    astripe(GX, ny, nh, C.accent);
    lcd_text(GX + 14, ty, "+ Wi-Fi 2.4GHz", C.accent, C.widget, sz);
    lcd_rect(GX + GCOL + GG, ny, GCOL, nh, C.widget);
    astripe(GX + GCOL + GG, ny, nh, C.accent);
    lcd_text(GX + GCOL + GG + 14, ty, "+ Wi-Fi 5GHz", C.accent, C.widget, sz);
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
            astripe(b.x, b.y, b.h, rows[i][2]);
            lcd_text(b.x + 12, b.y + (IS_ALMONDPLUS ? 8 : 6), rows[i][0], C.gray, C.widget, 1);
            lcd_text(b.x + 12, b.y + (IS_ALMONDPLUS ? b.h - 34 : 20), rows[i][1], C.white, C.widget, 2);
        }
        draw_back();
        lcd_flush();
        return;
    }

    if (l == null) {
        empty_msg(tr("Reading uplinks..."), C.ontop, 2);
        draw_scan_btns();
        draw_back();
        lcd_flush();
        return;
    }
    if (length(l) == 0) {
        // Кнопки скана обязаны быть и здесь: после «забыть сеть» без SIM
        // список пуст, и без них со страницы некуда идти (issue #4).
        empty_msg(tr("No uplinks"), C.ontop_dim, 2);
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
        astripe(b.x, b.y, b.h, col);
        let t1 = IS_ALMONDPLUS ? b.y + 8 : b.y + 5;
        let t2 = IS_ALMONDPLUS ? b.y + b.h - 18 : b.y + 25;
        lcd_text(b.x + 12, t1, tcut(e.label ?? e.iface ?? "?", 16),
                 up ? C.white : C.gray, C.widget, 2);
        lcd_text(b.x + 12, t2, tcut(e.sub ?? e.type ?? "", 24),
                 C.gray, C.widget, 1);
        // У Wi-Fi-аплинка справа зона «забыть сеть»: минус за разделителем.
        // Отступ метрики и адреса одинаковый у всех карточек, чтобы колонка
        // не прыгала между строками.
        let wifi_card = (e.type ?? "") == "wifi";
        let roff = NP_MINUS_W;
        if (wifi_card) {
            lcd_rect(b.x + b.w - roff, b.y + 4, 1, b.h - 8, C.border);
            lcd_text(b.x + b.w - roff + (IS_ALMONDPLUS ? 14 : 10),
                     IS_ALMONDPLUS ? b.y + int((b.h - fpx(3)) / 2) : b.y + 10, "-", C.red, C.widget, 3);
        }
        let ip = e.ip ?? "";
        if (ip != "")
            lcd_text_r(b.x + b.w - 10 - roff, t2, ip, C.green, C.widget, 1);
        // Пока переключаемся - вместо метрики троеточие акцентом (мгновенный
        // отклик без попапа); как станет основным, вернётся зелёная метрика.
        let m = switching ? "..." : sprintf("%d", int(+(e.metric ?? 0)));
        lcd_text(b.x + b.w - 10 - roff - twpx(m, 2), t1, m,
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
            let pb = netpri_btn(cnt);
            let px = IS_ALMONDPLUS ? pb.x : 10, pw = IS_ALMONDPLUS ? pb.w : 300;
            let py = pb.y, ph = IS_ALMONDPLUS ? pb.h : 40;
            if (py + ph + 4 < SCAN_BTN_Y) {
                for (let dx = 0; dx < pw; dx += 6) {
                    lcd_rect(px + dx, py, 3, 1, C.dim);
                    lcd_rect(px + dx, py + ph - 1, 3, 1, C.dim);
                }
                for (let dy = 0; dy < ph; dy += 6) {
                    lcd_rect(px, py + dy, 1, 3, C.dim);
                    lcd_rect(px + pw - 1, py + dy, 1, 3, C.dim);
                }
                lcd_text(px + 12, py + (IS_ALMONDPLUS ? 8 : 6), tcut(sta_pending.ssid, 18), C.ontop, C.bg, 2);
                lcd_text(px + 12, py + (IS_ALMONDPLUS ? ph - 18 : 26), tr("connecting..."), C.ontop_dim, C.bg, 1);
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
let SMS_COLS  = IS_ALMONDPLUS ? int((GW - 32) / 6) : 46;
let SMS_LINES = IS_ALMONDPLUS ? int((BACK_Y - 6 - 62) / 12) : 12;
let SMS_TEXT_Y = IS_ALMONDPLUS ? 62 : 58;
let SMS_HDR_H = IS_ALMONDPLUS ? 26 : 22;

function sms_row(r) {
    if (!IS_ALMONDPLUS) return { x: GX, y: 32 + r * 44, w: GW, h: 40 };
    let v = vfit(GVT, GVB, SMS_ROWS);
    return { x: GX, y: v.y0 + r * v.step, w: GW, h: v.h };
}

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

// Хранилище мост берёт из аргумента, а не из настроек: без него sms_tool
// читает своё умолчание - SIM, а Quectel складывает входящие в память модема,
// и ящик выглядел пустым при девятнадцати сообщениях. Значение и умолчание -
// те же, что у вкладки «Входящие» в 5gmodem.
function sms_store() {
    let v = ucur ? ucur.get("5gmodem", "sms", "storage") : null;
    return (v != null && v != "") ? v : "ME";
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
    system("(/usr/share/5gmodem/smsbridge.sh recv " + sms_store() +
           " > " + SMS_CACHE + ".new 2>/dev/null" +
           " && mv " + SMS_CACHE + ".new " + SMS_CACHE + ") >/dev/null 2>&1 &");
}

// Удаление сообщения: мост smsbridge.sh delete <index>. Мультипарт = несколько
// слотов (idx), сносим все. Слоты модема независимы, порядок не важен. Сразу
// перечитываем ящик, чтобы список обновился.
function sms_delete(m) {
    if (!m || !fs.stat("/usr/share/5gmodem/smsbridge.sh")) return;
    let ids = type(m.idx) == "array" ? m.idx : [];
    let store = sms_store();
    let cmd = "";
    for (let ix in ids)
        cmd += sprintf("/usr/share/5gmodem/smsbridge.sh delete %d %s >/dev/null 2>&1; ", ix, store);
    if (cmd == "") return;
    system("( " + cmd + "/usr/share/5gmodem/smsbridge.sh recv " + store +
           " > " + SMS_CACHE + ".new" +
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
// Точки листания - те же, что на заставке: клетка 7x7, шаг 12, активная
// белым. Цифры «1/2» в полосе навигации читались как отладочная строка.
function draw_page_dots(xc, y, pg, pages, col) {
    let x0 = xc - int((pages * 12 - 5) / 2);
    for (let i = 0; i < pages; i++)
        lcd_rect(x0 + i * 12, y, 7, 7, i == pg ? (col ?? C.white) : C.dim);
}

function draw_back_pager(pg, pages, no_back) {
    lcd_rect(0, BACK_Y, LCD_W, BACK_H, C.widget);
    lcd_rect(0, BACK_Y, LCD_W, 2, C.border);
    // Стрелка возврата всегда в центре полосы - на любом экране в одном и том
    // же месте, её положение не зависит от того, есть на странице листалка или
    // нет. Стрелки листания - по краям, точки страниц - только в меню, где
    // центр свободен: на подстраницах их место занято возвратом, а счётчик
    // страниц там живёт в заголовке.
    if (!no_back)
        draw_back_arrow(int(LCD_W / 2));
    if (pages > 1) {
        lcd_text_thin(16, bar_y(14), "<<", C.white, C.widget, 2, "l", 1);
        lcd_text_thin(LCD_W - 40, bar_y(14), ">>", C.white, C.widget, 2, "l", 1);
        if (no_back) {
            let dy = bar_y(7);
            if (pages <= 10)
                draw_page_dots(int(LCD_W / 2), dy, pg, pages);
            else
                lcd_text_thin(int(LCD_W / 2), bar_y(14),
                              sprintf("%d/%d", pg + 1, pages), C.white, C.widget, 2, "c", 1);
        }
    }
}

// Куда попал палец в полосе навигации. Листание по кругу: со последней
// страницы «вперёд» ведёт на первую - раньше стрелка на краю просто гасла и
// нажатие пропадало впустую.
let PAGER_NONE = 0, PAGER_PREV = -1, PAGER_NEXT = 1, PAGER_BACK = 2;

function pager_hit(tx, ty, pages) {
    if (ty < BACK_Y) return PAGER_NONE;
    if (pages > 1 && tx < 70) return PAGER_PREV;
    if (pages > 1 && tx > LCD_W - 70) return PAGER_NEXT;
    return PAGER_BACK;
}

// Тап по точкам страниц (только меню): номер страницы или -1.
function pager_dot_hit(tx, ty, pages) {
    if (ty < BACK_Y || pages < 2 || pages > 10) return -1;
    let sw = pages * 12 - 5, x0 = int(LCD_W / 2) - int(sw / 2);
    if (tx < x0 - 16 || tx > x0 + sw + 16) return -1;
    let i = int((tx - x0 + 6) / 12);
    if (i < 0) i = 0;
    if (i >= pages) i = pages - 1;
    return i;
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
        empty_msg(msg, C.ontop, 1);
        draw_back();
        lcd_flush();
        return;
    }
    if (length(list) == 0) {
        empty_msg(tr("No messages"), C.ontop_dim, 2);
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
        let b = sms_row(r), y = b.y;
        let neu = exists(unread, m.key);
        let mr = IS_ALMONDPLUS ? GX + GW : 310;
        let t1 = IS_ALMONDPLUS ? y + 8 : y + 5;
        let t2 = IS_ALMONDPLUS ? y + b.h - 18 : y + 25;
        lcd_rect(b.x, y, b.w, b.h, C.widget);
        astripe(b.x, y, b.h, neu ? C.green : C.dim);
        // Красный минус справа за разделителем - как «забыть» у Wi-Fi.
        lcd_rect(mr - NP_MINUS_W, y + 4, 1, b.h - 8, C.border);
        lcd_text(mr - NP_MINUS_W + (IS_ALMONDPLUS ? 14 : 10),
                 IS_ALMONDPLUS ? y + int((b.h - fpx(3)) / 2) : y + 8, "-", C.red, C.widget, 3);
        let from = sms_from(m.sender), when = sms_short_time(m.time);
        lcd_text(20, t1, tcut(from, 16), neu ? C.white : C.gray, C.widget, 2);
        lcd_text(mr - NP_MINUS_W - twpx(when, 1) - 6, IS_ALMONDPLUS ? t1 + 8 : y + 8, when, C.dim, C.widget, 1);
        // Обрезаем до зоны минуса (справа), чтобы текст на него не налезал.
        lcd_text(20, t2, tcut(replace(m.text, /\n/g, " "), IS_ALMONDPLUS ? int((GW - NP_MINUS_W - 26) / 6) : 40),
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

    lcd_rect(GX, 28, GW, SMS_HDR_H, C.widget);
    lcd_text(GX + 12, 28 + int((SMS_HDR_H - 8) / 2) - 1, tcut(sms_from(m.sender), 24), C.white, C.widget, 1);
    lcd_text((IS_ALMONDPLUS ? GR : 310) - twpx(m.time, 1) - 8, 28 + int((SMS_HDR_H - 8) / 2) - 1,
             m.time, C.dim, C.widget, 1);

    let lines = sms_wrap(m.text, SMS_COLS);
    let pages = int((length(lines) + SMS_LINES - 1) / SMS_LINES);
    if (pages < 1) pages = 1;
    if (st.sms_tp >= pages) st.sms_tp = pages - 1;

    for (let i = 0; i < SMS_LINES; i++) {
        let li = st.sms_tp * SMS_LINES + i;
        if (li >= length(lines)) break;
        lcd_text(16, SMS_TEXT_Y + i * 12, lines[li], C.ontop_hi, C.bg, 1);
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

// Цвет температуры воздуха по шкале «тепло-холод» (как у температуры модема,
// но диапазон уличный, -30..+40): мороз - синий, прохладно - голубой, комфорт
// - зелёный, тепло - янтарь, жара - оранжевый/красный. По строке вида "+15°C".
// Единый цвет температуры по всему UI - строго на палитре виджетов
// (голубой/зелёный/оранжевый/красный, без янтаря). Динамический тепло-холод.
function weather_temp_col(ts) {
    let m = match(trim(ts ?? ""), /(-?[0-9]+)/);
    if (!m) return C.white;
    let t = int(m[1]);
    if (t <=  8) return C.cyan;      // холод/прохлада
    if (t <= 18) return C.green;     // комфорт
    if (t <= 30) return C.orange;    // тепло
    return C.red;                    // жара
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
    let bt = d?.battery, bp = int(+(bt?.percent ?? -1));
    let ns = int(d?.sms_new ?? 0);
    // Цвет акцентной полосы - не украшение, а правило: где у пункта есть
    // состояние, полоса показывает его (связь, заряд, доступность), где нет -
    // цвет раздела. Иначе всё меню было голубым и цвет не значил ничего.
    let sig = int(+(d?.lte?.signal ?? -1));
    let mcol = sig < 0 ? C.dim : (sig >= 60 ? C.green : (sig >= 30 ? C.orange : C.red));
    let bcol = bp < 0 ? C.dim : (bp >= 40 ? C.green : (bp >= 15 ? C.orange : C.red));
    let up = netpri_primary();
    let svc_ok = 0, svc_bad = 0;
    if (type(d?.services) == "array")
        for (let e in d.services) {
            if (e?.r == null) continue;
            if (int(+(e.r.ok ?? 0)) > 0) svc_ok++; else svc_bad++;
        }
    let scol = svc_bad > 0 ? C.red : (svc_ok > 0 ? C.green : C.dim);
    let vcol = !vpn_present() ? C.dim : (st.vpn_on == true ? C.green : C.gray);
    let TOOL = "#A371F7";     // инструменты: терминал, игры, Zigbee

    let it = [];
    push(it, { label: tr("Network"), top: up, sub: tr("uplink"), icon: "network",
               ic: (up != null && up != "" && up != "-") ? C.green : C.dim, act: "dashboard" });
    push(it, { label: tr("WiFi"), top: sprintf(tr("%d cl."), nc),
               sub: tr("AP short"), icon: "wifi",
               ic: nc > 0 ? C.green : C.cyan, act: "wifi" });
    push(it, { label: tr("Modem"), top: d?.lte?.operator, sub: modem_status(d?.lte),
               icon: "modem", ic: mcol, act: "lte" });
    // Состояние словом: в одинарную клетку «SSClash не установлен» не влезало
    // и уезжало на соседнюю плитку.
    push(it, { label: "VPN",
               sub: !vpn_present() ? tr("no package")
                                   : (st.vpn_on == true ? tr("vpn is on") : tr("vpn is off")),
               sc: vpn_present() ? C.gray : C.dim, ic: vcol, act: "vpn" });
    push(it, { label: tr("Ping"), sub: tr("check"), icon: "services", ic: scol, act: "services" });
    push(it, { label: tr("Speedtest"), sub: speedtest_sub(), icon: "bolt", ic: C.cyan, act: "speedtest" });
    push(it, { label: tr("Traffic"), sub: sprintf("R:%s T:%s", fmt_bytes(rx_last), fmt_bytes(tx_last)),
               icon: "traffic", ic: C.cyan, act: "traffic" });
    push(it, { label: tr("SMS"), sub: ns > 0 ? sprintf(tr("%d new"), ns) : tr("inbox"),
               sc: ns > 0 ? C.green : C.gray, icon: "sms", ic: ns > 0 ? C.green : C.gray, act: "sms" });
    push(it, { label: tr("Weather"), sub: weather_sub(), icon: "weather", ic: C.yellow, act: "weather" });
    push(it, { label: tr("Alarm"), sub: alarm_sub(), icon: "sound", ic: C.yellow, act: "alarm" });
    let bfull = (bt?.full || (bt?.charging && bp >= 100)) && !bt?.no_battery;
    if (HAS_BATTERY)
        push(it, { label: tr("Battery"), top: bp >= 0 ? sprintf("%d%%", bp) : "--",
                   sub: bfull ? tr("Plugged in") : (bt?.charging ? tr("charging") : tr("on battery")),
                   sc: bfull ? C.green : (bt?.charging ? bcol : C.gray), icon: "bolt", ic: bcol, act: "battery" });
    push(it, { label: tr("Terminal"), sub: tr("shell"), icon: "term", ic: TOOL, act: "term" });
    push(it, { label: tr("Zigbee"), sub: "EM357", icon: "zigbee", ic: TOOL, act: "zigbee" });
    push(it, { label: "Z-Wave", sub: "SD3503", icon: "zigbee", ic: "#D2A8FF", act: "zwave" });
    push(it, { label: tr("Games"), sub: games_sub(), icon: "game", ic: TOOL, act: "games" });
    push(it, { label: tr("Settings"),
               sub: HAS_LED ? tr("screen, LED, night") : tr("screen, night, update"), icon: "display",
               ic: C.gray, act: "settings" });
    push(it, { label: tr("Info"), top: fmt_uptime_c(d?.uptime), sub: tr("about short"),
               icon: "info", ic: C.gray, act: "info" });
    push(it, { label: tr("Power"), sub: tr("System"), sc: C.gray, icon: "reboot", ic: "#F0736B", act: "power" });
    return it;
}

function menu_pages() {
    return length(MENU_LAYOUT);
}

// Пункт по имени действия: раскладка задаёт места, menu_items - содержимое.
function menu_by_act(items, act) {
    for (let i = 0; i < length(items); i++)
        if (items[i].act == act) return items[i];
    return null;
}

// Определена ПОСЛЕ menu_pages/menu_items: в ucode нет hoisting, иначе меню
// упало бы, не найдя их.
function draw_menu() {
    if (st.halting) return;

    lcd_clear(C.bg);
    draw_header();
    let items = menu_items();
    let pages = menu_pages();
    if (st.mpg == null || st.mpg < 1 || st.mpg > pages) st.mpg = 1;
    let page = MENU_LAYOUT[st.mpg - 1];
    for (let s = 0; s < length(page); s++) {
        let t = page[s];
        let m = menu_by_act(items, t.act);
        if (m == null) continue;
        let b = menu_cell(t);
        draw_btn(b, t.act, m.label, m.sub, m.tc ?? C.white, m.sc ?? C.gray,
                 m.bg, m.mid, m.icon, m.ic, m.top ?? m.sub);
        if (m.line) lcd_rect(b.x, b.y, b.w, 2, m.line);
    }
    draw_back_pager(st.mpg - 1, pages, true);
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

let WQR_BOX = IS_ALMONDPLUS ? 100 : 62;
let WQR_SC = IS_ALMONDPLUS ? 3 : 2;

function qr_box(y) {
    return { x: GX + GW - WQR_BOX - 6, y: y + (IS_ALMONDPLUS ? 11 : 9), w: WQR_BOX, h: WQR_BOX };
}

// Имя сети кликабельно - тап открывает переименование. Ширину обрезаем до QR:
// иначе тап по коду попадал бы сюда же.
// Тумблер Wi-Fi: кнопка в общем стиле UI (sub-panel + акцентная полоса слева,
// как плитки меню), высотой во весь текстовый блок карточки, в фиксированной
// колонке слева от QR. Одна геометрия для отрисовки и тача - не налезает на
// код и стоит на сетке одинаково в обеих карточках. Определена ЗДЕСЬ (выше
// wifi_name_box/wifi_cli_rect и draw_wifi_page), т.к. ucode не хойстит.
function wifi_onoff_box(cy) {
    let qx = GX + (st.ox ?? 0) + GW - WQR_BOX - 6;   // левый край QR-бокса
    let w = IS_ALMONDPLUS ? 96 : 66;
    if (!IS_ALMONDPLUS) return { x: qx - 10 - w, y: cy + 18, w: w, h: 48 };
    return { x: qx - 14 - w, y: cy + 26, w: w, h: 72 };
}

function wifi_onoff_rect(cy) {
    return wifi_onoff_box(cy);
}

function wifi_name_box(y) {
    // Зона переименования - только по строке SSID и строго ЛЕВЕЕ кнопки-
    // тумблера, иначе тап по «ВКЛ/ВЫКЛ» открывал клавиатуру.
    let bx = wifi_onoff_box(y).x;
    let x = GX + (st.ox ?? 0) + 6;
    if (!IS_ALMONDPLUS) return { x: x, y: y + 18, w: bx - x - 8, h: 26 };
    return { x: x, y: y + 26, w: bx - x - 8, h: 34 };
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

// Тумблеры «Инверсия» и «Панель» отсюда убраны. Вторая таблица инициализации
// (kernel) роняет панель: картинка идёт полосами, тач перестаёт отвечать, и
// вернуть аппарат можно только по ssh. Держать такую кнопку в интерфейсе
// нельзя, а инверсия без неё осталась бы одинокой строкой.
// Три секции «подпись + ряд кнопок» делят полезную область поровну.
function dbg_sec_y(i)    { return GVT + i * int((GVB - GVT + GG) / 3); }
function dbg_sec_h()     { return int((GVB - GVT + GG) / 3) - GG - 12; }
let DBG_W4 = IS_ALMONDPLUS ? int((GW - 3 * GG) / 4) : 72;
let DBG_S4 = IS_ALMONDPLUS ? DBG_W4 + GG : 77;
let DBG_W5 = IS_ALMONDPLUS ? int((GW - 4 * GG) / 5) : 56;
let DBG_S5 = IS_ALMONDPLUS ? DBG_W5 + GG : 62;
function dbg_gamma_btn(i){ return { x: GX + i * DBG_S4, y: dbg_sec_y(0) + 12, w: DBG_W4, h: dbg_sec_h() }; }
function dbg_cabc_btn(i) { return { x: GX + i * DBG_S4, y: dbg_sec_y(1) + 12, w: DBG_W4, h: dbg_sec_h() }; }
function dbg_pwm_btn(i)  { return { x: GX + i * DBG_S5, y: dbg_sec_y(2) + 12, w: DBG_W5, h: dbg_sec_h() }; }

function draw_debug_page() {
    lcd_clear(C.bg);
    draw_header(tr("Debug"));
    let c = pancfg();

    lcd_text(12, IS_ALMONDPLUS ? dbg_sec_y(0) + 1 : 30, tr("GAMMA CURVE"), C.ontop, C.bg, 1);
    for (let i = 0; i < 4; i++) {
        let b = dbg_gamma_btn(i), sel = (c.gamma == i + 1);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", i + 1);
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    lcd_text(12, IS_ALMONDPLUS ? dbg_sec_y(1) + 1 : 88, tr("COLOR ENHANCE"), C.ontop, C.bg, 1);
    let cl = [ tr("off"), "UI", tr("photo"), tr("video") ];
    for (let i = 0; i < 4; i++) {
        let b = dbg_cabc_btn(i), sel = (c.cabc == i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, sel ? C.green : C.border);
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), cl[i],
                 sel ? C.white : C.gray, C.widget, 1);
    }

    lcd_text(12, IS_ALMONDPLUS ? dbg_sec_y(2) + 1 : 146, tr("BACKLIGHT PWM, HZ"), C.ontop, C.bg, 1);
    for (let i = 0; i < length(PWM_STEPS); i++) {
        let b = dbg_pwm_btn(i), sel = (c.hz == PWM_STEPS[i]);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, sel ? C.green : C.border);
        let t = sprintf("%d", PWM_STEPS[i]);
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), t,
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
let ED_BOX = IS_ALMONDPLUS ? 240 : 168;
let ED_CELL = 12;              // размер клетки - пересчитывается под иконку
let ED_X = IS_ALMONDPLUS ? GX : 8, ED_Y = IS_ALMONDPLUS ? GVT : 28;
let ED_RX = IS_ALMONDPLUS ? GX + ED_BOX + 12 : 192;
let ED_CLR_W = IS_ALMONDPLUS ? 90 : 62;
let ED_PICK_X = IS_ALMONDPLUS ? ED_RX + ED_CLR_W + 10 : 260;
let ED_PICK_W = IS_ALMONDPLUS ? 64 : 50;
let ED_PV_X = IS_ALMONDPLUS ? GR - 48 : 280;
let ED_PV_Y = IS_ALMONDPLUS ? ED_Y + 88 : 92;
let ED_CP_STEP = IS_ALMONDPLUS ? 54 : 28;
let ED_CP_ROW = IS_ALMONDPLUS ? 56 : 30;
let ED_CP_SZ = IS_ALMONDPLUS ? 48 : 26;
let ED_CP_PER = IS_ALMONDPLUS ? 8 : 6;
let ED_PK_STEP = IS_ALMONDPLUS ? 46 : 37;
let ED_PK_ROW = IS_ALMONDPLUS ? 48 : 34;
let ED_PK_SZ = IS_ALMONDPLUS ? 42 : 32;
let ED_PK_PER = IS_ALMONDPLUS ? 10 : 8;
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
    { name: "rot",      pal: 6 }, { name: "home",   pal: 6 },
];

// Иконки состояний погоды (WICONS) - в редактор. Конвертируем буквенную
// палитру каждой в цифровой формат {art, pal}, регистрируем под именем
// wx_<ключ> в MICONS и добавляем слот в редактор. Отредактированную версию
// (файл /etc/almond3s/icons/wx_<ключ>.txt -> MICON_CUSTOM) draw_weather_icon
// подхватывает поверх вшитой. Один раз на старте.
for (let wkey, wic in WICONS) {
    let pal = [], idx = {};
    for (let ch, col in wic.colors) {
        push(pal, col);
        idx[ch] = length(pal);
    }
    let art = [];
    for (let row in wic.grid) {
        let line = "";
        for (let c = 0; c < length(row); c++) {
            let ch = substr(row, c, 1);
            line += (ch == "." || idx[ch] == null) ? "." : ("" + idx[ch]);
        }
        push(art, line);
    }
    while (length(pal) < 8) push(pal, "#000000");
    MICONS["wx_" + wkey] = { art: art, pal: pal };
    push(ED_SLOTS, { name: "wx_" + wkey, pal: 1 });
}

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
    if (!IS_ALMONDPLUS) return { x: 192, y: GVT + i * 30, w: GR - 192, h: 26 };
    return { x: ED_RX, y: GVT + i * 40, w: GR - ED_RX, h: 34 };
}

function ed_pal_btn(i) {
    // 3x3: восемь цветов и ластик в правом нижнем углу
    if (!IS_ALMONDPLUS) return { x: 192 + (i % 3) * 28, y: 92 + int(i / 3) * 28, w: 24, h: 24 };
    return { x: ED_RX + (i % 3) * 40, y: ED_PV_Y + int(i / 3) * 40, w: 34, h: 34 };
}

function ed_cell_draw(r, c) {
    let v = ed_grid[r][c];
    lcd_rect(ED_X + c * ED_CELL + 1, ED_Y + r * ED_CELL + 1,
             ED_CELL - 2, ED_CELL - 2, v ? ED_PAL[v - 1] : C.btn);
}

function ed_preview() {
    let bs = IS_ALMONDPLUS ? 44 : 32, by = IS_ALMONDPLUS ? ED_PV_Y + 32 : 116;
    if (IS_ALMONDPLUS) lcd_rect(ED_PV_X - 2, ED_PV_Y, bs + 4, 32 + bs, C.bg);
    else lcd_rect(278, 92, 34, 84, C.bg);
    lcd_rect(ED_PV_X, by, bs, bs, C.widget);
    let ps = int((bs - 2) / (ed_w > ed_h ? ed_w : ed_h));
    if (ps < 1) ps = 1;
    let px0 = ED_PV_X + int((bs - ed_w * ps) / 2), py0 = by + int((bs - ed_h * ps) / 2);
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

// Пользовательские рисунки из /etc/almond3s/art подгружаем в MICON_CUSTOM (по
// имени art_NNN), чтобы их рисовал draw_micon и открывал ed_load - как обычные
// кастомные иконки, только живут они в своём каталоге.
function ed_art_load() {
    let out = [];
    let names = fs.lsdir("/etc/almond3s/art") ?? [];
    for (let f in names) {
        let m = match(f, /^(art_[0-9]+)\.txt$/);
        if (!m) continue;
        let raw = fs.readfile("/etc/almond3s/art/" + f);
        if (!raw) continue;
        let grid = [], pal = null, w = 0;
        for (let line in split(raw, "\n")) {
            let lm = match(line, /^colors:(.*)$/);
            if (lm) {
                pal = [];
                for (let pm in match(lm[1], /[0-9]=(#[0-9A-Fa-f]{6})/g)) push(pal, pm[1]);
                continue;
            }
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
        if (length(grid) >= 4 && w >= 4) {
            MICON_CUSTOM[m[1]] = { g: grid, w: w, h: length(grid),
                                   pal: (pal != null && length(pal) == 8) ? pal : ED_PAL_DEF };
            push(out, m[1]);
        }
    }
    return out;
}

// Слоты пикера: «+» (новый рисунок), вшитые иконки, пользовательские art-файлы.
function ed_pick_slots() {
    let s = [ { kind: "new" } ];
    for (let sl in ED_SLOTS) push(s, { kind: "icon", name: sl.name, pal: sl.pal });
    for (let a in ed_art_load()) push(s, { kind: "art", name: a });
    return s;
}

function draw_iconedit_page() {
    ed_init();
    lcd_clear(C.bg);
    draw_header(tr("Editor"));
    if (ed_cpick) {
        // Пикер цветов: расширенная палитра для текущего слота.
        lcd_text(ED_X, ED_Y, tr("Pick a color for the slot"), C.ontop, C.bg, 1);
        for (let i = 0; i < length(ED_COLORS); i++) {
            let px = ED_X + (i % ED_CP_PER) * ED_CP_STEP;
            let py = ED_Y + 14 + int(i / ED_CP_PER) * ED_CP_ROW;
            let cs = ED_CP_SZ;
            lcd_rect(px, py, cs, cs, ED_COLORS[i]);
            if (ed_color > 0 && ED_PAL[ed_color - 1] == ED_COLORS[i]) {
                lcd_rect(px, py, cs, 2, C.bg);
                lcd_rect(px, py + cs - 2, cs, 2, C.bg);
                lcd_rect(px, py, 2, cs, C.bg);
                lcd_rect(px + cs - 2, py, 2, cs, C.bg);
            }
        }
        draw_back();
        lcd_flush();
        return;
    }
    if (ed_pick) {
        // Пикер: «+» новый рисунок, вшитые иконки, пользовательские art-файлы.
        lcd_text(ED_X, ED_Y, tr("Pick an icon to edit"), C.ontop, C.bg, 1);
        let slots = ed_pick_slots();
        for (let i = 0; i < length(slots); i++) {
            let px = ED_X + (i % ED_PK_PER) * ED_PK_STEP;
            let py = ED_Y + 14 + int(i / ED_PK_PER) * ED_PK_ROW;
            let sl = slots[i], ss = ED_PK_SZ, hs = int(ss / 2);
            if (sl.kind == "new") {
                lcd_rect(px, py, ss, ss, C.btn);
                lcd_rect(px + hs - 2, py + 7, 4, ss - 14, C.green);
                lcd_rect(px + 7, py + hs - 2, ss - 14, 4, C.green);
                continue;
            }
            lcd_rect(px, py, ss, ss, ed_target == sl.name ? C.accent : C.btn);
            let d = micon_dim(sl.name);
            let sc = (d[0] * 2 <= ss - 2 && d[1] * 2 <= ss - 2) ? 2 : 1;
            draw_micon(px + int((ss - d[0] * sc) / 2), py + int((ss - d[1] * sc) / 2),
                       sl.name, sl.kind == "icon" ? ED_PAL[sl.pal - 1] : C.white, sc);
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
    astripe(b0.x, b0.y, b0.h, C.green);
    lcd_text_fit(b0.x + 14, mid_y(b0, 2), tr("Save"), C.white, "none", 2, b0.w - 24);
    let b1 = ed_btn(1);
    lcd_rect(b1.x, b1.y, ED_CLR_W, b1.h, C.widget);
    astripe(b1.x, b1.y, b1.h, C.red);
    lcd_text(b1.x + 10, mid_y(b1, 1), tr("Clr"), C.white, C.widget, 1);
    // Кнопка пикера: открыть иконку меню на правку.
    if (IS_ALMONDPLUS) {
        lcd_rect(ED_PICK_X, b1.y, ED_PICK_W, b1.h, C.btn);
        for (let dy = 0; dy < 3; dy++)
            for (let dx = 0; dx < 3; dx++)
                lcd_rect(ED_PICK_X + 11 + dx * 15, b1.y + 6 + dy * 8, 9, 4, C.cyan);
    } else {
        lcd_rect(260, b1.y, 50, 24, C.btn);
        for (let dy = 0; dy < 3; dy++)
            for (let dx = 0; dx < 3; dx++)
                lcd_rect(268 + dx * 12, b1.y + 5 + dy * 6, 6, 3, C.cyan);
    }
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
    for (let i = 0; i < 4; i++) {
        if (IS_ALMONDPLUS)
            lcd_rect(ED_PV_X + 2 + i * 10, ED_PV_Y + 2, 10, 22,
                     [ "#F85149", "#FFD866", "#10B981", "#58A6FF" ][i]);
        else
            lcd_rect(282 + i * 7, 94, 7, 16,
                     [ "#F85149", "#FFD866", "#10B981", "#58A6FF" ][i]);
    }
    lcd_text(ED_RX, IS_ALMONDPLUS ? GVB - 28 : 180, ed_target != null
             ? sprintf("%s: %s", tr("editing"), ed_target)
             : "/etc/almond3s/art", C.ontop_dim, C.bg, 1);
    if (ed_saved != "")
        lcd_text(ED_RX, IS_ALMONDPLUS ? GVB - 14 : 192, ed_saved, C.ontop, C.bg, 1);
    draw_back();
    lcd_flush();
}

function dbg_open_btn() { return { x: GX, y: 176, w: 160, h: 26 }; }

// Тёплый фильтр: вечернее наложение. Убавляет синий и чуть зелёный уже при
// передаче на панель, поэтому это настоящий тёплый свет, а не нарисованная
// поверх плёнка - исходный кадр не трогается.
let WARM_STEPS = [ 0, 30, 60, 100 ];

function warm_btn()   { return disp_half(2, false); }
function radius_btn() { return disp_half(2, true); }
// Свечение угла карточек - общий тумблер на весь интерфейс.
function glow_btn()   { return disp_half(3, false); }

function warm_cfg() {
    let v = ucur ? ucur.get("almond3s", "display", "warm") : null;
    v = (v == null || v == "") ? 0 : int(+v);
    for (let i = 0; i < length(WARM_STEPS); i++)
        if (WARM_STEPS[i] == v) return v;
    return 0;
}

// Уровень тепла, положенный ПРЯМО СЕЙЧАС. Ночью со своим значением побеждает
// оно, иначе дневное с «Экрана». Раньше backlight_write в конце безусловно
// звал warm_apply() с дневным уровнем - и ночное тепло, только что выставленное
// на странице «Ночь», тут же затиралось нулём. Сюда же приходит любое
// пробуждение экрана и смена яркости, так что затиралось оно всю ночь.
function warm_now() {
    let n = nwarm_cfg();
    return (night_now() && n > 0) ? n : warm_cfg();
}

function warm_apply() {
    system(sprintf("almond3s-lcd warm %d >/dev/null 2>&1", warm_now()));
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
// Акцент по тому же правилу, что и в главном меню: у «Диода» есть состояние,
// и полоса его показывает, у остальных - цвет раздела; отладка панели серая
// как служебная.
let SETTINGS = [
    { label: "Display",      sub: "brightness, warm, language", act: "display", ic: "#58A6FF" },
    { label: "Saver",        sub: "timeout and look",           act: "saver",   ic: "#A371F7" },
    { label: "Night",        sub: "schedule and actions",       act: "night",   ic: "#39C5CF" },
    { label: "LED",          sub: "above the screen",           act: "led" },
    { label: "Editor",       sub: "pixel art",                  act: "iconedit", ic: "#DB61A2" },
    { label: "Update",       sub: "packages",                   act: "update",  ic: "#3FB950" },
];
// Нет диода над экраном (Almond+) - строку «Диод» из настроек убираем.
if (!HAS_LED) {
    let s = [];
    for (let r in SETTINGS) if (r.act != "led") push(s, r);
    SETTINGS = s;
}
// Плитка «Дебаг» из настроек убрана: страница служебная, снаружи она путала.
// Сама страница жива - echo debug > /tmp/.lcd_goto.

// Две колонки по сетке: плитка 148x51 - вдвое крупнее прежней строки, в неё
// влезает заголовок нормального кегля, и попасть пальцем куда легче.
function settings_btn(i) {
    let n = length(SETTINGS);
    let h = gcard_h(IS_ALMONDPLUS ? int((n + 1) / 2) : 3);
    let w = GCOL;
    if (IS_ALMONDPLUS && i == n - 1 && (n % 2) == 1) w = GW;
    return { x: GX + (i % 2) * (GCOL + GG), y: GVT + int(i / 2) * (h + GG),
             w: w, h: h };
}

let UPD_SCRIPT = "almond_update.sh";

function upd_file(key) {
    return "/tmp/almond_upd_" + key + ".json";
}

function upd_read(key) {
    let raw = fs.readfile(upd_file(key));
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
}

function upd_ver_disp(v) {
    v = "" + (v ?? "?");
    let c = substr(v, 0, 1);
    return (c == "v" || c == "V") ? substr(v, 1) : v;
}

function upd_avail(j) {
    return j != null && (j.update_available == 1 || j.update_available == true);
}

function upd_err_msg(code) {
    if (code == "no_build") return tr("No build for your OpenWrt");
    if (code == "download") return tr("Download failed");
    if (code == "unchanged") return tr("Version unchanged");
    if (code == "asset_pending") return tr("Build not ready yet");
    return tr("Could not check");
}

function upd_run(action, key) {
    system(sprintf("setsid %s/%s %s %s >/dev/null 2>&1 &", SCRIPTS, UPD_SCRIPT, action, key));
}

// Наши пакеты + 5gmodem (если установлен). kmod помечен - у него особый путь:
// предупреждение и перезагрузка после установки.
function upd_pkgs() {
    let a = [
        { key: "kmod", label: tr("Almond kmod"), kmod: true },
        { key: "lcd",  label: tr("Almond lcd") },
        { key: "nes",  label: tr("Almond nes") },
    ];
    if (fs.stat("/usr/share/5gmodem/update.sh"))
        push(a, { key: "5g", label: "5gmodem" });
    return a;
}

// Фоновая проверка всех пакетов при заходе на страницу: пишем running сразу
// (мгновенный отклик), скрипты уходят в setsid и рендер не держат. Все три наши
// пакета проверяются одним запросом к API (check almond), 5gmodem - отдельно.
// Без force не частим - не чаще раза в 8 секунд.
// Пакет «занят», если у него идёт операция (свежая метка running). Метку
// старше 4 минут считаем зависшей и не блокируем ей проверку.
function upd_busy(key) {
    let j = upd_read(key);
    if (!(j != null && j.running == true)) return false;
    let f = fs.stat(upd_file(key));
    return f && (time() - f.mtime) < 240;
}

function upd_kick_all(force) {
    if (!force && (time() - (st.upd_kick_ts ?? 0)) < 8) return;
    // Не мешаем идущей установке/проверке: не перезаписываем её статус и не
    // дёргаем check параллельно (иначе 5gmodem update.sh конфликтует сам с
    // собой, а строка мигает между «Устанавливаю…» и «Проверяю…»).
    let busy_almond = upd_busy("kmod") || upd_busy("lcd") || upd_busy("nes");
    if (!busy_almond) {
        st.upd_kick_ts = time();
        for (let k in [ "kmod", "lcd", "nes" ])
            fs.writefile(upd_file(k), '{"running":true,"act":"check"}');
        upd_run("check", "almond");
    }
    if (fs.stat("/usr/share/5gmodem/update.sh") && !upd_busy("5g")) {
        fs.writefile(upd_file("5g"), '{"running":true,"act":"check"}');
        upd_run("check", "5g");
    }
}

// Тап по строке пакета открывает релиз-ноты его репозитория. Наши пакеты и
// 5gmodem живут в разных репах - src их различает. Старый файл сносим, чтобы
// страница показала «Загрузка…», пока фоновый фетч не принесёт свежие.
function upd_kick_notes(src) {
    fs.unlink("/tmp/almond_notes_" + src + ".txt");
    upd_run("notes", src);
}

function draw_settings_page() {
    lcd_clear(C.bg);
    draw_header(tr("Settings"));

    for (let i = 0; i < length(SETTINGS); i++) {
        let b = settings_btn(i);
        let acc = SETTINGS[i].ic ?? C.cyan;
        let sub = tr(SETTINGS[i].sub);
        if (SETTINGS[i].act == "led") {
            let lc = led_cfg();
            if (led_blinking) { sub = tr("blinking"); acc = C.orange; }
            else {
                sub = lc.on ? tr("on") : tr("off");
                if (lc.sms) sub += ", " + tr("blink on SMS");
                // Мигание по SMS - тоже включённое состояние: диод сам погашен,
                // но при новом сообщении оживёт, и полоса должна это показывать.
                acc = lc.on ? C.green : (lc.sms ? C.orange : C.gray);
            }
        }
        gcard(b.x, b.y, b.w, b.h, acc);
        let blk = IS_ALMONDPLUS ? fpx(2) + 12 : 30;
        let ty = b.y + int((b.h - blk) / 2);
        lcd_text(b.x + 12, ty, tr(SETTINGS[i].label), C.white, C.widget, 2);
        lcd_text(b.x + 12, ty + (IS_ALMONDPLUS ? fpx(2) + 4 : 22),
                 tcut(sub, IS_ALMONDPLUS ? int((b.w - 24) / 6) : 21), C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

// Обновление: две карточки - наши пакеты Almond и модем 5G. Работа идёт через
// almond_update.sh, статус ui.uc читает из /tmp одним форматом. Карточка 5G
// появляется только если на аппарате есть luci-app-5gmodem с его апдейтером.
// Ряды-строки списка + нижняя кнопка «Проверить»: равные веса, ровно
// заполняют полезную область по сетке.
function upd_rows() {
    let n = length(upd_pkgs());
    let w = [];
    for (let i = 0; i <= n; i++) push(w, 1);   // n пакетов + ряд кнопок
    return stack_rects(w);
}

// Две кнопки в ряд по сетке. idx 0 - левая.
function upd_row_btn(r, idx) {
    let bw = int((GW - GG) / 2);
    let x = (idx == 0) ? GX : (GX + bw + GG);
    let w = (idx == 0) ? bw : (GX + GW - x);
    return { x: x, y: r.y, w: w, h: r.h };
}

// Пометить пакет «в работе» (мгновенный отклик): act различает проверку и
// установку - от него зависит подпись в строке.
function upd_mark(key, act) {
    fs.writefile(upd_file(key), sprintf('{"running":true,"act":"%s"}', act));
}

function upd_any_avail() {
    for (let p in upd_pkgs())
        if (upd_avail(upd_read(p.key))) return true;
    return false;
}

// Правая колонка строки: состояние пакета одной подписью и цвет полоски.
function upd_row_state(j) {
    if (j != null && j.running == true)
        return { acc: C.orange, col: C.orange,
                 txt: (j.act == "install") ? tr("Installing…") : tr("Checking…") };
    if (j == null)          return { acc: C.dim, txt: tr("…"), col: C.gray };
    if (j.success == false) return { acc: C.red, txt: upd_err_msg(j.error), col: C.red };
    if (upd_avail(j))       return { acc: C.green,
                                     txt: sprintf("%s → %s", upd_ver_disp(j.current), upd_ver_disp(j.latest)),
                                     col: C.green };
    return { acc: C.cyan, txt: upd_ver_disp(j.current), col: C.gray };
}

// Модалка-предупреждение перед установкой модуля ядра.
function upd_confirm_geo() {
    let w = IS_ALMONDPLUS ? 400 : 288, h = IS_ALMONDPLUS ? 200 : 128;
    let x = int((LCD_W - w) / 2), y = int((LCD_H - h) / 2);
    let bw = IS_ALMONDPLUS ? 160 : 122, bh = IS_ALMONDPLUS ? 48 : 34, by = y + h - bh - 12;
    return { x: x, y: y, w: w, h: h,
             ok:     { x: x + 16,          y: by, w: bw, h: bh },
             cancel: { x: x + w - bw - 16, y: by, w: bw, h: bh } };
}

function draw_upd_confirm() {
    let g = upd_confirm_geo();
    lcd_rect(g.x - 2, g.y - 2, g.w + 4, g.h + 4, C.red);
    lcd_rect(g.x, g.y, g.w, g.h, C.widget);
    let ap = IS_ALMONDPLUS;
    lcd_text_c(LCD_W / 2, g.y + (ap ? 20 : 14), tr("Kernel module"), C.orange, C.widget, 2);
    lcd_text_c(LCD_W / 2, g.y + (ap ? 60 : 42), tr("Router will reboot"), C.white, C.widget, 1);
    lcd_text_c(LCD_W / 2, g.y + (ap ? 78 : 58), tr("right after install"), C.white, C.widget, 1);
    gcard(g.ok.x, g.ok.y, g.ok.w, g.ok.h, C.green);
    lcd_text_c(g.ok.x + int(g.ok.w / 2), g.ok.y + int((g.ok.h - fpx(2)) / 2), tr("OK"), C.white, C.widget, 2);
    gcard(g.cancel.x, g.cancel.y, g.cancel.w, g.cancel.h, C.dim);
    lcd_text_c(g.cancel.x + int(g.cancel.w / 2), g.cancel.y + int((g.cancel.h - fpx(2)) / 2),
               tr("Cancel"), C.gray, C.widget, 2);
}

function draw_update_page() {
    lcd_clear(C.bg);
    draw_header(tr("Update"));
    let pk = upd_pkgs(), n = length(pk), R = upd_rows();
    for (let i = 0; i < n; i++) {
        let p = pk[i], r = R[i];
        let s = upd_row_state(upd_read(p.key));
        gcard(r.x, r.y, r.w, r.h, s.acc);
        let ty = r.y + int((r.h - fpx(2)) / 2);
        lcd_text(r.x + 13, ty, p.label, C.white, C.widget, 2);
        lcd_text_r(r.x + r.w - 12, IS_ALMONDPLUS ? mid_y(r, 1) : ty, tcut(s.txt, IS_ALMONDPLUS ? 40 : 22),
                   s.col, C.widget, 1);
    }
    // Две кнопки в ряд: Проверить и Обновить (обновляет все доступные).
    let br = R[n];
    let cb = upd_row_btn(br, 0);
    gcard(cb.x, cb.y, cb.w, cb.h, C.cyan);
    lcd_text_c(cb.x + int(cb.w / 2), cb.y + int((cb.h - fpx(2)) / 2), tr("Check"), C.white, C.widget, 2);
    let any = upd_any_avail();
    let ub = upd_row_btn(br, 1);
    gcard(ub.x, ub.y, ub.w, ub.h, any ? C.green : C.dim);
    lcd_text_c(ub.x + int(ub.w / 2), ub.y + int((ub.h - fpx(2)) / 2), tr("Install"),
               any ? C.white : C.gray, C.widget, 2);

    if (st.upd_confirm) draw_upd_confirm();
    draw_back();
    lcd_flush();
}

function relnotes_read(src) {
    return fs.readfile("/tmp/almond_notes_" + src + ".txt");
}

function draw_relnotes_page() {
    let src = st.notes_src ?? "almond";
    lcd_clear(C.bg);
    draw_header(tr("Release notes"));
    let raw = relnotes_read(src);
    if (raw == null) {
        lcd_text_c(int(LCD_W / 2), 108, tr("Loading…"), C.gray, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }
    if (trim(raw) == "__ERR__") {
        lcd_text_c(int(LCD_W / 2), 108, tr("Could not load"), C.red, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }
    let nl = index(raw, "\n");
    let tag = (nl >= 0) ? substr(raw, 0, nl) : raw;
    let body = (nl >= 0) ? substr(raw, nl + 1) : "";
    lcd_rect(GX, 28, GW, SMS_HDR_H, C.widget);
    astripe(GX, 28, SMS_HDR_H, C.green);
    lcd_text(GX + 13, 28 + int((SMS_HDR_H - 8) / 2) - 1, tcut(tag, 24), C.green, C.widget, 1);

    let lines = sms_wrap(body, SMS_COLS);
    let pages = int((length(lines) + SMS_LINES - 1) / SMS_LINES);
    if (pages < 1) pages = 1;
    if ((st.notes_pg ?? 0) >= pages) st.notes_pg = pages - 1;
    for (let i = 0; i < SMS_LINES; i++) {
        let li = (st.notes_pg ?? 0) * SMS_LINES + i;
        if (li >= length(lines)) break;
        lcd_text(16, SMS_TEXT_Y + i * 12, lines[li], C.ontop_hi, C.bg, 1);
    }
    draw_back_pager(st.notes_pg ?? 0, pages);
    lcd_flush();
}

// Питание было модалкой: красное окно со своим циклом ожидания касания, то есть
// отдельной механикой на весь интерфейс. Теперь это обычная страница - две
// крупные карточки на сетке, а роль «Отмены» играет общая кнопка «назад».
// На Almond+ ни сброса модема (модем внешний, USB), ни выключения (питание не
// снять, устройство и не выключают) - оставляем только перезагрузку роутера.
function power_items() {
    if (IS_ALMONDPLUS)
        return [ { label: tr("Restart"), sub: tr("Reboot the router"), col: "#F0736B", act: "reboot" } ];
    return [
        { label: tr("Modem Reset"), sub: tr("LTE restart"), col: C.orange, act: "modem" },
        { label: tr("Restart"), sub: tr("Reboot the router"), col: "#F0736B", act: "reboot" },
        { label: tr("Shut down"), sub: tr("Unplug charger first"), col: C.red, act: "poweroff" },
    ];
}

function power_btn(i) {
    let n = length(power_items());
    let h = gcard_h(n);
    return { x: GX, y: GVT + i * (h + GG), w: GW, h: h };
}

function draw_power_page() {
    lcd_clear(C.bg);
    draw_header(tr("POWER"));
    // Порядок - по радикальности: сперва трогаем только модем, потом весь
    // аппарат, в конце выключение. Цвет полосы идёт той же лесенкой.
    let items = power_items();
    for (let i = 0; i < length(items); i++) {
        let b = power_btn(i);
        let pressed = (st.pwr_press == i);
        gcard(b.x, b.y, b.w, b.h, items[i].col);
        if (pressed) lcd_rect(b.x + 3, b.y, b.w - 3, b.h, C.press);
        let bgc = pressed ? C.press : C.widget;
        let blk = IS_ALMONDPLUS ? fpx(3) + 14 : 34;
        let ty = b.y + int((b.h - blk) / 2);
        lcd_text(b.x + 13, ty, items[i].label, C.white, bgc, 3);
        lcd_text(b.x + 13, ty + (IS_ALMONDPLUS ? fpx(3) + 6 : 26), items[i].sub, C.gray, bgc, 1);
    }
    draw_back();
    lcd_flush();
}

function draw_display_page() {
    lcd_clear(C.bg);
    draw_header(tr("Display"));

    let rb = rot_btn();
    gcard(rb.x, rb.y, rb.w, rb.h, rot_cfg() ? C.green : C.dim);
    draw_st_icon(rb.x + int((rb.w - st_icon_w("rot", ROT_DEF)) / 2),
                 rb.y + int((rb.h - 15) / 2), "rot", ROT_DEF,
                 rot_cfg() ? C.green : C.gray, true);

    // Язык - компактная кнопка: флаг слева, код справа, без слова «Язык».
    let ru = (lang() == "ru");
    let lb = lang_btn();
    gcard(lb.x, lb.y, lb.w, lb.h, C.cyan);
    draw_flag(lb.x + 10, lb.y + int((lb.h - 10) / 2), ru ? "ru" : "en");
    lcd_text_r(lb.x + lb.w - 12, mid_y(lb, 1), ru ? "RU" : "EN", C.cyan, C.widget, 1);

    // Шрифт интерфейса: тап перебирает список по кругу.
    let fb = font_btn(), ff = (FONT_MODE > 0);
    gcard(fb.x, fb.y, fb.w, fb.h, ff ? C.green : C.border);
    lcd_text(fb.x + 12, mid_y(fb, 1), tr("Font"), C.white, C.widget, 1);
    lcd_text_r(fb.x + fb.w - 10, mid_y(fb, 1), tr(FONTS[FONT_MODE].label),
             ff ? C.green : C.gray, C.widget, 1);

    // Фон-подложка и тема - две колонки сетки.
    let tb = theme_btn();
    let dark = (THEME == "dark");
    gcard(tb.x, tb.y, tb.w, tb.h, dark ? C.gray : C.cyan);
    lcd_text(tb.x + 12, mid_y(tb, 1), tr("Theme"), C.white, C.widget, 1);
    lcd_text_r(tb.x + tb.w - 10, mid_y(tb, 1), dark ? tr("Dark") : tr("Light"),
               dark ? C.gray : C.cyan, C.widget, 1);

    let gb = bg_btn();
    let lt = (BG_TINT == "light");
    let bacc = !GRAD_ON ? C.dim : (lt ? C.cyan : C.gray);
    gcard(gb.x, gb.y, gb.w, gb.h, bacc);
    lcd_text(gb.x + 12, mid_y(gb, 1), tr("Background"), C.white, C.widget, 1);
    lcd_text_r(gb.x + gb.w - 10, mid_y(gb, 1),
               !GRAD_ON ? tr("off") : (lt ? tr("Light") : tr("Dark")),
               bacc, C.widget, 1);

    // Тёплый свет и скругление углов - вторым рядом, по две колонки сетки.
    let wb = warm_btn(), wv = warm_cfg();
    gcard(wb.x, wb.y, wb.w, wb.h, wv ? "#F0A868" : C.dim);
    lcd_text(wb.x + 12, mid_y(wb, 1), tr("Warm"), C.white, C.widget, 1);
    lcd_text_r(wb.x + wb.w - 10, mid_y(wb, 1), warm_label(),
               wv ? "#F0A868" : C.gray, C.widget, 1);

    let cb = radius_btn();
    gcard(cb.x, cb.y, cb.w, cb.h, RADIUS ? C.cyan : C.dim);
    lcd_text(cb.x + 12, mid_y(cb, 1), tr("Corners"), C.white, C.widget, 1);
    lcd_text_r(cb.x + cb.w - 10, mid_y(cb, 1),
               RADIUS ? sprintf("%d px", RADIUS) : tr("off"),
               RADIUS ? C.cyan : C.gray, C.widget, 1);

    let wb2 = glow_btn();
    gcard(wb2.x, wb2.y, wb2.w, wb2.h, GLOW_ON ? C.cyan : C.dim);
    lcd_text(wb2.x + 12, mid_y(wb2, 1), tr("Glow"), C.white, C.widget, 1);
    lcd_text_r(wb2.x + wb2.w - 10, mid_y(wb2, 1), GLOW_ON ? tr("on") : tr("off"),
               GLOW_ON ? C.cyan : C.gray, C.widget, 1);

    // Тумблер боковых акцентных полос - рядом со свечением.
    let bsb = bars_btn();
    gcard(bsb.x, bsb.y, bsb.w, bsb.h, BARS_ON ? C.cyan : C.dim);
    lcd_text(bsb.x + 12, mid_y(bsb, 1), tr("Bars"), C.white, C.widget, 1);
    lcd_text_r(bsb.x + bsb.w - 10, mid_y(bsb, 1), BARS_ON ? tr("on") : tr("off"),
               BARS_ON ? C.cyan : C.gray, C.widget, 1);

    // Яркость: семь шагов, выбранный подсвечен.
    let bp = bright_cfg();
    if (IS_ALMONDPLUS) lcd_text(GX + 4, mid_y(disp_row(4), 1), tr("LIGHT"), C.ontop, C.bg, 1);
    else lcd_text(GX + 4, GVB - 38, tr("LIGHT"), C.ontop, C.bg, 1);
    for (let i = 0; i < length(BRIGHT_STEPS); i++) {
        let b = bright_btn(i), sel = (BRIGHT_STEPS[i] == bp);
        gcard(b.x, b.y, b.w, b.h, sel ? C.green : C.border);
        let t = sprintf("%d%%", BRIGHT_STEPS[i]);
        // Строка шрифта - 8 пикселей на размер: центр клетки считаем от него,
        // иначе цифра прижимается к верху (кнопка стала ниже, отступ остался).
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), t,
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
    gcard(sb.x, sb.y, sb.w, sb.h, C.cyan);
    lcd_text(sb.x + 12, sb.y + 9, tr("SCREENSAVER AFTER"), C.gray, C.widget, 1);
    lcd_text(sb.x + 12, sb.y + (IS_ALMONDPLUS ? 24 : 22), saver_label(saver_cfg()), C.white, C.widget, 2);
    gcard(z.x, z.y, z.w, z.h, C.border);
    draw_pm(z, true, C.accent);
    gcard(a.x, a.y, a.w, a.h, C.border);
    draw_pm(a, false, C.accent);

    let stl = saver_style();
    lcd_text(GX + 4, GVT + (IS_ALMONDPLUS ? 64 : 50), tr("VIEW"), C.ontop, C.bg, 1);
    for (let i = 0; i < length(SAVER_STYLES); i++) {
        let b = style_btn(i), sel = (SAVER_STYLES[i] == stl);
        gcard(b.x, b.y, b.w, b.h, sel ? C.green : C.border);
        let t = style_label(SAVER_STYLES[i]);
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    let hb = svshift_btn(), on = burnin_cfg();
    gcard(hb.x, hb.y, hb.w, hb.h, on ? C.green : C.dim);
    lcd_text(hb.x + 10, mid_y(hb, 2), tr("Shift"), C.white, C.widget, 2);
    lcd_text_r(hb.x + hb.w - 10, mid_y(hb, 2), on ? tr("on") : tr("off"),
               on ? C.green : C.gray, C.widget, 2);

    // Редактор «Своих виджетов»: четвёртая страница карусели «Виджеты».
    let cb = svcust_btn();
    gcard(cb.x, cb.y, cb.w, cb.h, C.cyan);
    lcd_text_c(cb.x + int(cb.w / 2), mid_y(cb, 1), tr("Custom widgets"),
               C.white, C.widget, 1);

    // Ночной режим: зелёная тусклая заставка по расписанию. Тап открывает
    // часы и включает, если был выключен.
    draw_back();
    lcd_flush();
}

// Часы ночного режима - отдельной страницей: открывается тапом по «Ночь».
function led_row(i) {
    return led_rgb() ? rows_rect(i, 3, 56) : rows_rect(i, 2, 80);
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
      args: "440 500 0 30 440 500 0 30 440 500 0 30 349 375 523 125 440 500 0 30 349 375 523 125 440 650 0 60 659 500 0 30 659 500 0 30 659 500 0 30 698 375 523 125 415 500 349 375 523 125 440 650 0 60 880 500 440 375 0 30 440 125 880 500 831 375 784 125 740 60 698 60 740 500" },
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
    // Три полки полезной области: время с мелодией, режим/повтор, громкость с
    // тумблером. Координаты считаем от сетки, иначе низ страницы пустовал.
    let AR = stack_rects([ 100, 32, 44 ]);
    let half = int((GCOL - GG) / 2);          // половинки левой колонки
    let bh = 26;                              // кнопки +/- у часов и минут
    return {
        hup:  { x: GX,          y: AR[0].y,               w: half, h: bh },
        hdn:  { x: GX,          y: AR[0].y + AR[0].h - bh, w: half, h: bh },
        mup:  { x: GX + half + GG, y: AR[0].y,               w: half, h: bh },
        mdn:  { x: GX + half + GG, y: AR[0].y + AR[0].h - bh, w: half, h: bh },
        // Мелодия справа: одна строка "< имя >", тап по имени = проигрывание.
        sprev:{ x: GX + GCOL + GG,       y: AR[0].y + int((AR[0].h - 32) / 2), w: 44, h: 32 },
        sname:{ x: GX + GCOL + GG + 44,  y: AR[0].y + int((AR[0].h - 32) / 2), w: 62, h: 32 },
        snext:{ x: GX + GCOL + GG + 106, y: AR[0].y + int((AR[0].h - 32) / 2), w: 44, h: 32 },
        // Режим + повтор, ниже - громкость (мельче) и большой тумблер.
        mode: { x: GX,               y: AR[1].y, w: GCOL, h: AR[1].h },
        rep:  { x: GX + GCOL + GG,   y: AR[1].y, w: GCOL, h: AR[1].h },
        vol:  { x: GX,               y: AR[2].y, w: 96,   h: AR[2].h },
        tog:  { x: GX + 96 + GG,     y: AR[2].y, w: GW - 96 - GG, h: AR[2].h },
    };
}

function draw_alarm_page() {
    if (!st.alarm) alarm_load();
    let a = st.alarm, R = alarm_rects();
    lcd_clear(C.bg);
    draw_header(tr("Alarm"));

    // --- Время слева: цифры HH:MM, крупные кнопки +/- сверху и снизу ---
    let dc = a.en ? C.white : C.gray;
    let pm = function(r, plus) {
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        draw_pm(r, plus, C.cyan);
    };
    pm(R.hup, true); pm(R.hdn, false); pm(R.mup, true); pm(R.mdn, false);
    // Цифры стоят между кнопками «+» и «-», по центру левой колонки.
    let dy = R.hup.y + R.hup.h + int((R.hdn.y - R.hup.y - R.hup.h - 32) / 2);
    lcd_text_c(R.hup.x + int(R.hup.w / 2) - 8, dy, sprintf("%02d", a.h), dc, "none", 4);
    lcd_text_c(GX + int(GCOL / 2), dy, ":", dc, "none", 4);
    lcd_text_c(R.mup.x + int(R.mup.w / 2) + 8, dy, sprintf("%02d", a.m), dc, "none", 4);

    // --- Мелодия справа: одна строка "< имя >". Тап по имени - проигрывание. ---
    let lbl = ALARM_SOUNDS[a.si].label;
    let SR = R.sprev, SN = R.snext;
    gcard(SR.x, SR.y, GCOL, SR.h, C.cyan);
    lcd_text(SR.x + 10, mid_y(SR, 2), "<", C.cyan, C.widget, 2);
    lcd_text_r(SN.x + SN.w - 10, mid_y(SN, 2), ">", C.cyan, C.widget, 2);
    lcd_text_c(SR.x + int(GCOL / 2), mid_y(SR, 2), lbl, C.white, C.widget, 2);

    // --- Режим + повтор ---
    lcd_rect(R.mode.x, R.mode.y, R.mode.w, R.mode.h, C.widget);
    lcd_text(R.mode.x + 10, mid_y(R.mode, 1), a.mode == "daily" ? tr("Daily") : tr("Once"),
             C.white, C.widget, 2);
    lcd_rect(R.rep.x, R.rep.y, R.rep.w, R.rep.h, C.widget);
    lcd_text(R.rep.x + 10, mid_y(R.rep, 1),
             a.rep == 0 ? tr("no repeat") : sprintf("%s: %d %s", tr("repeat"), a.rep, tr("min")),
             C.white, C.widget, 1);

    // --- Громкость (компактно): подпись + 3 палочки, тап циклит 1..3 ---
    lcd_rect(R.vol.x, R.vol.y, R.vol.w, R.vol.h, C.widget);
    lcd_text(R.vol.x + 6, mid_y(R.vol, 1), tr("vol"), C.gray, C.widget, 1);
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

function savercfg_rows_for_style() {
    let stl = saver_style();
    let rows = [];
    for (let r in SAVERCFG_ROWS) {
        if (r.key == "sv_date" && stl == "line") continue;
        if (r.key == "sv_wander" && stl != "clock") continue;
        if (r.key == "sv_batt" && !HAS_BATTERY) continue;
        push(rows, r);
    }
    return rows;
}

// Число рядов зависит от стиля заставки, поэтому высоту считаем от него:
// иначе на коротких списках снизу оставалась пустая полка в треть экрана.
function savercfg_rows_n() {
    return length(savercfg_rows_for_style()) + (saver_style() == "clock" ? 1 : 0);
}

function savercfg_row(i) {
    return rows_rect(i, savercfg_rows_n(), IS_ALMONDPLUS ? 56 : 44);
}

function savercfg_size_btn(i) {
    let r = rows_rect(savercfg_rows_n() - 1, savercfg_rows_n(), IS_ALMONDPLUS ? 56 : 44);
    if (!IS_ALMONDPLUS) return { x: 118 + i * 68, y: r.y, w: 60, h: r.h };
    let w = int((GW - 150 - 2 * GG) / 3);
    return { x: GX + 150 + i * (w + GG), y: r.y, w: w, h: r.h };
}

// Показываем только то, что в выбранном стиле вообще есть: у «строки» нет
// даты, блуждание и размер - только у «часов».
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
        astripe(b.x, b.y, b.h, on ? C.green : C.dim);
        lcd_text(b.x + 12, mid_y(b, 1), tr(rows[i].label), C.white, C.widget, 1);
        lcd_text_r(b.x + b.w - 12, mid_y(b, 1), on ? tr("on") : tr("off"),
                 on ? C.green : C.gray, C.widget, 1);
    }
    if (saver_style() == "clock") {
        let sb0 = savercfg_size_btn(0);
        lcd_text(IS_ALMONDPLUS ? GX + 4 : 10, mid_y(sb0, 1), tr("Clock size"), C.ontop, C.bg, 1);
        let names = [ "S", "M", "L" ], keys = [ "s", "m", "l" ];
        for (let i = 0; i < 3; i++) {
            let b = savercfg_size_btn(i), sel = fl.size == keys[i];
            lcd_rect(b.x, b.y, b.w, b.h, C.widget);
            astripe(b.x, b.y, b.h, sel ? C.green : C.border);
            lcd_text_c(b.x + int(b.w / 2), mid_y(b, 2), names[i],
                     sel ? C.white : C.gray, C.widget, 2);
        }
    }
    draw_back();
    lcd_flush();
}


// Сетка списка сетей: две колонки по пять рядов. В одну колонку помещалось
// шесть сетей, в две - десять, и это без прокрутки закрывает почти любой эфир.
function stascan_row(i) {
    if (!IS_ALMONDPLUS)
        return { x: GX + (i % 2) * (GCOL + GG), y: 30 + int(i / 2) * 30,
                 w: GCOL, h: 26 };
    let v = vfit(GVT, GVB, 6);
    return { x: GX + (i % 2) * (GCOL + GG), y: v.y0 + int(i / 2) * v.step,
             w: GCOL, h: v.h };
}

// Скрытая точка в скане не появляется никогда - её имя надо назвать самому.
// Строка стоит под найденными сетями (и одна на пустом списке): выше неё
// место занято результатами скана, ниже - полоса «назад».
// Последний ряд отдан служебным клеткам: слева скрытая сеть, справа листалка.
// Держать за ними постоянное место обязательно - иначе на полном экране
// результатов их негде рисовать, а именно там они и нужны.
let STASCAN_MAX = 10;
function stascan_hidden_row() { return stascan_row(10); }
function stascan_more_row()   { return stascan_row(11); }

// Страниц столько, сколько нужно на все найденные сети; страница по кругу.
function stascan_pages(nets) {
    let n = (type(nets) == "array") ? length(nets) : 0;
    if (n <= STASCAN_MAX) return 1;
    return int((n + STASCAN_MAX - 1) / STASCAN_MAX);
}

function stascan_page(nets) {
    let pg = int(+(sta.pg ?? 0));
    let pages = stascan_pages(nets);
    if (pg < 0 || pg >= pages) pg = 0;
    sta.pg = pg;
    return pg;
}

function draw_hidden_row(nets) {
    let b = stascan_hidden_row();
    lcd_rect(b.x, b.y, b.w, b.h, C.widget);
    astripe(b.x, b.y, b.h, C.accent);
    lcd_text(b.x + 12, IS_ALMONDPLUS ? mid_y(b, 2) : b.y + 7, tr("+ Hidden"), C.accent, C.widget,
             IS_ALMONDPLUS ? 2 : 1);
}

function draw_stascan_page() {
    lcd_clear(C.bg);
    draw_header(sprintf("%s %s", tr("Find network"), sta.band == 5 ? "5GHz" : "2.4GHz"));

    let nets = sta.nets;
    if (nets == null) {
        empty_msg(tr("Scanning..."), C.ontop, 2);
        draw_back();
        lcd_flush();
        return;
    }
    if (length(nets) == 0) {
        lcd_text(20, IS_ALMONDPLUS ? GVT + 12 : 60, tr("No networks found"), C.ontop_dim, C.bg, 2);
        lcd_text(20, IS_ALMONDPLUS ? GVT + 44 : 84, tr("Tap BACK and retry"), C.ontop_dim, C.bg, 1);
        draw_hidden_row(nets);
        draw_back();
        lcd_flush();
        return;
    }
    // Десять сетей на страницу, самые сильные сверху. Клетка узкая, поэтому
    // диапазон не пишем словом - о нём и так сказано в заголовке страницы,
    // а звёздочка отмечает защищённую сеть.
    let off = stascan_page(nets) * STASCAN_MAX;
    for (let k = 0; k < STASCAN_MAX && off + k < length(nets); k++) {
        let n = nets[off + k], b = stascan_row(k);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        let bars = n.signal > -55 ? 3 : (n.signal > -70 ? 2 : 1);
        let bc = bars == 3 ? C.green : (bars == 2 ? C.orange : C.red);
        astripe(b.x, b.y, b.h, bc);
        if (IS_ALMONDPLUS) {
            text_fit2(b.x + 12, mid_y(b, 2), n.ssid, C.white, C.widget, b.w - 36);
            if (n.enc) lcd_text_r(b.x + b.w - 8, mid_y(b, 2), "*", C.gray, C.widget, 2);
        } else {
            lcd_text(b.x + 12, b.y + 7, tcut(n.ssid, 17), C.white, C.widget, 1);
            if (n.enc) lcd_text_r(b.x + b.w - 8, b.y + 7, "*", C.gray, C.widget, 1);
        }
    }
    draw_hidden_row(nets);
    draw_back_pager(stascan_page(nets), stascan_pages(nets));
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
let KB_Y0 = IS_ALMONDPLUS ? 96 : 92;
let KB_FIELD_H = IS_ALMONDPLUS ? 44 : 30;
let KB_FIELD_TY = IS_ALMONDPLUS ? 30 + int((KB_FIELD_H - fpx(2)) / 2) : 38;

function kb_row_pitch(y0) {
    return IS_ALMONDPLUS ? int((BACK_Y - 4 - y0) / 4) : 28;
}

function kb_draw(y0, kb) {
    KB_KEYS = [];
    let rows = KB_ROWS[kb.pg];
    // В терминале подменяем нижний ряд на вариант с Ctrl (кроме страницы стрелок).
    if (kb.term && kb.pg != "ext")
        rows = [ rows[0], rows[1], rows[2], KB_TERM_BOTTOM[kb.pg] ];
    let unit = (LCD_W - 8) / 10;
    let pitch = kb_row_pitch(y0);
    for (let r = 0; r < length(rows); r++) {
        let row = rows[r], y = y0 + r * pitch, cx = 4;
        for (let key in row) {
            let isobj = type(key) == "object";
            let wu = isobj ? (key.w ?? 1) : 1;
            let x = int(cx), w = int(wu * unit) - 2, h = pitch - 2;
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
                astripe(x, y, h, ac);
            }
            let sc = isobj ? 1 : 2;
            if (IS_ALMONDPLUS && isobj && twpx(label, 2) <= w - 14) sc = 2;
            let lw = IS_ALMONDPLUS ? twpx(label, sc) : length(label) * (sc == 2 ? 12 : 6);
            let o = pd ? 1 : 0;
            let ly = IS_ALMONDPLUS ? y + int((h - fpx(sc)) / 2) : y + (sc == 2 ? 6 : 8);
            lcd_text(x + int((w - lw) / 2) + o, ly + o,
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

// Отклик нажатия без паузы: вдавленный кадр висит, пока перерисовывается
// страница после применения клавиши, - глазу хватает, а ввод не тормозит.
function kb_press_show(e, kb, y0) {
    kb_pressed = e;
    kb_draw(y0, kb);
    lcd_flush();
    kb_pressed = null;
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
    lcd_rect(x + 2, y + 2, 26, 16, C.widget);
    for (let r = 0; r < 2; r++)
        for (let c = 0; c < 6; c++)
            lcd_rect(x + 4 + c * 4, y + 4 + r * 4, 2, 2, C.white);
    lcd_rect(x + 6, y + 13, 18, 3, C.white);   // «пробел»
}

// Адрес брокера длинный - ему целая строка; остальное короткое и живёт по две
// клетки в ряд, иначе восемь полей на экран не помещаются. Объявлен ЗДЕСЬ,
// выше draw_kbd_page: та берёт из него заголовок поля, а ucode не хойстит -
// объявление ниже по файлу роняло демона на первом же тапе по полю MQTT.
let MQTT_FIELDS = [
    { key: "host",         label: "Broker",   hint: "адрес или имя" },
    { key: "port",         label: "Port",     hint: "1883" },
    { key: "period",       label: "Period",   hint: "60" },
    { key: "user",         label: "User",     hint: "нет" },
    { key: "pass",         label: "Password", hint: "нет" },
    { key: "prefix",       label: "Topic",    hint: "almond3s" },
    { key: "node",         label: "Node",     hint: "имя хоста" },
    { key: "homed_prefix", label: "HOMEd",    hint: "homed" },
];

function draw_kbd_page() {
    lcd_clear(C.bg);
    // Режим ввода города: то же поле+клавиатура, но текст открытый и свой буфер.
    if (st.kbmode == "city") {
        draw_header(tr("Custom city"));
        lcd_rect(GX, 30, GW, KB_FIELD_H, C.widget);
        let v = st.citybuf ?? "";
        lcd_text(GX + 10, KB_FIELD_TY, v != "" ? v : tr("Type city name"),
                 v != "" ? C.white : C.dim, C.widget, 2);
        kb_draw(KB_Y0, st.citykb);
        draw_back();
        lcd_flush();
        return;
    }
    if (st.kbmode == "ssid") {
        draw_header(tr("Network name"));
        lcd_rect(GX, 30, GW, KB_FIELD_H, C.widget);
        let v = st.ssidbuf ?? "";
        lcd_text(GX + 10, KB_FIELD_TY, v != "" ? v : tr("Type network name"),
                 v != "" ? C.white : C.dim, C.widget, 2);
        kb_draw(KB_Y0, st.citykb);
        draw_back();
        lcd_flush();
        return;
    }
    if (st.kbmode == "hssid") {
        draw_header(tr("Hidden network"));
        lcd_rect(GX, 30, GW, KB_FIELD_H, C.widget);
        let v = sta.hssid ?? "";
        lcd_text(GX + 10, KB_FIELD_TY, v != "" ? v : tr("Type network name"),
                 v != "" ? C.white : C.dim, C.widget, 2);
        kb_draw(KB_Y0, sta.kb);
        draw_back();
        lcd_flush();
        return;
    }
    if (st.kbmode == "zigpan") {
        draw_header("Zigbee: PAN ID");
        lcd_rect(GX, 30, GW, KB_FIELD_H, C.widget);
        let v = st.zigpanbuf ?? "";
        lcd_text(GX + 10, KB_FIELD_TY, v != "" ? v : "0001..FFFE",
                 v != "" ? C.white : C.dim, C.widget, 2);
        lcd_text_r(GX + GW - 10, KB_FIELD_TY, "hex", C.dim, C.widget, 1);
        kb_draw(KB_Y0, st.citykb);
        draw_back();
        lcd_flush();
        return;
    }
    if (st.kbmode == "mqtt") {
        let fk = st.kbfield ?? "host";
        let ttl = fk;
        for (let i = 0; i < length(MQTT_FIELDS); i++)
            if (MQTT_FIELDS[i].key == fk) ttl = tr(MQTT_FIELDS[i].label);
        draw_header(sprintf("MQTT: %s", ttl));
        lcd_rect(GX, 30, GW, KB_FIELD_H, C.widget);
        let v = st.mqttbuf ?? "";
        lcd_text(GX + 10, KB_FIELD_TY, v != "" ? v : tr("Type value"),
                 v != "" ? C.white : C.dim, C.widget, 2);
        kb_draw(KB_Y0, st.citykb);
        draw_back();
        lcd_flush();
        return;
    }
    let n = sta.sel >= 0 ? sta.nets[sta.sel] : null;
    draw_header(tcut(n ? n.ssid : (sta.hssid != null && sta.hssid != ""
                                   ? sta.hssid : tr("Password")), 24));

    // Поле ввода: показываем пароль точками, последний символ открыт.
    lcd_rect(GX, 30, GW, KB_FIELD_H, C.widget);
    let shown = "";
    let pl = length(sta.pass);
    for (let i = 0; i < pl; i++)
        shown += (i == pl - 1) ? substr(sta.pass, i, 1) : "*";
    lcd_text(GX + 10, KB_FIELD_TY, shown != "" ? shown : tr("enter password"),
             shown != "" ? C.white : C.dim, C.widget, 2);

    kb_draw(KB_Y0, sta.kb);   // общая клавиатура (встроенные ⌫⇧↵)
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
let TERM_COLS = IS_ALMONDPLUS ? int((LCD_W - 8) / 6) : 52;

function term_rows() {
    if (!IS_ALMONDPLUS) return st.term.kbd ? 8 : 22;
    return int(((st.term.kbd ? KB_Y0 - 4 : BACK_Y - 4) - (HDR_H + 2)) / 8);
}

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
    lcd_rect(0, BACK_Y, LCD_W, BACK_H, C.widget);
    lcd_rect(0, BACK_Y, LCD_W, 2, C.border);
    // Fn - редактируемая иконка (30x20, слот "fn" в редакторе). Активна
    // (открыта страница стрелок) - рисуем вторым проходом со сдвигом 1px = жирнее.
    let active = st.term.kb.pg == "ext";
    draw_fn_icon(8, bar_y(20), C.white);
    if (active) draw_fn_icon(9, bar_y(20), C.white);
    if (IS_ALMONDPLUS)
        lcd_text_thin(int(LCD_W / 2), bar_y(14), tr("Exit"), C.white, C.widget, 2, "c", 1);
    else
        lcd_text_thin(130, bar_y(14), tr("Exit"), C.white, C.widget, 2);
    draw_kbd_icon(LCD_W - 36, bar_y(20));
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
        kb_draw(KB_Y0, t.kb);
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
    let BR = stack_rects([ 50, 40, 56, 12 ]);
    let y1 = BR[0].y;
    let pcol = pct < 0 ? C.dim : (pct <= 5 && !chg ? C.red : (pct <= 25 ? C.orange : C.green));
    gcard(cx, y1, cw, BR[0].h, pcol);
    lcd_text(cx + 12, y1 + 10, pct < 0 ? "--" : sprintf("%d%%", pct), pcol, C.widget, 3);
    let st_s = bat?.no_battery ? tr("Battery not installed")
             : (full ? tr("Plugged in") : (chg ? tr("Charging") : tr("Battery")));
    lcd_text_r(cx + cw - 12, y1 + 10, st_s, C.white, C.widget, 1);
    // Вольты вместо сырого АЦП по ТОЧНОЙ стоковой формуле (из дизасма ядра:
    // ADC*3.3*(1/1024)*7.11*0.5 = ADC*0.01145654); прежняя adc*8.4/726
    // завышала на ~1% (при 726 рисовала 8.4В, реально 8.32В).
    let adc_s = adc > 0 ? sprintf("%.2f %s", adc * 0.01145654, tr("V")) : "";
    lcd_text_r(cx + cw - 12, y1 + 26, adc_s, C.gray, C.widget, 1);

    // Время работы от батареи с момента, когда сняли зарядку (даёт collector).
    let obs = int(+(bat?.on_bat_sec ?? 0));
    if (!chg && !full && !bat?.no_battery && obs > 0) {
        let ob = sprintf(tr("on battery %s"),
                         obs < 60 ? sprintf("%d %s", obs, tr("sec")) : fmt_dur(int(obs / 60), false));
        lcd_text_r(cx + cw - 12, y1 + 40, ob, C.gray, C.widget, 1);
    }

    // Прогноз: слева подпись и время, справа расход.
    let y2 = BR[1].y;
    gcard(cx, y2, cw, BR[1].h, C.cyan);
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
    lcd_text_r(cx + cw - 12, y2 + 8, d1, C.white, C.widget, 1);
    lcd_text_r(cx + cw - 12, y2 + 22, d2, C.gray, C.widget, 1);

    // Графики за последние ~2 часа: слева заряд, справа сырой АЦП.
    let y3 = BR[2].y;
    gcard(cx, y3, cw, BR[2].h, chg ? C.green : C.yellow);
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
    bar_graph(cx + 10, y3 + 16, 136, BR[2].h - 22, [ { data: bh_pct, color: C.green } ], 0, 100);
    // АЦП - с автомасштабом по данным: на фиксированной шкале 500..730
    // час зарядки выглядел одной неподвижной полосой.
    let abm = arr_minmax(bh_adc);
    bar_graph(cx + 156, y3 + 16, 136, BR[2].h - 22, [ { data: bh_adc, color: C.cyan } ],
              abm.min - 4, abm.max + 4);

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
    lcd_text(cx + 2, BR[3].y + 3, foot, C.dim, "none", 1);

    draw_back();
    lcd_flush();
}

// Две колонки, как в списке сетей: имена ромов короткие, в одну колонку
// половина строки уходила впустую, а на страницу влезало вдвое меньше.
let GAMES_PER_PAGE = 8;
let GAMES_CFG_H = IS_ALMONDPLUS ? 40 : 28;
function games_btn(i) {
    if (!IS_ALMONDPLUS)
        return { x: GX + (i % 2) * (GCOL + GG), y: 26 + int(i / 2) * 32,
                 w: GCOL, h: 30 };
    let v = vfit(GVT, GVB - GAMES_CFG_H - GG, 4);
    return { x: GX + (i % 2) * (GCOL + GG), y: v.y0 + int(i / 2) * v.step,
             w: GCOL, h: v.h };
}

// Листалка: ромов стало много, на страницу помещается четыре.
function games_cfg_btn() {
    if (!IS_ALMONDPLUS) return { x: 8, y: 158, w: 96, h: 28 };
    return { x: GX, y: GVB - GAMES_CFG_H, w: 160, h: GAMES_CFG_H };
}

// Переключатели эмулятора лежат в файлах: он перечитывает их на живую, без
// перезапуска игры. Здесь мы им просто даём лицо.
let KEYFILE = "/etc/almond3s/nes_keys";

let LCD_MOD = IS_ALMONDPLUS ? "almondplus_lcd" : "almond3s_lcd";

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
      sysfs: "/sys/module/" + LCD_MOD + "/parameters/color12" },
    // Обновление через строку: байтов по шине вдвое меньше, но на быстром
    // движении видна гребёнка.
    { file: "/etc/almond3s/lcd_interlace", label: "Через строку", vals: [ "0", "1" ],
      names: [ "выкл", "вкл" ], def: "0",
      sysfs: "/sys/module/" + LCD_MOD + "/parameters/interlace" },
];
if (IS_ALMONDPLUS) {
    GSET = filter(GSET, (g) => g.file != "/etc/almond3s/lcd_color12");
    push(GSET, { file: "/etc/almond3s/nes_scale", label: "Масштаб", vals: [ "fit", "1x" ],
                 names: [ "весь экран", "1:1" ], def: "fit" });
}

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
    if (!IS_ALMONDPLUS) return { x: 8, y: 28 + i * 24, w: 304, h: 22 };
    let v = vfit(GVT, GVB, length(GSET) + 1);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}

// Кнопка «Пульт» под списком настроек - ведёт на страницу с QR-кодами.
function gqr_btn() {
    if (!IS_ALMONDPLUS) return { x: 8, y: 32 + length(GSET) * 24, w: 148, h: 26 };
    let r = gset_btn(length(GSET));
    return { x: GX, y: r.y, w: GCOL, h: r.h };
}

function gkeys_btn() {
    if (!IS_ALMONDPLUS) return { x: 164, y: 32 + length(GSET) * 24, w: 148, h: 26 };
    let r = gset_btn(length(GSET));
    return { x: GX + GCOL + GG, y: r.y, w: GCOL, h: r.h };
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

    if (IS_ALMONDPLUS) {
        let sc = 5, rows0 = qr_rows(pad_url(1));
        let side = (rows0 ? length(rows0) : 29) * sc;
        let qy = GVT + 12;
        for (let i = 0; i < 2; i++) {
            let x = i == 0 ? int(LCD_W / 2) - 24 - side : int(LCD_W / 2) + 24;
            draw_qr(qr_rows(pad_url(i + 1)), x, qy, sc, "#000000", "#FFFFFF");
            lcd_text_c(x + int(side / 2), qy + side + 12, sprintf(tr("Player %d"), i + 1),
                       C.ontop_hi, C.bg, 2);
        }
        lcd_text(GX + 6, GVB - 34, tr("scan while a game is running"), C.ontop_dim, C.bg, 1);
        lcd_text(GX + 6, GVB - 18, pad_url(1), C.ontop, C.bg, 1);
    } else {
        for (let i = 0; i < 2; i++) {
            let x = 22 + i * 156;
            draw_qr(qr_rows(pad_url(i + 1)), x, 46, 3, "#000000", "#FFFFFF");
            lcd_text(x + 4, 140, sprintf(tr("Player %d"), i + 1), C.ontop_hi, C.bg, 1);
        }
        lcd_text(12, 168, tr("scan while a game is running"), C.ontop_dim, C.bg, 1);
        lcd_text(12, 184, pad_url(1), C.ontop, C.bg, 1);
    }

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
    if (!IS_ALMONDPLUS) return { x: 8, y: 32 + i * 32, w: 304, h: 28 };
    let v = vfit(GVT, GVB - 24, length(KEYS));
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}

let GK_VAL_X = IS_ALMONDPLUS ? 240 : 180;

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
        astripe(b.x, b.y, b.h, C.accent);
        let ky = IS_ALMONDPLUS ? mid_y(b, 1) : b.y + 8;
        lcd_text(b.x + 12, ky, KEYS[i].label, C.gray, C.widget, 1);
        lcd_text(b.x + GK_VAL_X, ky, key_title(m[KEYS[i].id]), C.white, C.widget, 1);
    }
    lcd_text(12, IS_ALMONDPLUS ? GVB - 12 : 32 + length(KEYS) * 32 + 4,
             tr("tap a row, then press a key"), C.ontop_dim, C.bg, 1);

    draw_back();
    lcd_flush();
}

// Ждём нажатие и записываем. Пока ждём, показываем это на самой строке -
// иначе непонятно, слушает интерфейс или подвис.
function gkey_learn(i) {
    let b = gkey_btn(i);
    let ky = IS_ALMONDPLUS ? mid_y(b, 1) : b.y + 8;
    lcd_rect(b.x, b.y, b.w, b.h, C.press);
    astripe(b.x, b.y, b.h, C.accent);
    lcd_text(b.x + 12, ky, KEYS[i].label, C.gray, C.press, 1);
    lcd_text(b.x + GK_VAL_X, ky, tr("press a key"), C.accent, C.press, 1);
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
        astripe(b.x, b.y, b.h, C.accent);
        let gy = IS_ALMONDPLUS ? mid_y(b, 1) : b.y + 7;
        lcd_text(b.x + 10, gy, GSET[i].label, C.gray, C.widget, 1);
        lcd_text(b.x + (IS_ALMONDPLUS ? 200 : 150), gy, GSET[i].names[k], C.white, C.widget, 1);
    }
    let kb = gkeys_btn();
    lcd_rect(kb.x, kb.y, kb.w, kb.h, C.widget);
    astripe(kb.x, kb.y, kb.h, C.accent);
    lcd_text(kb.x + 10, IS_ALMONDPLUS ? mid_y(kb, 1) : kb.y + 8, tr("Keys"), C.accent, C.widget, 1);

    let q = gqr_btn();
    lcd_rect(q.x, q.y, q.w, q.h, C.widget);
    astripe(q.x, q.y, q.h, C.accent);
    lcd_text(q.x + 10, IS_ALMONDPLUS ? mid_y(q, 1) : q.y + 8, tr("Gamepad"), C.accent, C.widget, 1);

    draw_back();
    lcd_flush();
}

function draw_games_page() {
    lcd_clear(C.bg);
    draw_header(tr("Games"));

    let roms = rom_list();
    let pages = length(roms) > GAMES_PER_PAGE
              ? int((length(roms) + GAMES_PER_PAGE - 1) / GAMES_PER_PAGE) : 1;
    if (st.gpg == null || st.gpg >= pages) st.gpg = 0;
    let base = st.gpg * GAMES_PER_PAGE;
    for (let i = 0; i < GAMES_PER_PAGE && base + i < length(roms); i++) {
        let r = games_btn(i);
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        astripe(r.x, r.y, r.h, C.accent);
        if (IS_ALMONDPLUS)
            text_fit2(r.x + 12, mid_y(r, 2), roms[base + i].name, C.white, C.widget, r.w - 24);
        else
            lcd_text(r.x + 12, r.y + 9, tcut(roms[base + i].name, 20), C.white, C.widget, 1);
    }
    let cb = games_cfg_btn();
    lcd_rect(cb.x, cb.y, cb.w, cb.h, C.widget);
    astripe(cb.x, cb.y, cb.h, C.accent);
    if (IS_ALMONDPLUS)
        lcd_text(cb.x + 12, mid_y(cb, 2), tr("Setup"), C.accent, C.widget, 2);
    else
        lcd_text(cb.x + 10, cb.y + 10, tr("Setup"), C.accent, C.widget, 1);

    // Путь к ромам показываем ВСЕГДА, мелко и приглушённо. Раньше он всплывал
    // только когда список пуст - то есть ровно тогда, когда его уже некуда
    // положить, а при полном списке узнать место было неоткуда.
    if (IS_ALMONDPLUS)
        lcd_text(cb.x + cb.w + 12, mid_y(cb, 1), ROM_DIRS[0], C.ontop_dim, C.bg, 1);
    else
        lcd_text(10, 192, ROM_DIRS[0], C.ontop_dim, C.bg, 1);

    // Подсказка, когда ромов нет или эмулятор не поставлен. Путь тут больше не
    // дублируем - он строкой ниже.
    let y = 26 + (length(roms) + 1) * 32 + 6;
    if (IS_ALMONDPLUS)
        y = games_btn(length(roms) < GAMES_PER_PAGE ? length(roms) : GAMES_PER_PAGE - 1).y + 12;
    if (!fs.stat(NES_BIN))
        lcd_text(12, y, tr("emulator not installed"), C.ontop_dim, C.bg, 1);
    else if (!length(roms))
        lcd_text(12, y, tr("Put .nes into"), C.ontop_dim, C.bg, 1);

    draw_back_pager(st.gpg ?? 0, pages);
    lcd_flush();
}


let ZIG_BIN = "/usr/libexec/almond3s/almond3s-zig";
let ZIG_ESCAN = "/tmp/lcd_zig_escan.json";
let ZIG_ASCAN = "/tmp/lcd_zig_ascan.json";
let ZIG_INFO  = "/tmp/lcd_zig_info.json";

// Случайный номер сети, запомненный на первый раз. /dev/urandom - тот же
// источник, что и у ключа: своего генератора в ucode нет.
function zig_pan_default() {
    if (!ucur) return 6699;
    let v = ucur.get("almond3s", "zigbee", "pan");
    if (v != null && v != "") return int(+v);
    let f = fs.popen("head -c 2 /dev/urandom | hexdump -v -e '2/1 \"%02X\"'", "r");
    let hx = f ? trim(f.read("all") ?? "") : "";
    if (f) f.close();
    let n = length(hx) == 4 ? hex(hx) : 0;
    if (n < 1 || n > 65534) n = 4096 + (time() % 40000);
    if (ucur.get("almond3s", "zigbee") == null)
        ucur.set("almond3s", "zigbee", "zigbee");
    ucur.set("almond3s", "zigbee", "pan", sprintf("%d", n));
    ucur.commit("almond3s");
    return n;
}

function zig_cfg() {
    let g = function(k, d) {
        let v = ucur ? ucur.get("almond3s", "zigbee", k) : null;
        return (v == null || v == "") ? d : v;
    };
    return {
        // Своя сеть - свой номер: если его ещё нет, берём случайный, а не
        // зашитый. Прежний умолчальный 0x1A2B был один на все аппараты, и
        // «Поднять» на чистом устройстве уводило его в чужую сеть с тем же
        // номером.
        pan:   clampi(int(+g("pan", zig_pan_default())), 1, 65534),
        ch:    clampi(int(+g("channel", 15)), 11, 26),
        power: clampi(int(+g("power", 8)), -8, 20),
        key:   g("key", "30313233343536373839404142434445"),
        beacon: g("beacon", "0") == "1",
    };
}

let ZIG_PEERS = "/tmp/lcd_zig_peers.json";

function zig_name() {
    let v = ucur ? ucur.get("system", "@system[0]", "hostname") : null;
    return (v == null || v == "") ? "almond" : v;
}

let ZIG_TELE = "/tmp/lcd_zig_tele.json";
let TELE_SELF = "/tmp/almond_tele.json";
let TELE_MODEM = "/tmp/5gmodem_tele.json";
let TELE_STALE = 90;

// Телеметрия для маячка: плоский набор чисел, который он упакует в эфир.
// Считает интерфейс - у него уже всё разобрано, а в C дублировать разбор
// незачем. Имена полей те же, что в контракте схемы.
function zig_tele_write() {
    let d = st.data;
    if (!d) return;
    let bt = d.battery, tot = int(+(d.mem_total_mb ?? 0)), fr = int(+(d.mem_free_mb ?? 0));
    let stot = int(+(d.storage?.total_kb ?? 0)), sfr = int(+(d.storage?.free_kb ?? 0));
    let nc = type(d.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
    let tele = {};

    let pc = int(+(bt?.percent ?? -1));
    if (pc >= 0) {
        tele.batt = clampi(pc, 0, 100);
        tele.chg = bt?.charging ? 1 : 0;
    }
    if (d.cpu_busy != null) tele.cpu = clampi(int(+d.cpu_busy), 0, 100);
    if (tot > 0) tele.mem = clampi(int(((tot - fr) * 100 + tot / 2) / tot), 0, 100);
    if (stot > 0) tele.disk = clampi(int(((stot - sfr) * 100 + stot / 2) / stot), 0, 100);
    if (d.uptime != null) tele.up = int((int(+d.uptime) + 30) / 60);
    tele.wifi = nc;
    if (st.vpn_on != null) tele.vpn = st.vpn_on ? 1 : 0;
    if (st.vpn_on && st.vpn_node != null && st.vpn_node != "")
        tele.vpn_node = tcut(st.vpn_node, 16);

    let tmp = TELE_SELF + ".tmp";
    fs.writefile(tmp, sprintf("%J\n", tele));
    system(sprintf("mv %s %s", tmp, TELE_SELF));
}

// Пока идёт одноразовая команда (скан, вступление, поднятие сети), порт
// чипа занят ею. Всё, что умеет поднимать телеметрию - сторож, страницы, -
// обязано в это время молчать: иначе демон перехватывает порт и команда
// умирает на «занято». Это и было вечное «жду соседей».
function zig_hold(sec) {
    st.zig ??= {};
    st.zig.hold = time() + (sec ?? 60);
}

function zig_held() {
    // Основной признак - сам файл, его снимает последняя команда цепочки.
    // Файл старше двух минут - цепочка умерла, не прибрав за собой: чистим,
    // иначе страница вечно «занята», а сторож не поднимает телеметрию.
    let ss = fs.stat("/tmp/.zig_cmd_busy");
    if (ss) {
        if ((time() - ss.mtime) > 120) { fs.unlink("/tmp/.zig_cmd_busy"); return false; }
        return true;
    }
    // Флаг снят - цепочка закончилась. Запас времени дальше не держим: он
    // только оттягивал синхронизацию конфига и перезапуск телеметрии на
    // остаток полутора минут после уже завершённой команды.
    if (st.zig?.hold_file) { st.zig.hold_file = null; st.zig.hold = null; return false; }
    return st.zig?.hold != null && time() < st.zig.hold;
}

function zig_beacon_stop() {
    // Гасим ТОЛЬКО демона телеметрии, а не всё с этим именем: killall убивал
    // заодно одноразовые команды - скан и вступление, - и они умирали на
    // полпути. pkill в busybox тут нет, поэтому ищем процесс сами: в cmdline
    // есть и имя бинарника, и слово режима.
    for (let e in (fs.lsdir("/proc") ?? [])) {
        if (!match(e, /^[0-9]+$/)) continue;
        let c = fs.readfile("/proc/" + e + "/cmdline");
        if (!c) continue;
        if (index(c, "almond3s-zig") < 0) continue;
        if (index(c, "mesh") < 0 && index(c, "beacon") < 0) continue;
        system("kill " + e + " >/dev/null 2>&1");
    }
}


let ZIG_KEYFILE = "/tmp/.zig_key";

function zig_mode() {
    let v = ucur ? ucur.get("almond3s", "zigbee", "mode") : null;
    return v == "mesh" ? "mesh" : "beacon";
}

// Команда запуска телеметрии - одной строкой: нужна и обычному старту, и
// цепочке «погасить - выполнить - поднять обратно».
function zig_start_cmd() {
    let c = zig_cfg();
    if (!c.beacon) return "";
    // Ключ эфира кладём в файл, а не в аргументы: аргументы видно всем в списке
    // процессов. Пустой ключ - маячок работает открытым текстом.
    if (length(c.key) >= 32) {
        fs.writefile(ZIG_KEYFILE, substr(c.key, 0, 32) + "\n");
        system("chmod 600 " + ZIG_KEYFILE + " 2>/dev/null");
    } else {
        fs.unlink(ZIG_KEYFILE);
    }
    // Имя узла - это hostname, а его человек задаёт сам: пробел разорвал бы
    // команду на два аргумента, точка с запятой - на две команды.
    // Открытое окно приёма передаём демону: стек сбрасывает его при своём
    // networkInit, и без этого «Приём» гас через секунды - ровно на рестарте
    // телеметрии, который идёт следом за самой командой.
    if (zig_mode() == "mesh")
        return sprintf("ZIG_POWER=%d setsid %s mesh 30 %s >/dev/null 2>&1 </dev/null &",
                       c.power, ZIG_BIN, sh_quote(zig_name()));
    return sprintf("ZIG_POWER=%d setsid %s beacon %d 10 %s >/dev/null 2>&1 </dev/null &",
                   c.power, ZIG_BIN, c.ch, sh_quote(zig_name()));
}

function zig_beacon_start() {
    if (zig_held()) return;          // идёт команда - порт не отбираем
    let cmd = zig_start_cmd();
    if (cmd == "") return;
    zig_beacon_stop();
    system(cmd);
}

// Порт у чипа один, и телеметрия держит его постоянно. Любая команда с
// интерфейса упиралась в «занято», через шесть секунд сдавалась и молча
// ничего не делала - именно так «Поднять» оставляла аппарат в старой сети.
// Поэтому демона гасим, выполняем команду и той же цепочкой поднимаем обратно.
function zig_cmd_bg(cmd) {
    zig_hold(90);
    let restart = zig_start_cmd();
    // Команду отдали - значит набранное уже применяется, и защищать правку от
    // синхронизации больше незачем: пусть страница показывает результат сразу,
    // а не через двадцать секунд.
    if (st.zig) st.zig.edit = null;
    zig_beacon_stop();
    // Конфиг подводим к чипу ТОЛЬКО когда сеть реально поднялась (state=2).
    // Иначе неудачное вступление затирало набранный PAN старым - тем, где
    // чип и остался, - и выглядело так, будто правку проглотили.
    let sync = "S=$(jsonfilter -i /tmp/lcd_zig_state.json -e '@.state' 2>/dev/null); " +
               "P=$(jsonfilter -i /tmp/lcd_zig_state.json -e '@.pan' 2>/dev/null); " +
               "C=$(jsonfilter -i /tmp/lcd_zig_state.json -e '@.ch' 2>/dev/null); " +
               "if [ \"$S\" = 2 ] && [ -n \"$P\" ] && [ \"$P\" != 65535 ]; then " +
               "uci set almond3s.zigbee.pan=$P; uci set almond3s.zigbee.channel=$C; " +
               "uci commit almond3s; fi";
    // Команда запуска демона САМА заканчивается на «&», поэтому ставить после
    // неё точку с запятой нельзя - шелл падает на «& ;» и вся цепочка не
    // выполняется вовсе. Держим её последней, а флаг снимаем перед ней.
    if (restart == "") restart = "true";
    system(sprintf("( %s ; %s state > /tmp/lcd_zig_state.json 2>/dev/null ; %s ; " +
                   "rm -f /tmp/.zig_cmd_busy ; %s ) >/dev/null 2>&1 &",
                   cmd, ZIG_BIN, sync, restart));
    system("touch /tmp/.zig_cmd_busy");
    st.zig ??= {};
    st.zig.hold_file = 1;
}

function zig_set(k, v) {
    if (!ucur) return;
    if (ucur.get("almond3s", "zigbee") == null)
        ucur.set("almond3s", "zigbee", "zigbee");
    ucur.set("almond3s", "zigbee", k, sprintf("%s", v));
    ucur.commit("almond3s");
}

function zig_json(path) {
    let raw = fs.readfile(path);
    if (!raw) return null;
    try { return json(raw); } catch (e) { return null; }
}

// Режим страницы Zigbee - «эфир» или список соседей. Держать его в одном месте
// обязательно: zig_run() заводит st.zig под свои нужды ещё до того, как
// страницу впервые нарисовали, и объект получался БЕЗ поля mode. Рисование
// показывало список (там условие «не эфир»), а обработчик тапа сверялся с
// «mode == peers» и не находил совпадения - строки соседей не открывались.
// Конфиг подтягиваем к тому, где чип на самом деле: параметры живой сети
// кладёт в свой JSON телеметрия. Вызывается при отрисовке страницы настроек и
// сразу после поднятия/вступления - чтобы на экране всегда было одно число, а
// не «в конфиге одно, в эфире другое».
// PAN и канал живой сети: их пишет телеметрия, читаем оттуда. null - если
// данных нет или они несвежие; тогда зовущий берёт значение из конфига.
// Сколько секунд ещё открыт приём. Источник один - файл, который читает и
// демон: состояние в памяти интерфейса терялось при его перезапуске, и кнопка
// врала про открытое окно.
let ZIG_PERMIT_F = "/tmp/.zig_permit_until";

function zig_permit_left() {
    let raw = fs.readfile(ZIG_PERMIT_F);
    if (!raw) return 0;
    let t = int(+trim(raw));
    let left = t - time();
    return left > 0 ? left : 0;
}

function zig_permit_open(sec) {
    fs.writefile(ZIG_PERMIT_F, sprintf("%d\n", time() + sec));
}

function zig_permit_close() {
    fs.unlink(ZIG_PERMIT_F);
}

let ZIG_STATE = "/tmp/lcd_zig_state.json";

// Живое состояние сети - из самого свежего источника. Телеметрия пишет свой
// файл раз в две секунды, но её можно выключить - тогда единственная правда
// это файл состояния, который пишет каждая цепочка команд. Раньше интерфейс
// верил только телеметрии: с выключенной телеметрией аппарат вступал в сеть,
// а экран навсегда застревал в прошлой - «жду соседей», старый PAN в шапке.
function zig_live_src() {
    let bp = null, bm = 0;
    for (let p in [ ZIG_PEERS, ZIG_STATE ]) {
        let ss = fs.stat(p);
        if (!ss || (time() - ss.mtime) > 20) continue;
        if (ss.mtime >= bm) { bm = ss.mtime; bp = p; }
    }
    return bp ? zig_json(bp) : null;
}

function zig_live_pan() {
    let v = int(+(zig_live_src()?.pan ?? 0));
    return (v > 0 && v != 65535) ? v : null;
}

function zig_live_ch() {
    let v = int(+(zig_live_src()?.ch ?? 0));
    return v > 0 ? v : null;
}

// Роль в сети: null - свежих данных нет вовсе, 0 - вне сети, 1 - координатор,
// 2 - роутер. PAN 65535 означает «ни в какой», роль тогда тоже нулевая.
function zig_live_node() {
    let d = zig_live_src();
    if (d == null) return null;
    let pan = int(+(d.pan ?? 0));
    if (pan <= 0 || pan == 65535) return 0;
    return int(+(d.node ?? 0));
}

// Конфиг за спиной интерфейса правят цепочки команд обычным uci, а свой
// курсор держит прочитанное в памяти. Перечитываем перед каждой отрисовкой
// страниц Zigbee - иначе на экране навсегда остаётся значение, прочитанное
// при запуске.
function zig_cfg_reload() {
    if (ucur) ucur.load("almond3s");
}

function zig_sync_cfg() {
    // Пока идёт команда, состояние переходное: демон убит, файл соседей от
    // ПРОШЛОЙ сети. Подводить под него конфиг нельзя - именно так набранный
    // PAN откатывался к старому сразу после нажатия «Поднять».
    if (zig_held()) return;
    let ss = fs.stat(ZIG_PEERS);
    if (!ss || (time() - ss.mtime) > 10) return;   // файл несвежий - верить нечему
    // Конфиг за спиной интерфейса правит и цепочка команд (обычным uci из
    // шелла), поэтому перед сверкой перечитываем файл: свой курсор держит
    // значения в памяти, и страница показывала старое, пока он сам не
    // обновится. Это и был скачок «канал 20 -> 15 -> снова 20».
    if (ucur) ucur.load("almond3s");
    let live = zig_json(ZIG_PEERS);
    let lpan = int(+(live?.pan ?? 0)), lch = int(+(live?.ch ?? 0));
    // 65535 - «ни в какой сети»: подводить конфиг под него нельзя.
    if (lpan <= 0 || lpan == 65535 || lch <= 0 || !ucur) return;
    if (st.zig?.edit != null && (time() - st.zig.edit) < 20) return;   // человек правит прямо сейчас
    let c = zig_cfg();
    if (c.pan != lpan) ucur.set("almond3s", "zigbee", "pan", sprintf("%d", lpan));
    if (c.ch != lch) ucur.set("almond3s", "zigbee", "channel", sprintf("%d", lch));
    if (c.pan != lpan || c.ch != lch) ucur.commit("almond3s");
}

function zig_ui_mode() {
    st.zig ??= {};
    if (st.zig.mode == null)
        st.zig.mode = zig_cfg().beacon ? "peers" : "escan";
    return st.zig.mode;
}

// Скан идёт секунды и держит порт, поэтому запускаем фоном в файл, а страница
// подхватывает результат по смене mtime - как проверка сервисов.
function zig_run(cmd, out, arg) {
    st.zig ??= {};
    zig_hold(60);
    st.zig.busy = time();
    st.zig.cmd = cmd;
    let st0 = fs.stat(out);
    st.zig.mt = st0 ? st0.mtime : 0;
    system(sprintf("(%s %s %s > %s.tmp 2>/dev/null; mv %s.tmp %s) </dev/null &",
                   ZIG_BIN, cmd, arg ?? "", out, out, out));
}

function zig_busy() {
    let z = st.zig;
    if (!z || !z.busy) return false;
    let out = z.cmd == "ascan" ? ZIG_ASCAN : (z.cmd == "escan" ? ZIG_ESCAN : ZIG_INFO);
    let ss = fs.stat(out);
    if ((ss && ss.mtime != z.mt) || (time() - z.busy) > 45) { z.busy = 0; z.hold = null; return false; }
    return true;
}

let ZIG_HDR_H = IS_ALMONDPLUS ? 30 : 26;
let ZIG_BTN_H = IS_ALMONDPLUS ? 40 : 32;
let ZIG_ROW_STEP = IS_ALMONDPLUS ? 24 : 17;

function zig_btn(i) {
    let w = int((GW - 2 * GG) / 3);
    return { x: GX + i * (w + GG), y: IS_ALMONDPLUS ? GVB - ZIG_BTN_H : BACK_Y - 38, w: w, h: ZIG_BTN_H };
}

// Домик координатора рисуется общим движком иконок: значит, его можно
// открыть в редакторе и переправить, как любую другую иконку.
function icon_home(x, y, col, bg) {
    draw_st_icon(x, y, "home", HOME_DEF, col, true);
}

function zig_rssi_bar(v) {
    return clampi(int((int(v) + 100) * 100 / 90), 0, 100);
}

function zig_rssi_col(v) {
    let r = int(v);
    return r >= -70 ? C.green : (r >= -85 ? C.orange : C.red);
}

function zig_rows() {
    let d = zig_json(ZIG_PEERS);
    let peers = type(d?.peers) == "array" ? d.peers : [];
    let mnode = int(+(d?.node ?? 0));
    let rows = [];
    if (mnode > 0)
        push(rows, { name: d?.me ?? zig_name(), self: true, coord: mnode == 1, pi: -1 });
    for (let i = 0; i < length(peers); i++) {
        let pp = peers[i];
        push(rows, { name: pp.name ?? "?", self: false,
                     coord: mnode > 0 && int(+(pp.m?.node ?? 0)) == 1,
                     rssi: int(+(pp.rssi ?? 0)), lqi: int(+(pp.lqi ?? 0)),
                     age: int(+(pp.age ?? 999)), pi: i });
    }
    return rows;
}

let ZW_BIN = "/usr/libexec/almond3s/almond3s-zwave";
function zw_probe(force) {
    let now = time();
    if (!force && st.zw && (now - (st.zw.ts ?? 0)) < 20)
        return st.zw.d;
    let out = "";
    let p = fs.popen(ZW_BIN + " 2>/dev/null", "r");
    if (p) { out = trim(p.read("all") ?? ""); p.close(); }
    let d = null;
    try { d = json(out); } catch (e) {}
    st.zw = { ts: now, d: d };
    return d;
}

function draw_zwave_page() {
    lcd_clear(C.bg);
    draw_header("Z-Wave");
    let d = zw_probe(false);
    let ok = (d?.ok == 1);
    let head = ok ? sprintf("SD3503  %s", d.version ?? "") : tr("controller silent");

    let hh = ZIG_HDR_H;
    lcd_rect(GX, GY, GW, hh, C.widget);
    astripe(GX, GY, hh, ok ? C.green : C.dim);
    lcd_text(GX + 12, GY + int((hh - 8) / 2), head, C.white, C.widget, 1);

    let ay = GY + hh + GG, ah = (IS_ALMONDPLUS ? GVB : BACK_Y - 44) - ay;
    lcd_rect(GX, ay, GW, ah, C.widget);
    astripe(GX, ay, ah, ok ? "#D2A8FF" : C.dim);
    if (ok) {
        let ls = IS_ALMONDPLUS ? 2 : 1;
        lcd_text(GX + 14, ay + 16, sprintf("Home ID: %s", d.homeid ?? "?"), C.white, C.widget, IS_ALMONDPLUS ? 3 : 2);
        lcd_text(GX + 14, ay + (IS_ALMONDPLUS ? 64 : 48), sprintf("Node ID: %d", d.nodeid ?? 0), C.gray, C.widget, ls);
        lcd_text(GX + 14, ay + (IS_ALMONDPLUS ? 96 : 68), sprintf("%s controller (lib %d)", tr("static"), d.libtype ?? -1),
                 C.gray, C.widget, ls);
    } else {
        lcd_text(GX + 14, ay + int(ah / 2) - (IS_ALMONDPLUS ? int(fpx(2) / 2) : 7), tr("controller silent"), C.gray, C.widget, 2);
    }
    draw_back();
    lcd_flush();
}

function draw_zigbee_page() {
    zig_cfg_reload();
    lcd_clear(C.bg);
    draw_header(tr("Zigbee"));
    let cfg = zig_cfg();
    zig_ui_mode();
    let z = st.zig;

    let info = zig_json(ZIG_INFO);
    let pj = zig_json(ZIG_PEERS);
    // Пока работает маячок, опросить чип нельзя - порт занят. Тогда берём
    // строку, которую маячок сам записал при старте.
    let head = info?.ok ? sprintf("EM357  EZSP v%d  %s", info.ezsp, info.stack ?? "")
             : (pj?.chip ?? tr("chip silent"));
    let hh = ZIG_HDR_H, hty = GY + int((hh - 8) / 2);
    lcd_rect(GX, GY, GW, hh, C.widget);
    astripe(GX, GY, hh, info?.ok ? C.green : C.dim);
    lcd_text(GX + 12, hty, head, C.white, C.widget, 1);
    lcd_text_r(GX + GW - 11, hty,
             sprintf("PAN %04X  CH %d", zig_live_pan() ?? cfg.pan,
                     zig_live_ch() ?? cfg.ch), C.gray, C.widget, 1);

    let ay = GY + hh + GG, ah = (IS_ALMONDPLUS ? GVB - ZIG_BTN_H - GG : BACK_Y - 44) - ay;
    lcd_rect(GX, ay, GW, ah, C.widget);

    if (!zig_busy() && st.zig?.restart) { st.zig.restart = false; zig_beacon_start(); }
    if (zig_busy()) {
        lcd_text(GX + int((GW - tlen(tr("Scanning...")) * 12) / 2), ay + int(ah / 2) - 7,
                 tr("Scanning..."), C.cyan, C.widget, 2);
    } else if (zig_ui_mode() == "escan") {
        let d = zig_json(ZIG_ESCAN);
        let chans = type(d?.channels) == "array" ? d.channels : [];
        if (length(chans) == 0) {
            lcd_text(GX + 12, ay + 12, tr("Air"), C.gray, C.widget, 1);
            lcd_text(GX + 12, ay + 28, tr("no data"), C.dim, C.widget, 2);
        } else {
            let best = null, worst = null;
            for (let c in chans) {
                if (best == null || c.rssi < best.rssi) best = c;
                if (worst == null || c.rssi > worst.rssi) worst = c;
            }
            let lo = best.rssi - 4, hi = worst.rssi + 2;
            if (hi - lo < 10) { lo = hi - 10; }
            let bw = int((GW - 16) / length(chans));
            let base = ay + ah - 16;
            let top = ay + 16;
            for (let i = 0; i < length(chans); i++) {
                let c = chans[i];
                let v = clampi(int((c.rssi - lo) * 100 / (hi - lo)), 3, 100);
                let h = int((base - top) * v / 100);
                let x = GX + 8 + i * bw;
                let col = (c.ch == best.ch) ? C.green : (v > 55 ? C.orange : C.cyan);
                if (h > 0) lcd_rect(x, base - h, bw - 2, h, col);
                if ((c.ch % 2) == 1)
                    lcd_text(x - 1, base + 4, sprintf("%d", c.ch), C.dim, C.widget, 1);
            }
            lcd_text(GX + 12, ay + 5, sprintf("%s: %d (%d dBm)", tr("quietest"),
                     best.ch, best.rssi), C.green, C.widget, 1);
        }
    } else {
        let d = zig_json(ZIG_PEERS);
        let on = zig_cfg().beacon;
        let lnode = zig_live_node();
        let mesh = (lnode ?? int(+(d?.node ?? 0))) > 0;
        let rows = zig_rows();
        // Список из одного себя сразу после вступления - это не поломка, а
        // ожидание: каждый объявляется раз в период. Пишем прямо, иначе
        // читается как «вступил, но никого нет».
        let waiting = mesh && length(rows) <= 1;
        // Легенду «домик - координатор» убрал: она читалась как состояние
        // этого аппарата, хотя домик стоит у той строки, чей узел координатор.
        if (zig_held()) {
            // Идёт команда: список под ней всё равно от прошлой сети, честнее
            // сказать, что происходит, чем показывать устаревших соседей.
            lcd_text(GX + 12, ay + 8, tcut(st.zig?.form_msg ?? tr("command running"), 23),
                     C.cyan, C.widget, 2);
        } else if (!on) {
            // Телеметрия выключена - обновлять список некому. Раньше тут
            // висело «жду соседей», и казалось, что вступление не сработало.
            lcd_text(GX + 12, ay + 8, tr("telemetry disabled"), C.orange, C.widget, 2);
            lcd_text(GX + 12, ay + 30, tr("enable telemetry hint"), C.dim, C.widget, 1);
            if (mesh)
                lcd_text(GX + 12, ay + 46, sprintf("%s: PAN %04X", tr("in network"),
                         zig_live_pan() ?? zig_cfg().pan), C.gray, C.widget, 1);
        } else if (zig_mode() == "mesh" && !mesh) {
            lcd_text(GX + 12, ay + 8, tr("not in network yet"), C.dim, C.widget, 2);
            lcd_text(GX + 12, ay + 30, tr("join or form hint"), C.dim, C.widget, 1);
        } else if (waiting) {
            lcd_text(GX + 12, ay + 8, tr("waiting for peers"), C.cyan, C.widget, 2);
            lcd_text(GX + 12, ay + 30, tr("each announces once a period"), C.dim, C.widget, 1);
        } else if (length(rows) == 0) {
            lcd_text(GX + 12, ay + 8, tr("no peers heard"), C.dim, C.widget, 2);
        } else {
            if (!mesh)
                lcd_text(GX + 12, ay + 6, sprintf("%s: %s, %s %d", tr("Beacon"),
                         d?.me ?? zig_name(), tr("Channel"), d?.ch ?? zig_cfg().ch),
                         C.green, C.widget, 1);
            let more = length(rows) > ZIG_ROWS;
            let show = more ? ZIG_ROWS - 1 : length(rows);
            let off = (st.zig?.poff ?? 0) % length(rows);
            let ap = IS_ALMONDPLUS;
            for (let k = 0; k < show; k++) {
                let n = rows[(off + k) % length(rows)], y = ay + 6 + k * ZIG_ROW_STEP;
                let fresh = n.self || n.age < 30;
                // Цвет говорит сам: синий - координатор (и когда это мы тоже),
                // зелёный - этот аппарат, белый - живой сосед, тусклый - давно
                // не слышно. Подпись «это устройство» лишняя.
                let col = n.coord ? C.cyan
                        : (n.self ? C.green : (fresh ? C.white : C.dim));
                if (n.coord) icon_home(GX + 12, y - 1, C.cyan, C.widget);
                lcd_text(GX + 26, y, tcut(n.name, ap ? 20 : 12), col, C.widget, 1);
                if (n.self) continue;
                let zc = fresh ? zig_rssi_col(n.rssi) : C.dim;
                seg_bar(GX + (ap ? 170 : 110), y, ap ? 120 : 60, 7, zig_rssi_bar(n.rssi),
                        zc, C.btn, "zl" + n.name);
                lcd_text(GX + (ap ? 310 : 180), y, sprintf("%d dBm", n.rssi), zc, C.widget, 1);
                lcd_text(GX + (ap ? 390 : 250), y, sprintf("%d %s", n.age, tr("sec")), C.dim, C.widget, 1);
            }
            if (more)
                lcd_text(GX + 26, ay + 6 + show * ZIG_ROW_STEP,
                         sprintf("%s %d", tr("more devices"), length(rows) - show),
                         C.orange, C.widget, 1);
        }
    }

    let labels = [ tr("Air"), tr("Peers"), tr("Settings") ];
    for (let i = 0; i < 3; i++) {
        let b = zig_btn(i);
        let on = (i == 0 && z.mode == "escan") || (i == 1 && z.mode == "peers");
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, on ? C.green : C.border);
        if (IS_ALMONDPLUS)
            lcd_text_thin(b.x + int(b.w / 2), b.y + int((b.h - 16) / 2), labels[i],
                          on ? C.white : C.gray, C.widget, 2, "c", 1);
        else
            lcd_text(b.x + int((b.w - twpx(labels[i], 1)) / 2), b.y + 12, labels[i],
                     on ? C.white : C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

function zig_peer_row(i) {
    return { x: GX, y: GY + 32 + i * 20, w: GW, h: 18 };
}

let A_CYAN = "#58A6FF", A_GREEN = "#10B981", A_ORANGE = "#E8853A",
    A_PURPLE = "#A371F7", A_TEAL = "#39C5CF", A_PINK = "#DB61A2";


function dash_card(b, o, acc) {
    lcd_rect(b.x, b.y, b.w, b.h, o.card);
    astripe(b.x, b.y, b.h, o.mono ?? (acc ?? C.dim));
    dash_glow(b, o, acc);
}

// Текст на карточках рисуем ПРОЗРАЧНЫМ: под ним лежит свечение угла, и
// непрозрачный фон вырезал бы в нём прямоугольники. Кадр всегда собирается
// заново, поэтому следов от прошлого текста не остаётся.
function dash_lab(b, o, s) {
    lcd_text(b.x + 12, b.y + 6, s, o.dim, "none", 1);
}

function dash_right(b, o, y, s, col) {
    lcd_text_r(b.x + b.w - 11, y, s, o.mono ?? (col ?? o.dim), "none", 1);
}

function dash_val(b, o, s, col) {
    // Размер выбирает рендерер: он мерит строку настоящим шрифтом. Раньше
    // здесь стояла прикидка «знак на 12», и адреса уезжали в мелкий шрифт,
    // хотя помещались.
    lcd_text_fit(b.x + 12, b.y + TILE_TTL_Y, s, o.mono ?? (col ?? o.fg), "none", 2, b.w - 20);
}

function dash_sub(b, o, s) {
    lcd_text(b.x + 12, b.y + b.h - TILE_BOT_OFF, s, o.dim, "none", 1);
}

function dash_bar(b, o, pct, col, key) {
    seg_bar(b.x + 12, b.y + b.h - 12, b.w - 24, 5, pct, o.mono ?? col,
            o.mono ? "#0A2A16" : C.btn, key);
}

function dash_simple(b, o, acc, label, val, sub, col) {
    dash_card(b, o, acc);
    dash_lab(b, o, label);
    dash_val(b, o, val, col);
    if (sub != null && sub != "") dash_sub(b, o, sub);
}

// Несущие агрегации: показываем ВСЕ настроенные (и спящие тоже, как 5gmodem),
// а красит их вызывающий - активные акцентом, спящие приглушённо. PCC всегда
// активна, SCC - по своему state из телеметрии.
function carrier_segs(l) {
    let c = l.cell ?? {};
    let segs = [];
    let pcc = l.band ?? "";
    if (pcc != "" && pcc != "-") push(segs, { t: pcc, on: true });
    let sc = [ [ c.s1band, c.s1state ], [ c.s2band, c.s2state ], [ c.s3band, c.s3state ] ];
    for (let s in sc) {
        let bnd = s[0] ?? "";
        if (bnd == "" || bnd == "-") continue;
        push(segs, { t: bnd, on: (s[1] ?? "") == "activated" });
    }
    return segs;
}

// Ширина цепочки несущих при размере шрифта sz (знак = sz*6, «+» - один знак).
function ca_width(segs, sz) {
    let cw = fsz(sz) * 6, total = 0;
    for (let i = 0; i < length(segs); i++) {
        if (i > 0) total += cw;
        total += tlen(segs[i].t) * cw;
    }
    return total;
}

// Рисует цепочку несущих слева от x: каждый сегмент своим цветом (активный con,
// спящий coff), разделители «+» - тоже coff. Возвращает нарисованную ширину.
function draw_ca(x, y, segs, sz, bg, con, coff) {
    let cw = fsz(sz) * 6, cx = x;
    for (let i = 0; i < length(segs); i++) {
        if (i > 0) { lcd_text(cx, y, "+", coff, bg, sz); cx += cw; }
        lcd_text(cx, y, segs[i].t, segs[i].on ? con : coff, bg, sz);
        cx += tlen(segs[i].t) * cw;
    }
    return cx - x;
}

function dash_gauge(b, o, acc, label, val, pct, col) {
    dash_card(b, o, acc);
    dash_lab(b, o, label);
    dash_val(b, o, val, col);
    dash_bar(b, o, pct, col, sprintf("g%d_%d_%s", b.x, b.y, label));
}

function dash_sig_pct(d) {
    let sp = int(+(d?.lte?.signal ?? 0));
    if (sp > 0) return clampi(sp, 0, 100);
    let rsrp = int(+(d?.lte?.rsrp ?? d?.uqmi?.rsrp ?? 0));
    return rsrp != 0 ? clampi(int(MET.rsrp.bar(rsrp)), 0, 100) : -1;
}

function dash_lvl_col(pct) {
    return pct < 0 ? C.dim : (pct >= 60 ? C.green : (pct >= 30 ? C.orange : C.red));
}

// Три ряда карточек растянуты на всю свободную высоту: раньше шаг и высота
// были фиксированными, блок кончался на 186-й строке, и под ним оставалась
// пустая полоса в два десятка пикселей перед кнопками.
function zp_box(c, r, cw) {
    let u = int((GW - 18) / 4);
    let top = GY, bot = BACK_Y - 8;
    let h = int((bot - top - 2 * 7) / 3);
    return { x: GX + c * (u + 6), y: top + r * (h + 7),
             w: cw * u + (cw - 1) * 6, h: h };
}

// Кнопки соседа - такие же карточки сетки, как всё остальное: плашка,
// акцентная полоска СЛЕВА, а не сверху. Навигация - третья такая же карточка
// со своим приглушённым акцентом.
// Нижний ряд соседа - три отдельные кнопки в ряд: команда модему, возврат,
// команда роутеру. Ширина и зазор те же, что у карточек сетки, поэтому ряд
// читается как три кнопки, а не как поделённая надвое полоса. Возврат - в
// средней, то есть ровно по центру экрана, как на всех остальных страницах.
function zp_act(i) {
    let w = int((GW - 2 * GG) / 3);
    return { x: GX + i * (w + GG), y: BACK_Y + 2, w: w, h: BACK_H - 4 };
}

function draw_zigpeer_page() {
    lcd_clear(C.bg);
    let d = zig_json(ZIG_PEERS);
    let peers = type(d?.peers) == "array" ? d.peers : [];
    let n = peers[st.zig?.peer ?? 0];
    if (n == null) {
        draw_header(tr("Peers"));
        lcd_text(GX + 12, GY + 20, tr("no peers heard"), C.ontop_dim, C.bg, 2);
        draw_back();
        lcd_flush();
        return;
    }
    draw_header(tcut(n.name ?? "?", 18));

    let o = { card: C.widget, dim: C.dim, fg: C.white, bg: C.bg };
    let m = n.m ?? {};

    let b = zp_box(0, 0, 2);
    let sp = m.sig != null ? int(+m.sig) : -1;
    let scol = dash_lvl_col(sp);
    let oper = m.oper != null && m.oper != "" ? m.oper : tr("Signal");
    dash_gauge(b, o, scol, tcut(oper, 16), sp >= 0 ? sprintf("%d%%", sp) : "--",
               sp >= 0 ? sp : 0, scol);
    if (m.rsrp != null) dash_right(b, o, b.y + 6, sprintf("%d dBm", int(+m.rsrp)), A_CYAN);

    b = zp_box(2, 0, 1);
    let von = int(+(m.vpn ?? 0)) == 1;
    dash_simple(b, o, von ? A_PURPLE : C.dim, "VPN", von ? tr("on") : tr("off"), null,
                von ? A_PURPLE : o.dim);

    b = zp_box(3, 0, 1);
    let pc = m.batt != null ? int(+m.batt) : -1;
    let bcol = pc < 0 ? C.dim : (pc >= 40 ? C.green : (pc >= 15 ? C.orange : C.red));
    dash_gauge(b, o, bcol, tr("Battery"),
               pc >= 0 ? sprintf("%d%%%s", pc, int(+(m.chg ?? 0)) == 1 ? "+" : "") : "--",
               pc >= 0 ? pc : 0, bcol);

    b = zp_box(0, 1, 1);
    let ms = m.ping != null ? int(+m.ping) : -1;
    let pcol = ms < 0 ? C.dim : (ms < 80 ? C.green : (ms < 250 ? C.orange : C.red));
    dash_simple(b, o, pcol, tr("Ping"), ms >= 0 ? sprintf("%d", ms) : "--", tr("ms"), pcol);

    b = zp_box(1, 1, 1);
    let cp = m.cpu != null ? int(+m.cpu) : -1;
    let ccol = cp < 0 ? C.dim : (cp >= 85 ? C.orange : C.cyan);
    dash_gauge(b, o, ccol, "CPU", cp >= 0 ? sprintf("%d%%", cp) : "--",
               cp >= 0 ? cp : 0, ccol);

    b = zp_box(2, 1, 1);
    let mm = m.mem != null ? int(+m.mem) : -1;
    let mcol = mm < 0 ? C.dim : (mm >= 85 ? C.orange : C.cyan);
    dash_gauge(b, o, mcol, tr("Memory"), mm >= 0 ? sprintf("%d%%", mm) : "--",
               mm >= 0 ? mm : 0, mcol);

    b = zp_box(3, 1, 1);
    let tv = m.temp != null ? int(+m.temp) : 0;
    let tcol = tv == 0 ? C.dim : (tv >= 70 ? C.red : A_ORANGE);
    dash_simple(b, o, tcol, tr("Temp"), tv != 0 ? sprintf("%d°C", tv) : "--",
                tr("Modem"), tcol);

    b = zp_box(0, 2, 2);
    let fresh = int(+(n.age ?? 99)) < 30;
    let lq = int(+(n.lqi ?? 0));
    let zr = int(+(n.rssi ?? 0));
    let zcol = fresh ? zig_rssi_col(zr) : C.dim;
    dash_gauge(b, o, zcol, tr("link"), sprintf("%d dBm", zr),
               zig_rssi_bar(zr), zcol);
    dash_right(b, o, b.y + 6, sprintf("LQI %d   %d %s", lq,
                                      int(+(n.age ?? 0)), tr("sec")));

    b = zp_box(2, 2, 1);
    // Клетка соседа такая же узкая, как в виджетах: полная форма «1 день 0ч 3м»
    // вылезала за карточку, поэтому здесь тот же компактный вид.
    dash_simple(b, o, A_PURPLE, tr("Uptime short"),
                m.up != null ? fmt_uptime_c(int(+m.up) * 60) : "--", null, o.fg);

    b = zp_box(3, 2, 1);
    let nc = m.wifi != null ? int(+m.wifi) : -1;
    let wcol = nc > 0 ? A_TEAL : C.dim;
    dash_simple(b, o, wcol, "Wi-Fi", nc >= 0 ? sprintf("%d", nc) : "--", tr("clients"), wcol);

    // VPN переключается тапом по самой карточке, отдельной кнопки нет.
    // Три кнопки: «ребут модема», возврат, «ребут роутера». Раньше было
    // «Модем» и «Ребут» - непонятно, что кому перезагружают.
    let acts = [ [ tr("Reboot modem"), A_ORANGE ], [ null, C.gray ],
                 [ tr("Reboot router"), "#F0736B" ] ];
    for (let i = 0; i < 3; i++) {
        let a = zp_act(i);
        gcard(a.x, a.y, a.w, a.h, acts[i][1]);
        if (acts[i][0] == null) {
            draw_back_arrow(a.x + int(a.w / 2), a.y + int((a.h - 14) / 2));
            continue;
        }
        let w1 = split(acts[i][0], " ");
        lcd_text(a.x + 10, a.y + int((a.h - 18) / 2), w1[0], acts[i][2] ?? C.white, C.widget, 1);
        lcd_text(a.x + 10, a.y + int((a.h - 18) / 2) + 10,
                 length(w1) > 1 ? w1[1] : "", acts[i][1], C.widget, 1);
    }
    lcd_flush();
}
let ZIG_POWERS = [ -8, 0, 3, 5, 8 ];

let ZS_ACT_H = IS_ALMONDPLUS ? 40 : 32;
let ZS_VAL_X = IS_ALMONDPLUS ? 150 : 100;

function zigset_row(i) {
    if (!IS_ALMONDPLUS) return { x: GX, y: GVT + i * 25, w: GW, h: 23 };
    let v = vfit(GVT, GVB - ZS_ACT_H - GG - 18, 5);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}

// Строка подсказки под рядами: раньше стояла на 164, а ряд кнопок начинается
// на 170 - подсказка уходила под них.
function zigset_hint_y() { return IS_ALMONDPLUS ? GVB - ZS_ACT_H - GG - 13 : GVT + 5 * 25 + 4; }

function zigset_pm(i, plus) {
    let r = zigset_row(i);
    let w = r.h - 4, y = r.y + 2;
    let px = r.x + r.w - 6 - w;
    return { x: plus ? px : px - w - 5, y: y, w: w, h: w };
}

function zigset_act(i) {
    let w = int((GW - 3 * GG) / 4);
    return { x: GX + i * (w + GG), y: GVB - ZS_ACT_H, w: w, h: ZS_ACT_H };
}

function zig_btn_fx(b, label, accent) {
    lcd_rect(b.x, b.y, b.w, b.h, C.press);
    astripe(b.x, b.y, b.h, accent ?? C.gray);
    let inner = b.w - 12;
    let w = twpx(label, 1);
    if (IS_ALMONDPLUS)
        lcd_text_thin(b.x + 5 + int(inner / 2), b.y + int((b.h - 16) / 2), tcut(label, int(inner / 12)),
                      C.white, C.press, 2, "c", 1);
    else
        lcd_text(b.x + 7 + (w < inner ? int((inner - w) / 2) : 0), b.y + 12,
                 tcut(label, int(inner / 6)), C.white, C.press, 1);
    lcd_flush();
}

function mqtt_cfg() {
    let g = function(k, d) {
        let v = ucur ? ucur.get("almond3s", "mqtt", k) : null;
        return (v == null || v == "") ? d : v;
    };
    return {
        on:   g("enabled", "0") == "1",
        host: g("host", ""),
        port: g("port", "1883"),
        user: g("user", ""),
        pass: g("pass", ""),
        period: g("period", "60"),
        prefix: g("prefix", "almond3s"),
        node: g("node", ""),
        homed_prefix: g("homed_prefix", "homed"),
        control: g("control", "off"),
        retain: g("retain", "0") == "1",
    };
}

// Управление органами: выключено, темы Home Assistant, темы HOMEd или оба
// набора сразу. Ходит по кругу тапом, отдельного экрана не заслуживает.
let MQTT_CTL = [ "off", "ha", "homed", "both" ];
function mqtt_ctl_label(v) {
    if (v == "ha") return "HA";
    if (v == "homed") return "HOMEd";
    if (v == "both") return tr("both");
    return tr("off");
}

function mqtt_set(k, v) {
    if (!ucur) return;
    ucur.set("almond3s", "mqtt", k, sprintf("%s", v));
    ucur.commit("almond3s");
}

function mqtt_row(i) {
    if (!IS_ALMONDPLUS) {
        if (i == 0) return { x: GX, y: GY, w: GW, h: 26 };
        let k = i - 1;
        return { x: GX + (k % 2) * (GCOL + GG), y: 52 + int(k / 2) * 28, w: GCOL, h: 26 };
    }
    let v = vfit(GVT, GVB, 6);
    if (i == 0) return { x: GX, y: v.y0, w: GW, h: v.h };
    let k = i - 1;
    return { x: GX + (k % 2) * (GCOL + GG), y: v.y0 + (1 + int(k / 2)) * v.step, w: GCOL, h: v.h };
}

function mqtt_ctl_btn() {
    if (!IS_ALMONDPLUS) return { x: GX + GCOL + GG, y: 136, w: GCOL, h: 26 };
    let r = mqtt_row(8);
    return { x: r.x, y: r.y, w: r.w, h: r.h };
}

// Нижняя строка делится: слева выключатель публикации, справа retain - он
// прижат к ней по смыслу, оба про то, как мы отдаём состояние наружу.
function mqtt_toggle_btn() {
    if (!IS_ALMONDPLUS) return { x: GX, y: BACK_Y - 40, w: 200, h: 32 };
    let r = mqtt_row(9);
    return { x: GX, y: r.y, w: GW - 150 - GG, h: r.h };
}

function mqtt_retain_btn() {
    if (!IS_ALMONDPLUS) return { x: GX + 208, y: BACK_Y - 40, w: 96, h: 32 };
    let r = mqtt_row(9);
    return { x: GX + GW - 150, y: r.y, w: 150, h: r.h };
}

function draw_mqtt_page() {
    lcd_clear(C.bg);
    draw_header("MQTT");
    // Конфиг могли поправить снаружи (uci из шелла, uci-defaults), а курсор
    // держит прочитанное в памяти - страница показывала старые значения и
    // «Сначала задайте адрес брокера» при уже работающей публикации.
    if (ucur) ucur.load("almond3s");
    let c = mqtt_cfg();
    for (let i = 0; i < length(MQTT_FIELDS); i++) {
        let r = mqtt_row(i), f = MQTT_FIELDS[i];
        let v = c[f.key] ?? "";
        let shown = f.key == "pass" && v != ""
            ? substr("************", 0, length(v) > 12 ? 12 : length(v))
            : v;
        let ap = IS_ALMONDPLUS;
        let ry1 = ap ? mid_y(r, 1) : r.y + 10;
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        astripe(r.x, r.y, r.h, v != "" ? C.cyan : C.dim);
        lcd_text(r.x + 12, ry1, tr(f.label), C.gray, C.widget, 1);
        if (i == 0)
            lcd_text(r.x + 96, ap ? (shown != "" ? mid_y(r, 2) : ry1) : r.y + 6,
                     shown != "" ? tcut(shown, 20) : tr(f.hint),
                     shown != "" ? C.white : C.dim, C.widget, shown != "" ? 2 : 1);
        else
            lcd_text_r(r.x + r.w - 10, ry1, shown != "" ? tcut(shown, ap ? 24 : 12) : tr(f.hint),
                       shown != "" ? C.white : C.dim, C.widget, 1);
    }

    let cb = mqtt_ctl_btn(), con = (c.control != "off");
    lcd_rect(cb.x, cb.y, cb.w, cb.h, C.widget);
    astripe(cb.x, cb.y, cb.h, con ? C.green : C.dim);
    let cy1 = IS_ALMONDPLUS ? mid_y(cb, 1) : cb.y + 10;
    lcd_text(cb.x + 12, cy1, tr("Control"), C.gray, C.widget, 1);
    lcd_text_r(cb.x + cb.w - 10, cy1, mqtt_ctl_label(c.control),
               con ? C.green : C.dim, C.widget, 1);
    let rb2 = mqtt_retain_btn();
    lcd_rect(rb2.x, rb2.y, rb2.w, rb2.h, C.widget);
    astripe(rb2.x, rb2.y, rb2.h, c.retain ? C.cyan : C.dim);
    if (IS_ALMONDPLUS) {
        lcd_text(rb2.x + 12, mid_y(rb2, 1), "Retain", C.gray, C.widget, 1);
        lcd_text_r(rb2.x + rb2.w - 10, mid_y(rb2, 1), c.retain ? tr("on") : tr("off"),
                   c.retain ? C.cyan : C.dim, C.widget, 1);
    } else {
        lcd_text(rb2.x + 12, rb2.y + 5, "Retain", C.gray, C.widget, 1);
        lcd_text(rb2.x + 12, rb2.y + 18, c.retain ? tr("on") : tr("off"),
                 c.retain ? C.cyan : C.dim, C.widget, 1);
    }

    let b = mqtt_toggle_btn();
    let can = c.host != "";
    lcd_rect(b.x, b.y, b.w, b.h, C.widget);
    astripe(b.x, b.y, b.h, c.on ? C.green : (can ? C.gray : C.dim));
    let lab = c.on ? tr("publishing on") : (can ? tr("publishing off") : tr("set broker address first"));
    lcd_text_c(b.x + int(b.w / 2), IS_ALMONDPLUS ? mid_y(b, 1) : b.y + 12, lab,
             c.on ? C.green : (can ? C.white : C.dim), C.widget, 1);
    draw_back();
    lcd_flush();
}

let ZIG_FW_DIR = "/usr/share/almond3s/zigbee";
let ZIG_FLASH_LOG = "/tmp/lcd_zig_flash.log";

function zig_fw_file() {
    let d = fs.lsdir(ZIG_FW_DIR);
    if (type(d) != "array") return null;
    for (let i = 0; i < length(d); i++)
        if (match(d[i], /\.ebl$/)) return ZIG_FW_DIR + "/" + d[i];
    return null;
}

let ZIG_JOIN = "/tmp/lcd_zig_join.json";

function zig_join_msg() {
    let j = zig_json(ZIG_JOIN);
    if (j == null) return null;
    let st2 = int(+(j.stack ?? -1));
    if (st2 == 144) return tr("joined the network");
    if (st2 == 171) return sprintf("%s: %s", tr("join failed"), tr("network not found"));
    if (st2 == 173) return sprintf("%s: %s", tr("join failed"), tr("key not received"));
    if (st2 == 148) return sprintf("%s: %s", tr("join failed"), tr("rejected"));
    if (st2 >= 0) return sprintf("%s (%d)", tr("join failed"), st2);
    return null;
}

function zig_flash_progress() {
    let raw = fs.readfile(ZIG_FLASH_LOG);
    if (!raw) return null;
    if (match(raw, /Serial upload complete/)) return { done: true, pct: 100 };
    let all = match(raw, /блоков отправлено ([0-9]+) из ([0-9]+)/g);
    if (type(all) == "array" && length(all) > 0) {
        let m = all[length(all) - 1];
        return { done: false, pct: int(+m[1] * 100 / +m[2]) };
    }
    if (match(raw, /загрузчик на связи/)) return { done: false, pct: 0 };
    return { done: false, pct: -1 };
}

// Список сетей в эфире. По стандарту вступают не в «набранный номер», а в
// сеть, которая слышна и открыта на приём: её и выбираем пальцем.
function zignet_row(i) {
    if (!IS_ALMONDPLUS) return { x: GX, y: GVT + i * 30, w: GW, h: 26 };
    let v = vfit(GVT, GVB, 5);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}

// Одна сеть - одна строка. На запрос маячка отвечает КАЖДЫЙ роутер сети, и
// сканер видит её столько раз, сколько узлов её услышало: в списке это
// выглядело как несколько одинаковых сетей. Схлопываем по PAN, берём лучший
// сигнал и считаем «приём открыт», если открыт хоть у одного узла - именно к
// нему вступление и пойдёт.
function zignet_list() {
    let d = zig_json(ZIG_ASCAN);
    let raw = type(d?.networks) == "array" ? d.networks : [];
    let out = [];
    for (let n in raw) {
        let pan = int(+(n.pan ?? 0));
        if (pan <= 0 || pan == 65535) continue;
        let found = null;
        for (let o in out) if (o.pan == pan) found = o;
        if (found == null) {
            push(out, { pan: pan, ch: int(+(n.ch ?? 0)), rssi: int(+(n.rssi ?? -127)),
                        join: int(+(n.join ?? 0)), nodes: 1 });
            continue;
        }
        found.nodes++;
        if (int(+(n.join ?? 0)) > 0) { found.join = 1; found.ch = int(+(n.ch ?? found.ch)); }
        if (int(+(n.rssi ?? -127)) > found.rssi) found.rssi = int(+(n.rssi ?? -127));
    }
    return out;
}

function draw_zignets_page() {
    zig_cfg_reload();
    lcd_clear(C.bg);
    draw_header(tr("Zigbee networks"));
    if (zig_busy()) {
        lcd_text(GX + 12, GVT + 30, tr("Scanning..."), C.cyan, "none", 2);
        draw_back();
        lcd_flush();
        return;
    }
    if (st.zig?.restart) { st.zig.restart = false; zig_beacon_start(); }
    let nets = zignet_list();
    if (length(nets) == 0) {
        lcd_text(GX + 12, GVT + 20, tr("no networks"), C.ontop_dim, "none", 2);
        lcd_text(GX + 12, GVT + 46, tr("open joining on the hub"), C.dim, "none", 1);
    }
    for (let i = 0; i < length(nets) && i < 5; i++) {
        let n = nets[i], b = zignet_row(i);
        let open = int(+(n.join ?? 0)) > 0;
        gcard(b.x, b.y, b.w, b.h, open ? C.green : C.dim);
        let ap = IS_ALMONDPLUS;
        lcd_text(b.x + 12, mid_y(b, 2), sprintf("%04X", int(+(n.pan ?? 0))),
                 C.white, C.widget, 2);
        lcd_text(b.x + (ap ? 110 : 76), mid_y(b, 1), sprintf("%s %d", tr("ch"), int(+(n.ch ?? 0))),
                 C.gray, C.widget, 1);
        lcd_text(b.x + (ap ? 190 : 132), mid_y(b, 1), sprintf("%d dBm", int(+(n.rssi ?? 0))),
                 C.gray, C.widget, 1);
        if (int(+(n.nodes ?? 1)) > 1)
            lcd_text(b.x + (ap ? 280 : 190), mid_y(b, 1),
                     sprintf("%d %s", int(+n.nodes), tr("nodes")), C.dim, C.widget, 1);
        // Подпись «приём открыт/закрыт» убрана: это флаг из маячка, и он
        // НЕ предсказывает результат - аппарат, который уже был в этой сети,
        // возвращается в неё и при закрытом окне. Надпись обещала одно, а
        // происходило другое. Открытый приём отмечаем только как подсказку.
        if (open)
            lcd_text_r(b.x + b.w - 12, mid_y(b, 1), tr("joining open"),
                       C.green, C.widget, 1);
    }
    draw_back();
    lcd_flush();
}

function draw_zigset_page() {
    zig_cfg_reload();
    lcd_clear(C.bg);
    draw_header(tr("Zigbee"));
    // Страница показывает ОДНО значение - то, что в конфиге, его же крутят
    // «+/-». Конфиг подтягивается к живой сети при входе на страницу и после
    // «Поднять»/«Вступить», поэтому расходиться им негде.
    zig_sync_cfg();
    let c = zig_cfg();
    let rows = [
        [ tr("PAN ID"), sprintf("%04X", c.pan) ],
        [ tr("Channel"), sprintf("%d", c.ch) ],
        [ tr("TX power"), sprintf("%d dBm", c.power) ],
    ];
    let bb = zigset_row(3);
    let mesh = zig_mode() == "mesh";
    lcd_rect(bb.x, bb.y, bb.w, bb.h, C.widget);
    astripe(bb.x, bb.y, bb.h, c.beacon ? C.green : C.dim);
    lcd_text(bb.x + 12, mid_y(bb, 1), tr("Telemetry"), C.gray, C.widget, 1);
    // Третье состояние называем словом, а не «выкл»: строка про телеметрию,
    // и «выключена» читается однозначно.
    let tval = c.beacon ? (mesh ? tr("network") : tr("beacon")) : tr("off fem");
    lcd_text(bb.x + ZS_VAL_X, mid_y(bb, 2), tval,
             c.beacon ? (mesh ? C.cyan : C.green) : C.gray, C.widget, 2);
    let hint2 = c.beacon ? (mesh ? tr("via Zigbee network") : tr("standalone, no network"))
                         : tr("chip free");
    // Подсказку режем по остатку строки: длинная налезала на значение.
    let hx = bb.x + ZS_VAL_X + twpx(tval, 2) + 8;
    lcd_text_r(bb.x + bb.w - 11, mid_y(bb, 1),
               tcut(hint2, int((bb.x + bb.w - 11 - hx) / 6)), C.dim, C.widget, 1);
    for (let i = 0; i < length(rows); i++) {
        let r = zigset_row(i);
        lcd_rect(r.x, r.y, r.w, r.h, C.widget);
        astripe(r.x, r.y, r.h, C.cyan);
        lcd_text(r.x + 12, mid_y(r, 1), rows[i][0], C.gray, C.widget, 1);
        lcd_text(r.x + ZS_VAL_X, mid_y(r, 2), rows[i][1], C.white, C.widget, 2);
        let m = zigset_pm(i, false), pl = zigset_pm(i, true);
        lcd_rect(m.x, m.y, m.w, m.h, C.btn);
        rborder(m.x, m.y, m.w, m.h, C.border);
        draw_pm(m, false, C.accent);
        lcd_rect(pl.x, pl.y, pl.w, pl.h, C.btn);
        rborder(pl.x, pl.y, pl.w, pl.h, C.border);
        draw_pm(pl, true, C.accent);
    }

    // Ключ сети живёт в чипе и раздаётся вступающим автоматически, как в
    // стандарте. Показываем ОТПЕЧАТОК настоящего сетевого ключа (его пишет
    // телеметрия), а не значение из конфига: по нему видно, одна ли сеть у
    // двух аппаратов. Ключ из конфига теперь только запасной путь.
    let kb = zigset_row(4);
    let nkey = zig_json(ZIG_PEERS)?.nkey ?? "";
    lcd_rect(kb.x, kb.y, kb.w, kb.h, C.widget);
    astripe(kb.x, kb.y, kb.h, nkey != "" ? C.cyan : C.dim);
    lcd_text(kb.x + 12, mid_y(kb, 1), tr("Net key"), C.gray, C.widget, 1);
    lcd_text(kb.x + ZS_VAL_X, mid_y(kb, 2), nkey != "" ? nkey : tr("no data"),
             nkey != "" ? C.white : C.dim, C.widget, 2);

    let stt = zig_json("/tmp/lcd_zig_state.json");
    if (st.zig?.form_msg && stt != null && (time() - (st.zig.msg_ts ?? 0)) > 3)
        st.zig.form_msg = null;
    let hnode = zig_live_node() ?? (stt?.state == 2 ? int(+(stt?.node ?? 0)) : 0);
    let hint = st.zig?.form_msg ?? (hnode > 0
        ? sprintf("%s %04X, %s", tr("own network"),
                  zig_live_pan() ?? int(+(stt?.pan ?? c.pan)),
                  hnode == 1 ? tr("coordinator") : tr("router role"))
        : sprintf("%s: %s", tr("own network"), tr("off")));
    let jm = zig_join_msg();
    if (jm != null && !st.zig?.flashing) hint = jm;
    if (st.zig?.flashing) {
        let pr = zig_flash_progress();
        hint = pr == null ? tr("Updating chip...")
             : (pr.done ? tr("Chip updated")
                        : (pr.pct >= 0 ? sprintf("%s %d%%", tr("Updating chip..."), pr.pct)
                                       : tr("Updating chip...")));
    } else if (st.zig?.flash_done && (time() - st.zig.flash_done) < 20) {
        hint = tr("Chip updated");
    }
    lcd_text(GX + 12, zigset_hint_y(), hint, C.ontop_dim, C.bg, 1);
    let pj = zig_json(ZIG_PEERS);
    let vs = null, vnum = 0;
    let cm = pj?.chip ? match(pj.chip, /EZSP v([0-9]+) ([0-9.]+)/) : null;
    if (cm) { vnum = int(+cm[1]); vs = sprintf("EZSP v%s  %s", cm[1], cm[2]); }
    else {
        let inf = zig_json(ZIG_INFO);
        if (inf?.ezsp != null) {
            vnum = int(+inf.ezsp);
            vs = sprintf("EZSP v%d  %s", vnum, inf.stack ?? "");
        }
    }
    if (vs != null)
        lcd_text_r(GX + GW - 11, zigset_hint_y(), vs,
                 vnum >= 8 ? C.green : C.orange, C.bg, 1);

    // Роль и членство - из живых данных (телеметрия или файл состояния), а не
    // из одного файла состояния: его пишут только цепочки команд, и после
    // перезагрузки он от прошлой жизни - кнопка показывала «Вступить» узлу,
    // который давно в сети.
    let lnode = zig_live_node();
    let joined = lnode != null ? lnode > 0 : stt?.state == 2;
    let mq = mqtt_cfg();
    let iscoord = lnode != null ? lnode == 1 : (joined && int(+(stt?.node ?? 0)) == 1);
    let pleft = zig_permit_left();
    let popen = pleft > 0;
    // Координатор, у которого настройки разошлись с живой сетью, должен уметь
    // поднять её заново одним нажатием: раньше для смены PAN приходилось
    // сперва «Выйти», а кнопка молча оставалась «Приёмом». Пока идёт команда,
    // живые файлы ещё от прошлой сети - расхождение в этот момент не считаем,
    // иначе сразу после «Поднять» кнопка мигала «Поднять» вместо отсчёта.
    let lp = zig_live_pan() ?? 0, lc2 = zig_live_ch() ?? 0;
    let changed = !zig_held() && iscoord && lp > 0 && (lp != c.pan || (lc2 > 0 && lc2 != c.ch));
    let names = [ (iscoord && !changed)
                      ? (popen ? sprintf("%d %s", pleft, tr("sec")) : tr("Permit short"))
                      : tr("Form short"),
                  joined ? tr("Leave short") : tr("Join short"),
                  tr("Flash short"), mq.on ? "MQTT+" : "MQTT" ];
    let accents = [ changed ? C.green : (popen ? C.orange : C.green),
                    joined ? C.red : A_PURPLE, C.cyan,
                    mq.on ? C.green : (mq.host != "" ? C.gray : C.dim) ];
    let fw = zig_fw_file();
    for (let i = 0; i < 4; i++) {
        let b = zigset_act(i);
        let dim = (i == 2 && fw == null) || (i == 3 && mq.host == "");
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, dim ? C.dim : accents[i]);
        let inner = b.w - 12;
        let lab = tcut(names[i], int(inner / 6));
        let lw = twpx(lab, 1);
        if (IS_ALMONDPLUS)
            lcd_text_thin(b.x + 5 + int(inner / 2), b.y + int((b.h - 16) / 2), lab,
                          dim ? C.dim : C.white, C.widget, 2, "c", 1);
        else
            lcd_text(b.x + 7 + (lw < inner ? int((inner - lw) / 2) : 0), b.y + 12, lab,
                     dim ? C.dim : C.white, C.widget, 1);
    }
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

let VPN_GPP = 4, VPN_MPP = 6;   // групп и серверов на страницу

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

let VPN_TOG_H = IS_ALMONDPLUS ? 52 : 40;
function vpn_tog_rect()     { return { x: GX, y: GY, w: GW, h: VPN_TOG_H }; }
function vpn_group_rect(i) {
    if (!IS_ALMONDPLUS) return { x: GX, y: GY + 48 + i * 34, w: GW, h: 28 };
    let v = vfit(GY + VPN_TOG_H + GG, GVB, VPN_GPP);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}
function vpn_member_rect(i) {
    if (!IS_ALMONDPLUS) return { x: GX, y: GY + i * 24, w: GW, h: 22 };
    let v = vfit(GY, GVB, VPN_MPP);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}

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
    if (!IS_ALMONDPLUS) return { x: r.x + r.w - 50, y: r.y + int((r.h - 18) / 2), w: 44, h: 18 };
    return { x: r.x + r.w - 76, y: r.y + int((r.h - 26) / 2), w: 68, h: 26 };
}
function draw_dbtn(r, ms, key) {
    let b = vpn_dbtn(r), pinging = (st.vpn_ping?.key == key), o = pinging ? 1 : 0;
    let bg = pinging ? C.press : C.btn;
    lcd_rect(b.x, b.y, b.w, b.h, bg);
    if (!pinging) lcd_rect(b.x, b.y + b.h - 2, b.w, 2, C.border);   // кант «кнопки»
    let txt = pinging ? "..." : vpn_delay_txt(ms);
    let col = pinging ? C.cyan : vpn_delay_col(ms);
    lcd_text_c(b.x + int(b.w / 2) + o, b.y + int((b.h - 8) / 2) + 1 + o, txt, col, bg, 1);
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

// История замера посекундно: бэкенд обновляет кэш раз в секунду, мы берём
// оттуда живое значение текущей фазы. Массивы переживают уход со страницы -
// лежат в файле, иначе график пропадал при первом же «назад».
let SPD_HIST = "/tmp/almond3s_spdhist.json";
// Шаг анимации замера. 250мс давали пять рывков в секунду; 100мс - предел
// панели (кадр уходит ~70мс), поэтому 120.
let SPD_TICK = 80;

// Монотонные миллисекунды: заливку ведём по часам, а не по числу тиков.
// Тик плавает (кадр сам по себе занимает время), и счёт тиками то отставал от
// бэкенда, то догонял его скачком - это и читалось как рывки.
function now_ms() {
    let c = clock(true);
    return c[0] * 1000 + int(c[1] / 1000000);
}

function spd_hist_clear() {
    st.spd_dh = []; st.spd_uh = [];
    fs.unlink(SPD_HIST);
}

function spd_hist_join(a) {
    let out = [];
    for (let v in (a ?? [])) push(out, sprintf("%.2f", +v));
    return join(",", out);
}

// Новый прогон замечаем по переходу «стоит → идёт»: тест могли запустить и
// мимо нашей кнопки (LuCI, скрипт), а старые столбики рядом с новыми цифрами
// врут.
function spd_run_watch() {
    let r = int(+(st.spd?.running ?? 0)) > 0;
    if (r && !st.spd_was) spd_hist_clear();
    st.spd_was = r;
}

function spd_hist_save() {
    fs.writefile(SPD_HIST, sprintf('{"d":[%s],"u":[%s]}',
                                   spd_hist_join(st.spd_dh), spd_hist_join(st.spd_uh)));
}

function spd_hist_load() {
    if (length(st.spd_dh ?? []) > 0 || length(st.spd_uh ?? []) > 0) return;
    let raw = fs.readfile(SPD_HIST);
    if (!raw) return;
    try {
        let h = json(raw) ?? {};
        st.spd_dh = type(h.d) == "array" ? h.d : [];
        st.spd_uh = type(h.u) == "array" ? h.u : [];
    } catch (e) {}
}

// Точку в историю кладёт опрос кэша, по одной на секунду теста.
function spd_hist_tick() {
    let sp = st.spd ?? {};
    if (int(+(sp.running ?? 0)) <= 0) return;
    let up = (sp.phase == "up");
    let v = +((up ? sp.live_up : sp.live_down) ?? 0);
    if (v <= 0) return;
    let a = up ? (st.spd_uh ?? []) : (st.spd_dh ?? []);
    // Бэкенд обновляет отдачу раз в две секунды, а читаем мы раз в секунду -
    // и столбики шли парами одинаковой высоты. Повтор байт-в-байт это не
    // ровная скорость, а тот же самый замер: живая сеть двух одинаковых чисел
    // подряд не даёт. Такой повтор пропускаем - столбик = один замер.
    if (length(a) > 0 && +a[length(a) - 1] == v) return;
    push(a, v);
    if (length(a) > 60) a = slice(a, length(a) - 60);
    if (up) st.spd_uh = a; else st.spd_dh = a;
}

// Столбики скорости в свободной части строки. Шкала линейная по максимуму
// самого замера - логарифм тут врёт: у спидтеста важна форма провалов.
function spd_graph(x, y, w, h, data, color) {
    let n = length(data ?? []);
    if (n < 1) return;
    let mx = 0;
    for (let v in data) { let f = +v; if (f > mx) mx = f; }
    if (mx <= 0) return;
    lcd_text_r(x + w, y, sprintf("%.0f", mx), C.dim, "none", 1);
    let gy = y + 9, gh = h - 9;
    if (gh < 4) return;
    lcd_rect_raw(x, gy + gh, w, 1, C.border);
    // Сетка столбиков общая с прогрессбарами и остальными графиками.
    let g = seg_geom(w);
    for (let i = 0; i < g.n; i++) {
        let idx = n >= g.n ? n - g.n + i : int(i * n / g.n);
        let bh = int(+data[idx] * gh / mx);
        bh = int(bh / 2) * 2;
        if (bh < 2) bh = 2;
        lcd_rect_raw(x + i * g.pitch, gy + gh - bh, g.sz, bh, color);
    }
}

function speedtest_read() {
    let raw = fs.readfile(SPEED_CACHE);
    if (!raw) { st.spd = st.spd ?? {}; return; }
    try { st.spd = json(raw) ?? {}; } catch (e) {}
}

function speedtest_start() {
    spd_hist_clear();
    st.spd_was = true;
    system(SPEEDBIN + " start >/dev/null 2>&1 &");
    st.spd = { running: 1, service: st.spd?.service ?? "" };
    st.spd_poll = true;
    st.spd_ebase = 0; st.spd_tref = now_ms();   // сброс плавной доводки заливки
}

function speedtest_stop() {
    system(SPEEDBIN + " stop >/dev/null 2>&1 &");
}

function spd_num(v) { return (v == null) ? "—" : sprintf("%.1f", +v); }

function draw_tri_down(x, y, col) { for (let i = 0; i < 5; i++) lcd_rect(x + i, y + i, 9 - 2 * i, 1, col); }
function draw_tri_up(x, y, col)   { for (let i = 0; i < 5; i++) lcd_rect(x + 4 - i, y + i, 1 + 2 * i, 1, col); }

function spd_settings_btn() {
    let r = stack_rects([ 118, 40 ])[1];
    return { x: r.x + st.ox, y: r.y, w: r.w, h: r.h };
}

// Имя пресета по сохранённому адресу: на кнопке показываем выбранную пару,
// иначе, чтобы её увидеть, приходилось заходить внутрь.
function spd_preset_name(list, url) {
    if (url == null || url == "") return tr("by default");
    for (let e in list) if (e[1] == url) return e[0];
    return tr("custom");
}
function spd_card_rect() {
    let r = stack_rects([ 118, 40 ])[0];
    return { x: r.x + st.ox, y: r.y + st.oy, w: r.w, h: r.h };
}

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

function draw_speedtest_page() {
    // В покое (тест не идёт) подтягиваем последний результат из кэша - чтобы
    // карточка показывала прошлый замер при любом входе на страницу.
    if (!st.spd_poll) { speedtest_read(); spd_run_watch(); spd_hist_load(); }
    if (st.spd_cfg == null) spd_cfg_read();   // имена серверов для кнопки
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
    let frac = 0;
    if (running && st.spd_tref) {
        frac = (now_ms() - st.spd_tref) / 1000.0;
        // Дальше следующей секунды не убегаем: бэкенд обновляет elapsed раз в
        // секунду, и заливка, обогнавшая его, потом дёргалась назад.
        if (frac > 1) frac = 1;
        if (frac < 0) frac = 0;
    }
    let disp_e = (st.spd_ebase ?? 0) + frac;
    if (disp_e > secs) disp_e = secs;

    // База + заливка по фазе (тон = цвет фазы при ~16% над фоном виджета).
    // Рамка - не четыре тонких прямоугольника поверх плашки, а внешний
    // прямоугольник с полем внутри: тонкие полоски углов не скругляют, и
    // карточка замера торчала квадратной среди скруглённых.
    let bord = C.border;
    if (running) bord = up ? "#0095FF" : C.green;
    lcd_rect(cx, cy, cw, ch, bord);
    lcd_rect(cx + 2, cy + 2, cw - 4, ch - 4, C.widget);
    if (running && disp_e > 0) {
        let iw = cw - 4;
        let fw = int(iw * disp_e / secs); if (fw > iw) fw = iw;
        if (fw > 0) {
            if (up) lcd_rect(cx + 2 + iw - fw, cy + 2, fw, ch - 4, "#122E45");
            else    lcd_rect(cx + 2, cy + 2, fw, ch - 4, tint(C.green, 16, C.widget));
        }
    }

    // Строка 1: сервис слева, фаза справа.
    let svc = sp.service ?? "";
    if (sp.error == "no-curl") svc = tr("curl not installed");
    else if (svc == "") svc = tr("Speedtest");
    let ap = IS_ALMONDPLUS;
    lcd_text(cx + 12, cy + (ap ? 10 : 8), tcut(svc, 22), C.gray, "none", 2);
    let ph = running ? (up ? tr("Upload") : tr("Download"))
                     : (int(+(sp.ok ?? 0)) ? tr("Done") : (sp.cancelled ? tr("Stopped") : ""));
    if (ph != "")
        lcd_text_r(cx + cw - 12, cy + (ap ? 18 : 10),
                 ph, running ? (up ? "#0095FF" : C.green) : C.gray, "none", 1);

    // Значения: живое число - в текущей фазе, второе - последнее известное.
    let dl, ul, dl_hot, ul_hot;
    if (running && !up)     { dl = sp.live_down; ul = sp.up_mbps; dl_hot = true; }
    else if (running && up) { dl = sp.down_mbps; ul = sp.live_up; ul_hot = true; }
    else                    { dl = sp.down_mbps; ul = sp.up_mbps; }

    let ds = spd_num(dl), us = spd_num(ul);
    // Правая треть строки пустовала - туда уходит график своей фазы. Он
    // рисуется по ходу теста и остаётся на карточке после него.
    let gw = ap ? 200 : 108, gx = cx + cw - 12 - gw;
    let y1 = ap ? cy + 48 : cy + 34, y2 = ap ? cy + 100 : cy + 64;
    let gh = ap ? 42 : 26, gdy = ap ? -4 : -4;
    let uoff = ap ? fpx(3) - 10 : 8;
    draw_tri_down(cx + 14, y1 + (ap ? 14 : 8), C.green);
    lcd_text(cx + 30, y1, ds, dl_hot ? C.white : C.gray, "none", 3);
    lcd_text(cx + 30 + twpx(ds, 3) + 6, y1 + uoff, tr("Mbps"), C.dim, "none", 1);
    spd_graph(gx, y1 + gdy, gw, gh, st.spd_dh, C.green);

    draw_tri_up(cx + 14, y2 + (ap ? 14 : 6), "#0095FF");
    lcd_text(cx + 30, y2, us, ul_hot ? C.white : C.gray, "none", 3);
    lcd_text(cx + 30 + twpx(us, 3) + 6, y2 + uoff, tr("Mbps"), C.dim, "none", 1);
    spd_graph(gx, y2 + gdy, gw, gh, st.spd_uh, "#0095FF");

    // Строка 4: IP + пиксель-флаг страны. Флаг рисуем только когда код страны
    // уже приехал (гео-запрос отстаёт от старта) - иначе просто IP, без пустого
    // серого бокса-заглушки.
    let ip = sp.pub_ip ?? "", cc = uc(sp.cc ?? "");
    let ipy = ap ? cy + ch - 22 : cy + 98;
    if (ip != "") {
        if (int(+(sp.ip_local ?? 0)) == 1) {
            lcd_text(cx + 12, ipy, tcut(ip, 24), C.dim, "none", 1);
        } else if (cc != "") {
            draw_cflag(cx + 12, ipy - 1, cc);
            lcd_text(cx + 32, ipy, tcut(ip, 22), C.gray, "none", 1);
        } else {
            lcd_text(cx + 12, ipy, tcut(ip, 24), C.gray, "none", 1);
        }
    }

    // Кнопка выбора - плитка того же канона, что в меню: верхняя строка
    // говорит, что выбрано сейчас, название белое, акцент в полосе слева.
    let sb = spd_settings_btn();
    let cfg = st.spd_cfg ?? { dl: "", ul: "" };
    gcard(sb.x, sb.y, sb.w, sb.h, C.cyan);
    lcd_text(sb.x + 12, sb.y + (ap ? 8 : 6),
             tcut(spd_preset_name(SPD_DL, cfg.dl) + " / " +
                  spd_preset_name(SPD_UL, cfg.ul), 30), C.dim, "none", 1);
    lcd_text(sb.x + 12, sb.y + (ap ? sb.h - fpx(2) - 8 : 19), tr("Choose servers"), C.white, "none", 2);

    draw_back();
    lcd_flush();
}

// Две колонки: слева загрузка (SPD_DL), справа отдача (SPD_UL). Одинаково -
// оба списком с выбором тапом.
// Две колонки плиток канона: слева загрузка, справа отдача. Ряд 27px -
// шесть пресетов ровно ложатся между шапкой и полосой «назад».
let SPD_HDR = IS_ALMONDPLUS ? 22 : 18;
function spd_row_y(i)   { return GVT + SPD_HDR + i * int((GVB - GVT - SPD_HDR + GG) / 6); }
function spd_row_h()    { return int((GVB - GVT - SPD_HDR + GG) / 6) - GG; }
function spd_dl_rect(i) { return { x: GX + st.ox,             y: spd_row_y(i), w: GCOL, h: spd_row_h() }; }
function spd_ul_rect(i) { return { x: GX + st.ox + GCOL + GG, y: spd_row_y(i), w: GCOL, h: spd_row_h() }; }

function draw_speedtest_settings_page() {
    lcd_clear(C.bg);
    draw_header(tr("Choose servers"));
    let cx = GX + st.ox;
    let cfg = st.spd_cfg ?? { dl: "", ul: "" };

    // Заголовки колонок - со стрелкой фазы, теми же, что на карточке замера.
    let hy = IS_ALMONDPLUS ? GVT + 2 : 29;
    let rx0 = IS_ALMONDPLUS ? cx + GCOL + GG : cx + 156;
    draw_tri_down(cx + 2, hy + 2, C.green);
    lcd_text(cx + 16, hy, tr("Download"), C.ontop_dim, "none", 1);
    draw_tri_up(rx0, hy + 2, "#0095FF");
    lcd_text(rx0 + 14, hy, tr("Upload"), C.ontop_dim, "none", 1);

    for (let i = 0; i < length(SPD_DL); i++) {
        let sel = SPD_DL[i][1] == cfg.dl, r = spd_dl_rect(i);
        gcard(r.x, r.y, r.w, r.h, sel ? C.green : C.dim);
        lcd_text(r.x + 12, IS_ALMONDPLUS ? mid_y(r, 2) : r.y + 5, tcut(SPD_DL[i][0], 15), sel ? C.white : C.gray, "none", 2);
    }
    for (let i = 0; i < length(SPD_UL); i++) {
        let sel = SPD_UL[i][1] == cfg.ul, r = spd_ul_rect(i);
        gcard(r.x, r.y, r.w, r.h, sel ? C.cyan : C.dim);
        lcd_text(r.x + 12, IS_ALMONDPLUS ? mid_y(r, 2) : r.y + 5, tcut(SPD_UL[i][0], 15), sel ? C.white : C.gray, "none", 2);
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
    let y0 = GY + VPN_TOG_H + 6, lh = 11, maxchars = IS_ALMONDPLUS ? int((GW - 8) / 6) : 50;
    let maxrows = int((BACK_Y - 4 - y0) / lh);
    if (maxrows < 1) maxrows = 1;
    let lines = vpn_log_lines(maxchars);
    if (length(lines) == 0) {
        lcd_text(GX + 4, y0, tr("Waiting for log..."), C.ontop_dim, C.bg, 1);
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
        gcard(GX, GY, GW, VPN_TOG_H + 4, C.dim);
        lcd_text(GX + 12, GY + 8, "SSClash", C.gray, C.widget, 2);
        lcd_text(GX + 12, GY + (IS_ALMONDPLUS ? 38 : 26), tr("SSClash not installed"), C.dim, C.widget, 1);
        lcd_text(GX + 4, GY + VPN_TOG_H + 20, tr("Install: opkg/apk add luci-app-ssclash"), C.ontop_dim, C.bg, 1);
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
            let msz = IS_ALMONDPLUS ? 2 : 1;
            if (is_auto) {
                lcd_text(r.x + 12, mid_y(r, msz), tr("Auto (URL-test)"),
                         sel ? C.white : C.gray, C.widget, msz);
            } else {
                // Значок узла + имя слева (по центру строки), кнопка-задержка
                // справа. Цвет имени: выбран - белый, живой (авто) - голубой,
                // иначе серый.
                let fl = vpn_flag(it);
                draw_node_icon(r.x + 10, r.y + int((r.h - 10) / 2), fl[0], fl[1]);
                let ncol = sel ? C.white : (live ? C.cyan : C.gray);
                if (IS_ALMONDPLUS)
                    text_fit2(r.x + 30, mid_y(r, 2), fl[1], ncol, C.widget, r.w - 30 - 84);
                else
                    lcd_text(r.x + 30, r.y + int((r.h - 8) / 2), tcut(fl[1], 33), ncol, C.widget, 1);
                draw_dbtn(r, vpn_delay(it), "m" + i);
            }
        }
        draw_back_pager(st.vpn_mpg ?? 0, pages);
        lcd_flush();
        return;
    }

    // --- Основной экран: тумблер + карточки групп ---
    draw_header("VPN");
    let run = v.running > 0;
    let tg = vpn_tog_rect();
    gcard(tg.x, tg.y, tg.w, tg.h, run ? C.green : C.red);
    lcd_text(tg.x + 12, tg.y + 8, "SSClash", C.white, C.widget, 2);
    lcd_text(tg.x + 12, tg.y + (IS_ALMONDPLUS ? 8 + fpx(2) + 4 : 26), run ? tr("Running") : tr("Stopped"),
             run ? C.green : C.gray, C.widget, 1);
    let ts = run ? tr("ON") : tr("OFF");
    lcd_text(tg.x + tg.w - 12 - twpx(ts, 2), IS_ALMONDPLUS ? mid_y(tg, 2) : tg.y + 12, ts,
             run ? C.green : C.red, C.widget, 2);

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
        lcd_text(GX + 4, GY + 62, tr("No switchable groups"), C.ontop_dim, C.bg, 1);
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
        lcd_text(r.x + 12, IS_ALMONDPLUS ? mid_y(r, 2) : r.y + int((r.h - 14) / 2), tcut(g.name, 10), C.white, C.widget, 2);
        // Справа кнопка-задержка (тап = тест группы), левее - значок и имя
        // текущего узла (по центру строки). У залоченной авто-группы это сам
        // закреплённый узел (now у url-test отстаёт) оранжевым.
        let locked = vpn_auto(g) && (g.fixed ?? "") != "";
        let cur = locked ? g.fixed : g.now;
        let fl = vpn_flag(cur);
        draw_dbtn(r, vpn_delay(cur), "g" + i);
        let b = vpn_dbtn(r);
        let txt = tcut(fl[1], IS_ALMONDPLUS ? 16 : 11), tw = twpx(txt, 1);
        let ex = b.x - 8 - tw;
        lcd_text(ex, r.y + int((r.h - 8) / 2), txt, locked ? C.orange : C.cyan, C.widget, 1);
        draw_node_icon(ex - 18, r.y + int((r.h - 10) / 2), fl[0], fl[1]);
    }
    draw_back_pager(st.vpn_gpg ?? 0, gpages);
    lcd_flush();
}

// Запустить пинг В ФОНЕ: команда пишет done-файл по завершении, UI опрашивает
// его в таймере данных и дорисовывает цифру. Так интерфейс не виснет на замере.
function vpn_ping_bg(cmd, key) {
    fs.unlink("/tmp/.vpn_ping_done");
    system("( " + cmd + " ; touch /tmp/.vpn_ping_done ) >/dev/null 2>&1 &");
    st.vpn_ping = { key: key, ts: time() };
    draw_vpn_page();
}
function draw_led_page() {
    lcd_clear(C.bg);
    draw_header(tr("LED"));

    let c = led_cfg();
    let rows = [
        { label: tr("LED"),          on: c.on,  hint: tr(led_rgb() ? "below the screen" : "above the screen") },
        { label: tr("Blink on SMS"), on: c.sms, hint: tr("while unread remain") },
    ];
    if (led_rgb())
        push(rows, { label: tr("Color"), on: c.on, hint: "", color: c.color });
    for (let i = 0; i < length(rows); i++) {
        let r = rows[i], b = led_row(i);
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, r.color != null ? "#" + r.color : (r.on ? C.green : C.dim));
        let ty = b.y + int((b.h - 26) / 2);
        lcd_text(b.x + 16, ty, r.label, C.white, C.widget, 2);
        lcd_text(b.x + 16, ty + 18, r.hint, C.dim, C.widget, 1);
        if (r.color != null)
            lcd_text_r(b.x + b.w - 16, mid_y(b, 2), led_color_name(r.color),
                       "#" + r.color, C.widget, 2);
        else
            lcd_text_r(b.x + b.w - 16, mid_y(b, 2), r.on ? tr("on") : tr("off"),
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
    let nb = night_btn();
    gcard(nb.x, nb.y, nb.w, nb.h, c.on ? C.green : C.dim);
    lcd_text(nb.x + 12, mid_y(nb, 2), tr("NIGHT MODE"), C.white, C.widget, 2);
    lcd_text_r(nb.x + nb.w - 12, mid_y(nb, 2), c.on ? tr("on") : tr("off"),
               c.on ? C.green : C.gray, C.widget, 2);

    let hcol = c.on ? C.white : C.dim;
    for (let r = 0; r < 2; r++) {
        let m = hour_btn(r, -1), vb = hour_btn(r, 0), pl = hour_btn(r, 1);
        let hv = sprintf("%02d", r == 0 ? c.from : c.to);
        lcd_text(GX + 2 + r * (GCOL + GG), mid_y(vb, 1),
                 r == 0 ? tr("From") : tr("To"), C.ontop, "none", 1);
        // Знаки кеглем 4 - это клетка 32px, ровно в высоту плашки: со старым
        // смещением +10 они свисали ниже неё. Центрируем и по вертикали, и по
        // горизонтали, число тоже перестаёт липнуть к низу.
        lcd_rect(m.x, m.y, m.w, m.h, C.widget);
        draw_pm(m, false, C.accent);
        lcd_rect(vb.x, vb.y, vb.w, vb.h, C.widget);
        lcd_text_c(vb.x + int(vb.w / 2), vb.y + int((vb.h - fpx(3)) / 2),
                 hv, hcol, C.widget, 3);
        lcd_rect(pl.x, pl.y, pl.w, pl.h, C.widget);
        draw_pm(pl, true, C.accent);
    }

    lcd_text(GX + 2, mid_y(night_row(2), 1), tr("LIGHT, %"), C.ontop, "none", 1);
    for (let i = 0; i < length(NIGHT_BRIGHT_STEPS); i++) {
        let b = nbright_btn(i), sel = (NIGHT_BRIGHT_STEPS[i] == c.bright);
        gcard(b.x, b.y, b.w, b.h, sel ? C.green : C.border);
        let t = sprintf("%d%%", NIGHT_BRIGHT_STEPS[i]);
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    lcd_text(GX + 2, mid_y(night_row(3), 1), tr("WARM, %"), C.ontop, "none", 1);
    for (let i = 0; i < length(NIGHT_WARM_STEPS); i++) {
        let b = nwarm_btn(i), sel = (NIGHT_WARM_STEPS[i] == nwarm_cfg());
        gcard(b.x, b.y, b.w, b.h, sel ? "#F0A868" : C.border);
        let t = NIGHT_WARM_STEPS[i] == 0 ? tr("off") : sprintf("%d%%", NIGHT_WARM_STEPS[i]);
        lcd_text_c(b.x + int(b.w / 2), mid_y(b, 1), t,
                 sel ? C.white : C.gray, C.widget, 1);
    }

    for (let i = 0; i < length(NIGHT_ACTS); i++) {
        let b = nact_btn(i), on = night_act(NIGHT_ACTS[i].key);
        gcard(b.x, b.y, b.w, b.h, (c.on && on) ? C.green : C.dim);
        let ty = b.y + int((b.h - (IS_ALMONDPLUS ? 22 : 18)) / 2);
        lcd_text(b.x + 10, ty, tcut(tr(NIGHT_ACTS[i].label), IS_ALMONDPLUS ? 22 : 14),
                 c.on ? C.white : C.dim, C.widget, 1);
        lcd_text(b.x + 10, ty + (IS_ALMONDPLUS ? 14 : 10), on ? tr("on") : tr("off"),
                 (c.on && on) ? C.green : C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

// Информация о соте - то же наполнение, что на одноимённой странице 5gmodem.
// Полей много, поэтому три листа со стрелками, как в выборе города.
let CELL_PAGES = 3;

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

    let cx = GX, cw = GW, y = GVT;
    let CR = stack_rects([ 84, 48 ]);
    // Карточка теперь тянется до низа, поэтому шаг строк считаем от её высоты:
    // прежний фиксированный шаг 14 оставлял снизу пустую треть.
    let rstep = int((GVB - y - 22 - 24) / 8);
    let ry = function(i) { return y + 22 + i * rstep; };

    if (st.cpage == 0) {
        // Идентификаторы и радио - в две колонки, чтобы не листать длинный список.
        let rc = GX + GCOL + GG;
        gcard(cx, y, GCOL, GVB - y, C.cyan);
        lcd_text(cx + 10, y + 6, tr("IDENTITY"), C.gray, C.widget, 1);
        kv2(cx + 10, ry(0),  "PLMN", sprintf("%d-%s", int(+(l.mcc ?? 0)),
        (l.mnc ?? "") != "" ? sprintf("%s", l.mnc) : "--"));
        kv2(cx + 10, ry(1),  "LAC",  c.lac);
        kv2(cx + 10, ry(2),  "TAC",  c.tac);
        kv2(cx + 10, ry(3),  "CID",  sprintf("%d", int(+(l.cid ?? 0))));
        kv2(cx + 10, ry(4),  "hex",  c.cid_hex);
        kv2(cx + 10, ry(5),  "eNB",  sprintf("%d", int(+(l.enbid ?? 0))));
        kv2(cx + 10, ry(6), "PCI",  sprintf("%d", int(+(l.pci ?? 0))));
        kv2(cx + 10, ry(7), "ARFCN", sprintf("%d", int(+(l.earfcn ?? 0))));

        gcard(rc, y, GCOL, GVB - y, C.green);
        lcd_text(rc + 10, y + 6, tr("RADIO"), C.gray, C.widget, 1);
        kv2(rc + 10, ry(0),  "Band",  l.band);
        kv2(rc + 10, ry(1),  "BW",    c.bandwidth);
        kv2(rc + 10, ry(2),  "CQI",   c.cqi);
        kv2(rc + 10, ry(3),  "MIMO",  c.mimo);
        kv2(rc + 10, ry(4),  "UEcat", c.uecat);
        kv2(rc + 10, ry(5),  "VoLTE", c.volte);
        kv2(rc + 10, ry(6), "PLoss", c.pathloss);
        kv2(rc + 10, ry(7), "TXpwr", c.txpower);
    } else if (st.cpage == 1) {
        gcard(cx, y, cw, CR[0].h, C.accent);
        lcd_text(cx + 10, y + 6, tr("CARRIERS"), C.gray, C.widget, 1);
        let row = 0;
        // PCC всегда активна; у SCC берём state из телеметрии. Спящую несущую
        // (state != activated) рисуем приглушённо как резерв - сеть держит её
        // выключенной до трафика, это не работающая агрегация.
        let cc = [ [ "PCC", l.band, int(+(l.pci ?? 0)), "activated" ],
                   [ "SCC1", c.s1band, int(+(c.s1pci ?? 0)), c.s1state ?? "" ],
                   [ "SCC2", c.s2band, int(+(c.s2pci ?? 0)), c.s2state ?? "" ],
                   [ "SCC3", c.s3band, int(+(c.s3pci ?? 0)), c.s3state ?? "" ] ];
        for (let e in cc) {
            if (e[1] == null || e[1] == "" || e[1] == "-") continue;
            let act = e[3] == "activated";
            let nc = act ? C.white : C.dim;
            let lc = act ? C.gray : C.dim;
            let crs = IS_ALMONDPLUS ? 20 : 14, cry = y + 22 + row * crs;
            lcd_text(cx + 10, cry, e[0], lc, C.widget, 1);
            lcd_text(cx + (IS_ALMONDPLUS ? 70 : 50), cry, e[1], nc, C.widget, 1);
            lcd_text(cx + (IS_ALMONDPLUS ? 190 : 130), cry, sprintf("PCI %d", e[2]), lc, C.widget, 1);
            lcd_text(cx + (IS_ALMONDPLUS ? 310 : 210), cry,
                     act ? tr("active fem") : tr("reserve"),
                     act ? C.green : C.dim, C.widget, 1);
            row++;
        }
        if (row == 0)
            lcd_text(cx + 10, y + 22, tr("no aggregation"), C.dim, C.widget, 1);

        let y2 = CR[1].y;
        gcard(cx, y2, cw, CR[1].h, "#D2A8FF");
        lcd_text(cx + 10, y2 + 6, tr("ANTENNA PORTS"), C.gray, C.widget, 1);
        let ap = c.antports ?? "";
        let rd = c.rxdiv ?? "";
        if (rd != "" && rd != "-") {
            let rdt = sprintf("RX div: %s", rd);
            lcd_text_r(cx + cw - 10, y2 + 6, rdt, C.gray, C.widget, 1);
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
                let yy = y2 + 21 + i * (IS_ALMONDPLUS ? 18 : 13);
                lcd_text(cx + 10, yy, sprintf("Rx%s", f[0]), C.white, C.widget, 1);
                lcd_text(cx + (IS_ALMONDPLUS ? 50 : 40), yy, sprintf("%d", rsrp), col, C.widget, 1);
                let rqx = cx + cw - 10 - twpx(f[2], 1);
                let bx = cx + (IS_ALMONDPLUS ? 100 : 76), bw = rqx - 8 - bx;
                if (bw < 40) bw = 40;
                seg_bar(bx, yy + 1, bw, 6, MET.rsrp.bar(rsrp), col, C.btn, "ant" + f[0]);
                lcd_text(rqx, yy, f[2], C.gray, C.widget, 1);
                i++;
            }
        }
    } else {
        // Соседние соты столбиками: на 320x240 таблица из шести строк по пять
        // колонок нечитаема, а относительный уровень видно с одного взгляда.
        gcard(cx, y, cw, IS_ALMONDPLUS ? GVB - y : 140, C.green);

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
            let ap = IS_ALMONDPLUS;
            lcd_text(cx + 10, yy, sprintf("B%s", e?.band ?? "?"), name_c, C.widget, 1);
            lcd_text(cx + (ap ? 60 : 40), yy, sprintf("%d", int(+(e?.pci ?? 0))), C.gray, C.widget, 1);
            lcd_text(cx + (ap ? 110 : 74), yy, sprintf("%d", rsrp), col, C.widget, 1);
            let bx = cx + (ap ? 160 : 110), bw = cw - (ap ? 170 : 120);
            seg_bar(bx, yy + 1, bw, 6, MET.rsrp.bar(rsrp), col, C.btn, bkey);
        };

        lcd_text(cx + 10, y + 6, tr("OWN CELL"), C.gray, C.widget, 1);
        if (own) cell_row(own, y + 22, C.white, "cellown");
        else lcd_text(cx + 10, y + 22, tr("no data"), C.dim, C.widget, 1);

        let nby = IS_ALMONDPLUS ? y + 50 : y + 44;
        lcd_text(cx + 10, nby, tr("NEIGHBOURS"), C.gray, C.widget, 1);
        if (length(others) == 0) {
            lcd_text(cx + 10, nby + 16, tr("no data"), C.dim, C.widget, 1);
        } else {
            let maxr = IS_ALMONDPLUS ? 8 : 4;
            let rows = length(others) > maxr ? maxr : length(others);
            for (let i = 0; i < rows; i++)
                cell_row(others[i], nby + 16 + i * (IS_ALMONDPLUS ? 22 : 19), C.gray, "cellnb" + i);
        }
    }

    // Листалка живёт в полосе навигации: две широкие кнопки со стрелками
    // раньше стояли поверх карточек, которые теперь тянутся до низа.
    draw_back_pager(st.cpage, CELL_PAGES);
    lcd_flush();
}

// Карточки доступности сервисов. Пробу делает svcping.sh поверх netpri.sh
// (TLS/HTTP, а не ICMP - на мобильном интернете с белыми списками пинг молчит
// даже там, где сайт открывается). Шесть хостов занимают до полуминуты,
// поэтому экран только читает готовый файл, а проверку запускает фоном.
let SVC_BTN_H = IS_ALMONDPLUS ? 44 : 32;

function svc_btn(i) {
    if (!IS_ALMONDPLUS) return { x: GX + (i % 2) * (GCOL + GG), y: GY + int(i / 2) * 48, w: GCOL, h: 44 };
    let v = vfit(GVT, GVB - SVC_BTN_H - GG, 3);
    return { x: GX + (i % 2) * (GCOL + GG), y: v.y0 + int(i / 2) * v.step, w: GCOL, h: v.h };
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
let SVC_BAR_Y = IS_ALMONDPLUS ? GVB - SVC_BTN_H : BACK_Y - 38;

function svc_refresh_btn() {
    return { x: GX, y: SVC_BAR_Y, w: GW, h: SVC_BTN_H };
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
        let ap = IS_ALMONDPLUS;
        lcd_rect(b.x + b.w - (ap ? 22 : 14), b.y + (ap ? 12 : 8), ap ? 12 : 8, ap ? 12 : 8, col);

        lcd_text(b.x + 12, b.y + (ap ? 12 : 8), tcut(hosts[i], ap ? 30 : 18),
                 known ? C.white : C.gray, C.widget, 1);
        if (known)
            lcd_text(b.x + 12, ap ? b.y + b.h - 18 : b.y + 24,
                     ok ? sprintf("%d ms", int(+(r.ms ?? 0))) : tr("no answer"),
                     ok ? C.gray : C.red, C.widget, 1);
    }

    // «Пинг» - обычная карточка меню, «назад» - в точности как в меню:
    // своя заливка C.hdr, без нижней грани и с той же надписью.
    let rb = svc_refresh_btn();
    // Идёт фоновая проверка? Снимаем метку, когда svcping перепишет кэш (сменит
    // mtime) или по таймауту.
    let sc = st.svc_check;
    if (sc) {
        let ss = fs.stat("/tmp/lcd_services.json");
        if ((ss && ss.mtime != sc.mt) || (time() - sc.ts) >= 15) { st.svc_check = null; sc = null; }
    }
    let lbl = sc ? tr("Checking...") : tr("Ping");
    lcd_rect(rb.x, rb.y, rb.w, rb.h, C.btn);
    astripe(rb.x, rb.y, rb.h, sc ? C.cyan : C.green);
    lcd_text(rb.x + int((rb.w - twpx(lbl, 2)) / 2), IS_ALMONDPLUS ? mid_y(rb, 2) : rb.y + 9, lbl,
             sc ? C.cyan : C.white, C.btn, 2);

    draw_back();
    lcd_flush();
}

function draw_qr_page() {
    let sec = st.qr_sec ?? "default_radio1";
    let ssid = ucur ? (ucur.get("wireless", sec, "ssid") ?? "N/A") : "N/A";
    let key  = ucur ? (ucur.get("wireless", sec, "key") ?? "") : "";
    let rows = wifi_qr_rows(ssid, key);

    lcd_clear(C.bg);
    draw_header(st.qr_band ?? "WiFi");
    // Имя сети по центру, ТОНКИМ начертанием (fnt:3 = тонкий пиксельный шрифт):
    // стандартный крупный Combo (bitcell) выглядит жирным, здесь нужно тоньше.
    let nm = tcut(ssid, 26);
    nm = strip_ctrl(replace(replace(replace(nm ?? "", '\\', '\\\\'), '"', '\\"'), "\n", "\\n"));
    let qb = GRAD_ON ? "none" : C.bg;
    let qy0 = IS_ALMONDPLUS ? HDR_H + 4 + fpx(2) + 6 : 50;
    Q(sprintf('{"cmd":"text","x":%d,"y":%d,"text":"%s","color":"%s","bg":"%s","size":2,"fnt":3,"anchor":"c"}',
        int(LCD_W / 2), 28, nm, C.ontop_hi, qb));

    if (rows) {
        let n = length(rows);
        let scale = int(((IS_ALMONDPLUS ? GVB : BACK_Y - 4) - qy0) / n);
        if (scale > (IS_ALMONDPLUS ? 7 : 6)) scale = IS_ALMONDPLUS ? 7 : 6;
        if (scale < 1) scale = 1;
        let side = n * scale;
        let qy = IS_ALMONDPLUS ? qy0 + int((GVB - qy0 - side) / 2) : qy0;
        draw_qr(rows, int((LCD_W - side) / 2), qy, scale, "#000000", "#FFFFFF");
    } else {
        lcd_text(10, 100, tr("QR unavailable"), C.red, C.bg, 2);
        lcd_text(10, IS_ALMONDPLUS ? 132 : 124, tr("install qrencode"), C.ontop, C.bg, 1);
    }

    draw_back();
    lcd_flush();
}


// Кнопка-тумблер в стиле кнопок UI: подложка C.btn (sub-panel), слева
// акцентная полоса (зелёная «включено» / серая «выключено»), подпись по
// центру. Подложка выделяет её на фоне плашки-карточки (C.widget).
function wifi_toggle_draw(cy, on) {
    let b = wifi_onoff_box(cy);
    let acc = on ? C.green : C.dim;
    lcd_rect(b.x, b.y, b.w, b.h, C.btn);
    astripe(b.x, b.y, b.h, acc);
    dash_glow({ x: b.x, y: b.y, w: b.w, h: b.h }, { card: C.btn, mono: null }, acc);
    let lbl = on ? tr("ON") : tr("OFF");
    // Центрируем в области ПОСЛЕ акцентной полосы (её ширина 3px + отступ),
    // иначе длинное «ВЫКЛ» прилипает к полоске.
    let inset = (BARS_ON ? 3 : 0) + 6;
    lcd_text_c(b.x + inset + int((b.w - inset - 4) / 2),
               b.y + int((b.h - fpx(2)) / 2), lbl, on ? C.green : C.gray, C.btn, 2);
}

function wifi_cli_rect(cy) {
    // Строка «Клиентов» - левее кнопки-тумблера, чтобы не перехватывать её тап.
    let x = GX + st.ox + 4;
    let w = wifi_onoff_box(cy).x - x - 6;
    if (!IS_ALMONDPLUS) return { x: x, y: cy + 40, w: w < 40 ? 40 : w, h: 30 };
    return { x: x, y: cy + 64, w: w < 40 ? 40 : w, h: 40 };
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
        empty_msg(tr("No Clients"), C.ontop_dim, 2, cx + 10, 110);
        draw_back();
        lcd_flush();
        return;
    }

    let per = 5;
    let pages = int((length(list) + per - 1) / per);
    if (pages < 1) pages = 1;
    if (st.wcli_pg == null || st.wcli_pg >= pages) st.wcli_pg = 0;

    let y = GY + st.oy;
    let wv = vfit(GVT, GVB, per);
    for (let r = 0; r < per; r++) {
        let idx = st.wcli_pg * per + r;
        if (idx >= length(list)) break;
        let cl = list[idx];
        let ap = IS_ALMONDPLUS;
        let ry = ap ? wv.y0 + st.oy + r * wv.step : y + r * 34;
        let rh = ap ? wv.h : 30;
        let dbm = int(+(cl.signal ?? 0));
        let scol = wifi_sig_col(dbm);
        lcd_rect(cx, ry, cw, rh, C.widget);
        astripe(cx, ry, rh, scol);
        let nm = cl.name;
        if (nm == null || nm == "" || nm == "unknown") nm = tr("device");
        lcd_text(cx + 10, ry + (ap ? 6 : 3), tcut(nm, 20), C.white, C.widget, 2);
        let ip = cl.ip ?? "";
        let ly = ap ? ry + rh - 14 : ry + 19;
        lcd_text(cx + 10, ly, ip, C.gray, C.widget, 1);
        lcd_text(cx + 12 + (tlen(ip) + 1) * 6, ly, uc(cl.mac ?? ""),
                 C.dim, C.widget, 1);
        let sg = sprintf("%d dBm", dbm);
        lcd_text(cx + cw - twpx(sg, 1) - 10, ly, sg, scol, C.widget, 1);
        wifi_sig_bars(cx + cw - 30, ry + (ap ? 8 : 4), dbm);
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
    let wh = int((GVB - GVT - GG) / 2);        // радио делят полезную область
    let y1 = GVT + oy;
    let disabled_2g_state = ucur ? wifi_is_disabled("radio1", "default_radio1") : true;
    let wap = IS_ALMONDPLUS;
    let wty = wap ? 8 : 6, wsy = wap ? 30 : 22, wcy = wap ? 72 : 48;
    gcard(cx, y1, cw, wh, disabled_2g_state ? C.dim : C.green);
    lcd_text(cx + 10, y1 + wty, "2.4 GHz", C.gray, C.widget, 1);
    
    if (ucur) {
        let ssid_2g = ucur.get("wireless", "default_radio1", "ssid") ?? "N/A";
        let key_2g = ucur.get("wireless", "default_radio1", "key") ?? "N/A";
        let disabled_2g = wifi_is_disabled("radio1", "default_radio1");
        
        // Текст-колонка слева обрезается по левому краю пилюли, чтобы длинный
        // SSID не заезжал под кнопку. Пароль на экране не показываем - QR и
        // есть пароль.
        let tw1 = wifi_onoff_box(y1).x - (cx + 10) - 8;
        lcd_text(cx + 10, y1 + wsy, tcut(ssid_2g, int(tw1 / (wap ? 18 : 12))), C.white, C.widget, 2);

        // Count clients on 2.4GHz
        let clients_2g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "2G" || cl.band == "2.4G") clients_2g++;
            }
        }
        lcd_text(cx + 10, y1 + wcy, sprintf(tr("Clients: %d"), clients_2g), C.cyan, C.widget, 2);

        wifi_toggle_draw(y1, !disabled_2g);
        if (!disabled_2g) {
            let qb = qr_box(y1);
            draw_qr(wifi_qr_rows(ssid_2g, key_2g), qb.x + 2, qb.y + 2, WQR_SC, "#000000", "#FFFFFF");
        }
    }

    // Card 2: 5GHz WiFi (radio0)
    let y2 = y1 + wh + GG;
    let disabled_5g_state = ucur ? wifi_is_disabled("radio0", "default_radio0") : true;
    gcard(cx, y2, cw, wh, disabled_5g_state ? C.dim : C.green);
    lcd_text(cx + 10, y2 + wty, "5 GHz", C.gray, C.widget, 1);
    
    if (ucur) {
        let ssid_5g = ucur.get("wireless", "default_radio0", "ssid") ?? "N/A";
        let key_5g = ucur.get("wireless", "default_radio0", "key") ?? "N/A";
        let disabled_5g = wifi_is_disabled("radio0", "default_radio0");
        
        let tw2 = wifi_onoff_box(y2).x - (cx + 10) - 8;
        lcd_text(cx + 10, y2 + wsy, tcut(ssid_5g, int(tw2 / (wap ? 18 : 12))), C.white, C.widget, 2);

        // Count clients on 5GHz
        let clients_5g = 0;
        let clients = d?.wifi?.clients;
        if (type(clients) == "array") {
            for (let cl in clients) {
                if (cl.band == "5G" || cl.band == "5GHz") clients_5g++;
            }
        }
        lcd_text(cx + 10, y2 + wcy, sprintf(tr("Clients: %d"), clients_5g), C.cyan, C.widget, 2);

        wifi_toggle_draw(y2, !disabled_5g);
        if (!disabled_5g) {
            let qb = qr_box(y2);
            draw_qr(wifi_qr_rows(ssid_5g, key_5g), qb.x + 2, qb.y + 2, WQR_SC, "#000000", "#FFFFFF");
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
    let n = length(rows);
    if (n < 1) { draw_back(); lcd_flush(); return; }
    // Акцент берём от карточки, из которой развернули: цвет остаётся тем же,
    // и видно, откуда пришёл. Раньше это был голый текст на фоне - крупный,
    // но вне сетки и без опознавательных знаков.
    let acc = i == 0 ? C.cyan : (i == 1 ? C.green : "#D2A8FF");
    let h = gcard_h(n);
    for (let r = 0; r < n; r++) {
        let y = GVT + r * (h + GG);
        let lab = rows[r][0], val = rows[r][1];
        gcard(GX, y, GW, h, acc);
        lcd_text(GX + 13, y + int((h - 8) / 2), lab, C.gray, C.widget, 1);
        if (val != null && val != "")
            lcd_text_r(GX + GW - 12, y + int((h - 16) / 2), tcut(val, 20),
                       C.white, C.widget, 2);
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
    let ch3 = gcard_h(3);
    // Три строки шагом 14 - блок в 36 пикселей. Ставим его по центру карточки:
    // сами плашки не двигаем, только содержимое.
    let ls = IS_ALMONDPLUS ? 19 : 14;
    let iy0 = int((ch3 - (2 * ls + 8)) / 2);
    let y1 = GVT + oy;
    gcard(cx, y1, cw, ch3, C.cyan);
    lcd_text(cx + 10, y1 + iy0, tr("SYSTEM"), C.gray, C.widget, 1);
    let hw = board?.model ?? "";
    lcd_text(cx + 10, y1 + iy0 + ls, hw != "" ? hw : "?", C.white, C.widget, 1);

    // ЦП поднят наверх и прижат к правому краю - над строкой «Свободно ОЗУ».
    let busy = int(+(d?.cpu_busy ?? -1));
    let cores = int(+(d?.cpu_cores ?? 0));
    let cstr = sprintf(tr("CPU %s"), load);
    if (busy >= 0) cstr += sprintf(", %d%%", busy);
    if (cores > 0) cstr += sprintf(tr(", %d threads"), cores);
    lcd_text_r(cx + cw - 10, y1 + iy0 + ls, cstr, C.accent, C.widget, 1);

    // Заряд отсюда убран: он и так виден в шапке каждой страницы, а
    // подробности живут на «Батарее» - дубль на карточке только шумел.
    lcd_text(cx + 10, y1 + iy0 + 2 * ls, sprintf(tr("Uptime %s"), fmt_uptime_c(d?.uptime)), C.white, C.widget, 1);

    // Свободную память прижимаем к правому краю карточки: строка длинная,
    // а слева уже стоит время работы.
    let mfree = int(+(d?.mem_free_mb ?? 0));
    let mtot  = int(+(d?.mem_total_mb ?? 0));
    let mstr = mtot > 0 ? sprintf(tr("free RAM %d/%dM"), mfree, mtot)
                        : sprintf(tr("free RAM %dM"), mfree);
    lcd_text_r(cx + cw - 10, y1 + iy0 + 2 * ls, mstr, C.green, C.widget, 1);

    // Card 2: Power
    let y2 = y1 + ch3 + GG;
    gcard(cx, y2, cw, ch3, C.green);
    lcd_text(cx + 10, y2 + iy0, tr("STORAGE AND NETWORK"), C.gray, C.widget, 1);

    // Флеш: свободно из всего, с полосой занятости справа.
    let so = d?.storage;
    let s_free = int(+(so?.free_kb ?? 0)), s_tot = int(+(so?.total_kb ?? 0));
    if (s_tot > 0) {
        lcd_text(cx + 10, y2 + iy0 + ls,
                 sprintf(tr("Flash %.1f of %.1f MB free"), s_free / 1024.0, s_tot / 1024.0),
                 C.white, C.widget, 1);
        let bw = 56, bx = cx + cw - 10 - bw;
        let pct = int((s_tot - s_free) * 100 / s_tot);
        seg_bar(bx, y2 + iy0 + ls, bw, 7, pct, pct > 80 ? C.red : C.green, C.btn, "flash");
    } else {
        lcd_text(cx + 10, y2 + iy0 + ls, tr("Flash: no data"), C.dim, C.widget, 1);
    }

    let lan = d?.lan;
    lcd_text(cx + 10, y2 + iy0 + 2 * ls, sprintf("LAN %s", lan?.ip ?? "?"), C.accent, C.widget, 1);
    let mac_s = uc(lan?.mac ?? "");
    if (mac_s != "")
        lcd_text_r(cx + cw - 10, y2 + iy0 + 2 * ls, mac_s, C.gray, C.widget, 1);

    // Card 3: Software
    let y3 = y2 + ch3 + GG;
    gcard(cx, y3, cw, ch3, "#D2A8FF");
    lcd_text(cx + 10, y3 + iy0, tr("SOFTWARE"), C.gray, C.widget, 1);
    // Ссылка на телеграм-канал - напротив заголовка «ПРОШИВКА», справа.
    lcd_text_r(cx + cw - 10, y3 + iy0, TG_LINK, C.dim, C.widget, 1);
    lcd_text(cx + 10, y3 + iy0 + ls, sprintf("OpenWrt %s", board?.release?.version ?? "?"), C.white, C.widget, 1);
    let kstr = sprintf(tr("Kernel %s"), board?.kernel ?? "?");
    lcd_text_r(cx + cw - 10, y3 + iy0 + ls, kstr, C.dim, C.widget, 1);

    // Драйвер отдаёт дату сборки как 2026-08-13 - показываем по-русски.
    let dv = drv_ver;
    let dm = match(dv, /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/);
    dv = dm ? sprintf(tr("build %s.%s.%s"), dm[3], dm[2], dm[1]) : sprintf(tr("build %s"), dv);
    // Имя драйвера слева цветом, дата сборки - в правый серый столбец
    // между ядром и ссылкой.
    lcd_text(cx + 10, y3 + iy0 + 2 * ls, "kmod-lcd-almond3s", C.accent, C.widget, 1);
    lcd_text_r(cx + cw - 10, y3 + iy0 + 2 * ls, dv, C.dim, C.widget, 1);

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
    if (!IS_ALMONDPLUS) return { x: 8 + (i % 2) * 156, y: 28 + int(i / 2) * 36, w: 148, h: 32 };
    let v = vfit(GVT, GVB, 5);
    return { x: GX + (i % 2) * (GCOL + GG), y: v.y0 + int(i / 2) * v.step, w: GCOL, h: v.h };
}
function wcity_kbd_btn() {
    if (!IS_ALMONDPLUS) return { x: 8, y: 136, w: 304, h: 28 };
    let v = vfit(GVT, GVB, 5);
    return { x: GX, y: v.y0 + 3 * v.step, w: GW, h: v.h };
}
function wcity_prov_btn() {
    if (!IS_ALMONDPLUS) return { x: 8, y: 168, w: 304, h: 28 };
    let v = vfit(GVT, GVB, 5);
    return { x: GX, y: v.y0 + 4 * v.step, w: GW, h: v.h };
}

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
        let csz = IS_ALMONDPLUS ? 2 : 1;
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, sel ? "#D2A8FF" : C.border);
        lcd_text(b.x + 12, IS_ALMONDPLUS ? mid_y(b, 2) : b.y + 10, city_name(list[i]),
                 sel ? C.white : C.gray, C.widget, csz);
    }

    // «Свой город» — открывает клавиатуру.
    let k = wcity_kbd_btn();
    let ksz = IS_ALMONDPLUS ? 2 : 1;
    lcd_rect(k.x, k.y, k.w, k.h, C.widget);
    astripe(k.x, k.y, k.h, C.accent);
    lcd_text(k.x + 12, IS_ALMONDPLUS ? mid_y(k, 2) : k.y + 8, tr("Custom city..."), C.accent, C.widget, ksz);

    // «Источник: <провайдер>» — переключатель по тапу.
    let p = wcity_prov_btn();
    let py = IS_ALMONDPLUS ? mid_y(p, 2) : p.y + 8;
    lcd_rect(p.x, p.y, p.w, p.h, C.widget);
    astripe(p.x, p.y, p.h, C.cyan);
    lcd_text(p.x + 12, py, tr("Source") + ": ", C.gray, C.widget, ksz);
    lcd_text(p.x + 12 + twpx(tr("Source") + ": ", ksz), py,
             weather_provider_name() + "  ▸", C.cyan, C.widget, ksz);

    draw_back();
    lcd_flush();
}

// Время последнего обновления погоды - по mtime кэша, который пишет
// Пикер выбора города при неоднозначности («две Москвы»): фоновый weather_geo.sh
// кладёт JSON совпадений в GEO_JSON, здесь их парсим и показываем списком с
// уточнением (регион, страна). НЕ зовёт go_page (no-hoisting) - выбор в тач-хэндлере.
function geopick_btn(i) {
    if (!IS_ALMONDPLUS) return { x: 8, y: 28 + i * 30, w: 304, h: 28 };
    let v = vfit(GVT, GVB, 6);
    return { x: GX, y: v.y0 + i * v.step, w: GW, h: v.h };
}

function draw_geopick_page() {
    lcd_clear(C.bg);
    draw_header(tr("Select city"));
    let raw = fs.readfile(GEO_JSON);
    if (!raw) {
        let msg = (time() - (st.geo_wait ?? 0) > 15) ? tr("City not found") : tr("Searching...");
        empty_msg(msg, C.ontop, 2);
        draw_back(); lcd_flush(); return;
    }
    let j; try { j = json(raw); } catch (e) { j = {}; }
    let r = (type(j?.results) == "array") ? j.results : [];
    st.geo_res = r;
    if (length(r) == 0) {
        empty_msg(tr("City not found"), C.ontop_dim, 2);
        draw_back(); lcd_flush(); return;
    }
    let n = length(r); if (n > 6) n = 6;
    for (let i = 0; i < n; i++) {
        let b = geopick_btn(i), e = r[i];
        let sub = e.admin1 ? (e.admin1 + ", " + (e.country ?? "")) : (e.country ?? "");
        lcd_rect(b.x, b.y, b.w, b.h, C.widget);
        astripe(b.x, b.y, b.h, C.accent);
        if (IS_ALMONDPLUS) {
            lcd_text(b.x + 12, mid_y(b, 2), tcut(e.name ?? "", 20), C.white, C.widget, 2);
            lcd_text_r(b.x + b.w - 12, mid_y(b, 1), tcut(sub, 40), C.gray, C.widget, 1);
        } else {
            lcd_text(b.x + 10, b.y + 3, tcut(e.name ?? "", 24), C.white, C.widget, 1);
            lcd_text(b.x + 10, b.y + 15, tcut(sub, 48), C.gray, C.widget, 1);
        }
    }
    draw_back(); lcd_flush();
}

// weather_fetch.sh (сам ответ API времени не несёт).
// «Сколько времени назад» - как принято: свежее время словами, а старше
// недели уже датой, потому что «11 дней назад» ни о чём не говорит.
function fmt_ago(mtime) {
    let dt = time() - mtime;
    if (dt < 0) dt = 0;
    let ru = (lang() == "ru");
    if (dt < 90) return ru ? "только что" : "just now";
    let m = int(dt / 60);
    if (m < 60)
        return ru ? sprintf("%d %s назад", m, plural_ru(m, "минуту", "минуты", "минут"))
                  : sprintf("%d min ago", m);
    let h = int(dt / 3600);
    if (h < 24)
        return ru ? sprintf("%d %s назад", h, plural_ru(h, "час", "часа", "часов"))
                  : sprintf("%d h ago", h);
    let dd = int(dt / 86400);
    if (dd < 7)
        return ru ? sprintf("%d %s назад", dd, plural_ru(dd, "день", "дня", "дней"))
                  : sprintf("%d d ago", dd);
    let t = localtime(mtime);
    if (!t) return "";
    return sprintf("%02d.%02d %02d:%02d", t.mday, t.mon, t.hour, t.min);
}

function weather_updated_str() {
    let s = fs.stat("/tmp/lcd_weather.txt");
    if (!s || !s.mtime) return "";
    return sprintf("%s %s", tr("Updated"), fmt_ago(s.mtime));
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
    let WR = stack_rects([ 84, 32, 44 ]);
    // Акцент-полоса героя - динамическая по температуре (тепло-холод), как у
    // виджетов температуры модема/чипа.
    let ap = IS_ALMONDPLUS;
    let h = gcard(X, WR[0].y + oy, GW, WR[0].h, weather_temp_col(w.temp));
    if (ap) draw_weather_icon(h.r - 112, h.y + int((h.h - 96) / 2), desc, 4, null);
    else draw_weather_icon(h.r - 82, h.y + 8, desc, 3, null);
    // Температура в главной карточке - крупно и целиком (как было).
    lcd_text(h.ix, h.y + 14, w.temp ?? "?", weather_temp_col(w.temp), C.widget, 4);
    lcd_text(h.ix, h.y + (ap ? 14 + fpx(4) + 10 : 52), city_name(w?.city) ?? "", C.gray, C.widget, ap ? 2 : 1);
    let wupd = weather_updated_str();
    if (wupd != "") lcd_text(h.ix, h.y + (ap ? h.h - 18 : 66), wupd, C.dim, C.widget, 1);

    // Условие - полосой (зазоры прежние, 8px).
    let cy = WR[1].y + oy;
    let cc = gcard(X, cy, GW, WR[1].h, C.cyan);
    lcd_text(cc.ix, ap ? mid_y(cc, 2) : cc.y + 9, wcond_tr(desc), C.cyan, C.widget, 2);

    // Три метрики ровным рядом, подписи целиком, текст с отступом от полоски.
    let my = WR[2].y + oy;
    let mw = int((GW - 2 * GG) / 3);               // (304-16)/3 = 96
    let mets = [ [ tr("Feels"), w.feels ?? "?" ],
                 [ tr("Humidity"), w.humidity ?? "?" ],
                 [ tr("Wind"), wind_fmt(w.wind ?? "") ] ];
    for (let i = 0; i < 3; i++) {
        let mx = X + i * (mw + GG);
        let mc = gcard(mx, my, (i < 2) ? mw : (X + GW - mx), WR[2].h, C.gray);
        lcd_text(mc.ix, mc.y + (ap ? 10 : 9), mets[i][0], C.gray, C.widget, 1);
        let mv = split_unit(mets[i][1]);
        let vy = ap ? mc.y + mc.h - fpx(2) - 8 : mc.y + 23;
        lcd_text(mc.ix, vy, mv[0], C.white, C.widget, 2);
        if (mv[1] != "")
            lcd_text(mc.ix + twpx(mv[0], 2) + 1, ap ? vy + fpx(2) - 10 : mc.y + 22, mv[1], C.gray, C.widget, 1);
    }

    draw_back();
    lcd_flush();
}

function draw_ip_page() {
    let d = st.data;
    lcd_clear(C.bg);
    draw_header(tr("External IP"));
    let ap = IS_ALMONDPLUS;
    let x = ap ? GX + 6 : 4;
    let y = ap ? GVT + 4 : 30;

    let eip = d?.vpn?.external_ip ?? "unknown";
    lcd_text(x, y, tr("Exit IP:"), C.cyan, C.bg, 2);
    y += ap ? fpx(2) + 6 : 22;
    lcd_text(x, y, eip, C.accent, C.bg, 3);
    y += ap ? fpx(3) + 10 : 30;

    let vpn = d?.vpn?.active;
    lcd_text(x, y, vpn ? "via VPN (WireGuard)" : "Direct (no VPN)",
        vpn ? C.green : C.red, C.bg, 2);
    y += ap ? fpx(2) + 10 : 24;

    let ping_g = int(+(d?.ping?.google_ms ?? -1));
    let ping_v = int(+(d?.vpn?.ping_ms ?? -1));
    let pg_s = ping_g < 0 ? "FAIL" : sprintf("%dms", ping_g);
    let pv_s = ping_v < 0 ? "FAIL" : sprintf("%dms", ping_v);
    lcd_text(x, y, sprintf("Google: %s  VPN: %s", pg_s, pv_s), C.ontop_hi, C.bg, 1);
    y += ap ? 18 : 14;

    // LTE IP for reference
    let lip = d?.lte?.ip ?? "?";
    lcd_text(x, y, sprintf("LTE IP: %s", lip), C.ontop, C.bg, 1);

    draw_back();
    lcd_flush();
}

function draw_metric_row(x, y, w, key, label, v) {
    let m = MET[key];
    let col = LVC[m.lv(v)];
    let bx = x + 86, bw = w - 86;
    lcd_text(x, y, label, C.gray, C.widget, 1);
    lcd_text(x + 42, y, sprintf("%d", v), col, C.widget, 1);
    seg_bar(bx, y + 1, bw, 6, m.bar(v), col, C.btn, key);
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
    let rx = function(t) { return REDGE - twpx(t, 1); };

    // Половинки - та же колонка и тот же зазор, что у всех двухколоночных
    // страниц: своя арифметика давала 149+6 и уводила правую колонку на 163.
    let hw = GCOL;
    let RX2 = X + GCOL + GG;
    let row2 = function(cx0, yy, label, val, lcol, vcol) {
        if (label != null && label != "")
            lcd_text(cx0 + 13, yy, label, lcol ?? C.gray, C.widget, 1);
        if (val != null && val != "")
            lcd_text_r(cx0 + hw - 12, yy, val, vcol ?? C.white, C.widget, 1);
    };

    let ch3 = gcard_h(3);
    // Четыре строки шагом 12 - блок в 44 пикселя. Ставим его по центру
    // карточки: карточки подросли, а строки остались прижатыми к верху.
    let rs = IS_ALMONDPLUS ? 16 : 12;
    let ry0 = int((ch3 - (3 * rs + 8)) / 2);
    let ay = GVT + oy;
    gcard(X, ay, hw, ch3, C.green);
    // Имя модема не влезает в 13 знаков (напр. «Quectel EP06-E») - роняли
    // вендора, а не обрезали хвост «-E». Порог по фактической ширине строки.
    let model = l.modem ?? "-";
    if (tlen(model) > (IS_ALMONDPLUS ? 22 : 13)) {
        let w = split(model, " ");
        if (length(w) > 1) model = join(" ", slice(w, 1));
    }
    let slot = int(+(l.simslot ?? 0));
    let ts = temp > 0
        ? sprintf("%d°C%s", temp, int(+(l.therm ?? 0)) > 0 ? " !" : "")
        : "-";
    let tc = temp >= 70 ? C.red : (temp >= 55 ? C.orange : (temp > 0 ? C.white : C.dim));
    row2(X, ay + ry0, tr("Modem"), tcut(model, IS_ALMONDPLUS ? 22 : 13), null, C.white);
    // Показываем ВСЕ несущие связки, а не только активные: активные акцентом,
    // спящие приглушённо - ровно как в 5gmodem. Так видно и работающую
    // агрегацию, и собранный про запас резерв.
    let segs = carrier_segs(l);
    lcd_text(X + 13, ay + ry0 + rs, tr("Band"), C.gray, C.widget, 1);
    if (length(segs) > 0)
        draw_ca(X + hw - 12 - ca_width(segs, 1), ay + ry0 + rs, segs, 1,
                C.widget, C.accent, C.dim);
    else
        lcd_text_r(X + hw - 12, ay + ry0 + rs, "-", C.white, C.widget, 1);
    // SIM без слотов (модем без sim-tray) прочерк не рисуем - строку опускаем.
    if (slot > 0)
        row2(X, ay + ry0 + 2 * rs, "SIM", sprintf("%d", slot), null, C.white);
    row2(X, ay + ry0 + 3 * rs, tr("Temp"), ts, null, tc);

    gcard(RX2, ay, hw, ch3, A_PINK);
    let mode_s = rat_label(l.mode ?? "-");
    if (nca > 1) mode_s += sprintf(" %dCA", nca);
    let roam_on = int(+(l.roaming ?? 0)) > 0;
    let oper = l.operator ?? "";
    let phone = phone_fmt(l.phone);
    row2(RX2, ay + ry0, tr("Operator"),
         mode_s != "" && mode_s != "-" ? mode_s : "-", null, C.cyan);
    row2(RX2, ay + ry0 + rs, tcut(oper != "" && oper != "-" ? oper : "-", IS_ALMONDPLUS ? 24 : 14), null, C.white);
    row2(RX2, ay + ry0 + 2 * rs, phone != "" ? phone : "-", null, C.white);
    row2(RX2, ay + ry0 + 3 * rs, roam_on ? tr("ROAM") : tr("Quality"),
         csq > 0 ? sprintf("%d/31", csq) : "-",
         roam_on ? C.orange : C.gray, C.gray);

    let by = ay + ch3 + GG;
    gcard(X, by, GW, ch3, C.cyan);
    draw_metric_row(X + 10, by + ry0,  GW - 20, "rsrp", "RSRP", rsrp);
    draw_metric_row(X + 10, by + ry0 + rs, GW - 20, "rsrq", "RSRQ", int(+(l.rsrq ?? 0)));
    draw_metric_row(X + 10, by + ry0 + 2 * rs, GW - 20, "sinr", "SINR", int(+(l.sinr ?? 0)));
    draw_metric_row(X + 10, by + ry0 + 3 * rs, GW - 20, "rssi", "RSSI", int(+(l.rssi ?? 0)));

    let cy = by + ch3 + GG;
    let cell_id = function(v) {
        let n = int(+(v ?? 0));
        return n > 0 ? sprintf("%d", n) : "-";
    };
    gcard(X, cy, hw, ch3, "#D2A8FF");
    row2(X, cy + ry0, tr("Cell"), null);
    row2(X, cy + ry0 + rs, "PCI", cell_id(u?.pci));
    row2(X, cy + ry0 + 2 * rs, "EARFCN", cell_id(l.earfcn));
    row2(X, cy + ry0 + 3 * rs, "eNB", cell_id(u?.enb_id));

    gcard(RX2, cy, hw, ch3, A_TEAL);
    let mcc = int(+(u?.mcc ?? 0)), mnc = int(+(u?.mnc ?? 0));
    let plmn_s = "-";
    if (mcc > 0) {
        plmn_s = sprintf("%d-%02d", mcc, mnc);
        let pop = lc(trim(l.operator ?? ""));
        let plmn_name = get_plmn_name(mcc, mnc);
        if (plmn_name && lc(plmn_name) != pop) plmn_s += " " + tcut(plmn_name, 8);
    }
    let ip_s = l.ip ?? "";
    let conn_s = conn_fmt(l.conn_time) ?? "";
    row2(RX2, cy + ry0, tr("Network"), null);
    row2(RX2, cy + ry0 + rs, "PLMN", plmn_s, null, C.gray);
    row2(RX2, cy + ry0 + 2 * rs, "IP", ip_s != "" ? ip_s : "-", null, C.green);
    row2(RX2, cy + ry0 + 3 * rs, tr("Online"), conn_s != "" ? conn_s : "-", null, C.gray);

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

    let ap = IS_ALMONDPLUS;
    let zx = ap ? GX + 6 : 12, zy1 = ap ? GVT + 4 : 30, zy2 = ap ? GVT + 4 + fpx(3) + 10 : 62;
    let vx = ap ? zx + 60 : 44;
    lcd_text(zx, zy1 + 4, "RX", C.green, C.bg, 2);
    lcd_text(vx, zy1, fmt_bytes(rx_last) + "/s", C.ontop_hi, C.bg, 3);
    lcd_text(zx, zy2 + 4, "TX", C.cyan, C.bg, 2);
    lcd_text(vx, zy2, fmt_bytes(tx_last) + "/s", C.ontop_hi, C.bg, 3);

    let rm = arr_minmax(hrx);
    let tm = arr_minmax(htx);
    let mx = rm.max > tm.max ? rm.max : tm.max;
    if (mx < 512) mx = 512;
    let gy = ap ? zy2 + fpx(3) + 12 : 96, gh = ap ? GVB - (zy2 + fpx(3) + 12) : 100;
    let gx = ap ? GX : 12, gw = ap ? GW : 296;
    lcd_rect(gx, gy, gw, gh, C.graph);
    dash_spark(gx, gy, gw, gh, htx, C.cyan, 0, mx);
    dash_spark(gx, gy, gw, gh, hrx, C.green, 0, mx);
    draw_back();
    lcd_flush();
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
    let ap = IS_ALMONDPLUS;
    let TGH = int((GVB - GVT - GG) / 2), GTOP = ap ? 52 : 34, GBOT = ap ? TGH - 8 : 79;
    let tsz = ap ? 2 : 1, tly = ap ? 22 : 20;
    let txx = ap ? 250 : 165, tvx = ap ? 292 : 187, rvx = ap ? 52 : 32;
    let y1 = GY;
    gcard(cx, y1, cw, TGH, C.cyan);
    lcd_text(cx + 10, y1 + 6, "MODEM - wwan0", C.gray, C.widget, 1);
    lcd_text(cx + 10, y1 + tly, "RX", C.green, C.widget, tsz);
    lcd_text(cx + rvx, y1 + tly, fmt_bytes(rx_last) + "/s", C.white, C.widget, tsz);
    lcd_text(cx + txx, y1 + tly, "TX", C.cyan, C.widget, tsz);
    lcd_text(cx + tvx, y1 + tly, fmt_bytes(tx_last) + "/s", C.white, C.widget, tsz);

    let rm = arr_minmax(hist.rx);
    let tm = arr_minmax(hist.tx);
    let mx1 = rm.max > tm.max ? rm.max : tm.max;
    if (mx1 < 512) mx1 = 512;
    bar_graph(cx + 4, y1 + GTOP, cw - 8, GBOT - GTOP,
              [ { data: hist.rx, color: C.green }, { data: hist.tx, color: C.cyan } ], 0, mx1);

    // WAN / Ethernet
    let wan_rx = length(hist.wan_rx) > 0 ? hist.wan_rx[length(hist.wan_rx) - 1] : 0;
    let wan_tx = length(hist.wan_tx) > 0 ? hist.wan_tx[length(hist.wan_tx) - 1] : 0;
    let y2 = y1 + TGH + GG;
    gcard(cx, y2, cw, TGH, C.yellow);
    lcd_text(cx + 10, y2 + 6, sprintf(tr("UPLINK - %s"), default_iface() ?? "none"), C.gray, C.widget, 1);
    lcd_text(cx + 10, y2 + tly, "RX", C.green, C.widget, tsz);
    lcd_text(cx + rvx, y2 + tly, fmt_bytes(wan_rx) + "/s", C.white, C.widget, tsz);
    lcd_text(cx + txx, y2 + tly, "TX", C.cyan, C.widget, tsz);
    lcd_text(cx + tvx, y2 + tly, fmt_bytes(wan_tx) + "/s", C.white, C.widget, tsz);

    let brm = arr_minmax(hist.wan_rx);
    let btm = arr_minmax(hist.wan_tx);
    let mx2 = brm.max > btm.max ? brm.max : btm.max;
    if (mx2 < 512) mx2 = 512;
    bar_graph(cx + 4, y2 + GTOP, cw - 8, GBOT - GTOP,
              [ { data: hist.wan_rx, color: C.green }, { data: hist.wan_tx, color: C.cyan } ], 0, mx2);

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
    if (st.page == "zigpeer") {
        let f = fs.stat(ZIG_PEERS);
        return base + sprintf("|%d|%d", f ? f.mtime : 0, st.zig?.peer ?? 0);
    }
    if (st.page == "zignets") {
        let f = fs.stat(ZIG_ASCAN);
        return base + sprintf("|%d|%d", f ? f.mtime : 0, zig_busy() ? 1 : 0);
    }
    if (st.page == "zigset") {
        let f = fs.stat("/tmp/lcd_zig_state.json");
        let fl = fs.stat(ZIG_FLASH_LOG);
        let pf = fs.stat(ZIG_PEERS);
        let jf = fs.stat(ZIG_JOIN);
        return base + sprintf("|%d|%d|%d|%d|%d|%d|%d|%d", f ? f.mtime : 0, st.zig?.form_msg ? 1 : 0,
                              fl ? fl.size : 0, st.zig?.flashing ? 1 : 0, pf ? pf.mtime : 0,
                              jf ? jf.mtime : 0, zig_permit_left(), zig_held() ? 1 : 0);
    }
    if (st.page == "zigbee") {
        let e = fs.stat(ZIG_ESCAN), pf = fs.stat(ZIG_PEERS), sf = fs.stat(ZIG_STATE);
        return base + sprintf("|%s|%d|%d|%d|%d|%d", st.zig?.mode ?? "escan",
                              zig_busy() ? 1 : 0, e ? e.mtime : 0, pf ? pf.mtime : 0,
                              sf ? sf.mtime : 0, zig_held() ? 1 : 0);
    }
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
    case "update": {
        let sg = "";
        for (let k in [ "kmod", "lcd", "nes", "5g" ]) {
            let f = fs.stat(upd_file(k));
            sg += sprintf("|%d|%d", f ? f.mtime : 0, f ? f.size : 0);
        }
        return base + sg + "|" + (st.upd_confirm ?? "");
    }
    case "relnotes": {
        let f = fs.stat("/tmp/almond_notes_" + (st.notes_src ?? "almond") + ".txt");
        return base + sprintf("|%d|%d|%d", f ? f.mtime : 0, f ? f.size : 0, st.notes_pg ?? 0);
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

// Пульт в браузере - отдельная служба: она живёт дольше игры, поэтому код с
// экрана настроек можно отсканировать заранее, а соединение не рвётся при
// выходе из игры. Держим её ровно пока открыт раздел «Игры».
//
// setsid обязателен: на время игры оболочка останавливается целиком, и без
// отвязки служба ушла бы вместе с ней. Второй запуск безвреден - служба сама
// выходит, если порт уже занят.
function pad_start() {
    /* setsid обязателен: на время игры оболочка останавливается целиком, и без
       отвязки служба ушла бы вместе с ней. Второй запуск безвреден - служба
       сама выходит, если порт уже занят. */
    system("/usr/bin/setsid /usr/libexec/almond3s/almond3s-pad >/dev/null 2>&1 </dev/null &");
}

function pad_stop() {
    system("killall almond3s-pad >/dev/null 2>&1");
}

// ===== «Свои виджеты»: настраиваемая страница заставки из слотов пир+метрика.
// Слоты хранятся строкой в uci almond3s.display.dcust: "клетка:имя:метрика"
// через запятую, клетка 0..15 в сетке 4x4. Страница появляется в карусели
// заставки, когда есть хоть один слот; данные - из телеметрии Zigbee (тот же
// /tmp/lcd_zig_peers.json, что и список соседей).
let DCUST = null;
let DCUST_PAGES = null;
let DCUST_MP = null;
let ZP_CACHE = null, ZP_TS = 0;

let DC_METS = [
    { k: "sig",  l: "Signal",  a: "#10B981" }, { k: "batt", l: "Battery", a: "#10B981" },
    { k: "temp", l: "Temp",    a: "#E8853A" }, { k: "cpu",  l: "CPU",     a: "#58A6FF" },
    { k: "mem",  l: "Memory",  a: "#58A6FF" }, { k: "ping", l: "Ping",    a: "#10B981" },
    { k: "up",   l: "Uptime",  a: "#58A6FF" }, { k: "vpn",  l: "VPN",     a: "#A78BFA" },
    { k: "link", l: "link",    a: "#10B981" }, { k: "tx",   l: "TX",      a: "#14B8A6" },
];

function dc_met_accent(k) {
    for (let x in DC_METS) if (x.k == k) return x.a;
    return C.cyan;
}

function dc_met_label(k) {
    for (let x in DC_METS) if (x.k == k) return tr(x.l);
    return k;
}

// Автоуплотнение: слоты страницы в порядке клеток прижимаются влево-вверх,
// первая свободная позиция, куда виджет влезает целиком, - его место. Дыр
// между виджетами не остаётся; удалил один - соседи подъезжают. Позиция
// клетки при добавлении остаётся подсказкой порядка.
function dc_pack() {
    let out = {};
    for (let pg = 0; pg < 4; pg++) {
        let list = [];
        for (let k, v in DCUST)
            if (int(int(k) / 16) == pg) push(list, { k: int(k), v: v });
        sort(list, (a, b) => a.k - b.k);
        let occ = [];
        for (let i = 0; i < 16; i++) push(occ, false);
        for (let s in list) {
            let cw = s.v.cw ?? 1, ch = s.v.ch ?? 1, placed = false;
            for (let idx = 0; idx < 16 && !placed; idx++) {
                let c = idx % 4, r = int(idx / 4);
                if (c + cw > 4 || r + ch > 4) continue;
                let ok = true;
                for (let dy = 0; dy < ch && ok; dy++)
                    for (let dx = 0; dx < cw && ok; dx++)
                        if (occ[(r + dy) * 4 + c + dx]) ok = false;
                if (!ok) continue;
                for (let dy = 0; dy < ch; dy++)
                    for (let dx = 0; dx < cw; dx++)
                        occ[(r + dy) * 4 + c + dx] = true;
                out[pg * 16 + idx] = s.v;
                placed = true;
            }
            if (!placed) out[s.k] = s.v;
        }
    }
    DCUST = out;
}

function dcust_load() {
    if (DCUST != null) return DCUST;
    DCUST = {};
    let raw = ucur ? ucur.get("almond3s", "display", "dcust") : null;
    if (type(raw) == "string" && raw != "") {
        for (let s in split(raw, ",")) {
            let p = split(s, ":");
            if (length(p) < 3) continue;
            let cell = int(p[0]);
            let cw = 1, ch = 1;
            if (length(p) >= 4) {
                let sz = split(p[3], "x");
                if (length(sz) == 2) { cw = int(sz[0]); ch = int(sz[1]); }
                if (cw < 1 || cw > 4) cw = 1;
                if (ch < 1 || ch > 4) ch = 1;
            }
            // Клетка абсолютная: страница*16 + позиция, до четырёх страниц.
            if (cell >= 0 && cell <= 63 && p[1] != "" && p[2] != "")
                DCUST[cell] = { p: p[1], m: p[2], cw: cw, ch: ch };
        }
    }
    dc_pack();
    return DCUST;
}

function dcust_save() {
    dc_pack();
    let out = [];
    for (let k, v in DCUST)
        push(out, sprintf("%s:%s:%s:%dx%d", k, v.p, v.m, v.cw ?? 1, v.ch ?? 1));
    if (ucur) {
        if (length(out) > 0) ucur.set("almond3s", "display", "dcust", join(",", out));
        else ucur.delete("almond3s", "display", "dcust");
        ucur.commit("almond3s");
    }
    DCUST_PAGES = null;
}

function zp_data() {
    let now = time();
    if (ZP_CACHE != null && now - ZP_TS < 5) return ZP_CACHE;
    ZP_TS = now;
    ZP_CACHE = zig_json(ZIG_PEERS);
    return ZP_CACHE;
}

// Карточка зигби-виджета: та же плашка и свечение, что у родных плиток, но
// полоска-акцент ПУНКТИРНАЯ - фирменный маркер «приехало по радио», в одном
// языке с пунктиром ожидания STA. Ни пикселя текста не тратит, читается на
// любом размере.
function zp_card(b, o, acc) {
    lcd_rect(b.x, b.y, b.w, b.h, o.card);
    if (BARS_ON) {
        // Ритм сегментов - канонический, как у прогрессбаров (SEG_W/SEG_GAP
        // через seg_geom). Якорь к нижнему краю, как у seg_vbar; верхний
        // сегмент дотягивается до верха - полоска касается обоих краёв.
        let g = seg_geom(b.h);
        for (let i = 0; i < g.n; i++) {
            let sy = b.y + b.h - i * g.pitch - g.sz;
            let sh = g.sz;
            if (i == g.n - 1) { sh = sy + sh - b.y; sy = b.y; }
            lcd_rect(b.x, sy, 3, sh, o.mono ?? acc);
        }
    }
    dash_glow(b, o, acc);
}

// Различительный хвост имени элмонда: суффикс после последнего «_» -
// «Pro», «13»; на 1x1 полное имя не влезает, а хвоста достаточно.
function zp_tail(p) {
    let parts = split(p ?? "", "_");
    return tcut(parts[length(parts) - 1] ?? "", 4);
}

// Плитка слота: иерархия как у родных виджетов - метрика верхней строкой,
// значение крупно, гейдж/доп.инфа внизу. Владелец - приглушённо в правом
// углу (на 1x1 - хвост имени). После минуты тишины акцент гаснет до серого,
// после трёх минут значения сменяются на «--».
function dash_zmetric(b, o, t, n) {
    let name = tcut(t.p, 11);
    let m = n?.m ?? {};
    let fresh = n != null && int(+(n.age ?? 999)) < 180;
    let met = t.m, lbl = dc_met_label(met);
    let wide = (t.cw ?? 1) >= 2, tall = (t.ch ?? 1) >= 2;

    let val = "--", col = C.dim, pct = -1, extra = null, extra2 = null;
    if (fresh) {
        if (met == "sig") {
            let sp = m.sig != null ? int(+m.sig) : -1;
            col = dash_lvl_col(sp);
            if (sp >= 0) { val = sprintf("%d%%", sp); pct = sp; }
            extra = trim(sprintf("%s %s %s", m.oper ?? "", m.mode ?? "", m.band ?? ""));
            if (m.rsrp != null) extra2 = sprintf("RSRP %d dBm", int(+m.rsrp));
        } else if (met == "batt") {
            let pc = m.batt != null ? int(+m.batt) : -1;
            col = pc < 0 ? C.dim : (pc >= 40 ? C.green : (pc >= 15 ? C.orange : C.red));
            if (pc >= 0) {
                val = sprintf("%d%%%s", pc, int(+(m.chg ?? 0)) == 1 ? "+" : "");
                pct = pc;
                extra = int(+(m.chg ?? 0)) == 1 ? tr("charging") : tr("on battery");
            }
        } else if (met == "temp") {
            let tv = m.temp != null ? int(+m.temp) : 0;
            if (tv != 0) { val = sprintf("%d°C", tv); col = tv >= 70 ? C.red : A_ORANGE; }
        } else if (met == "cpu" || met == "mem") {
            let v = m[met] != null ? int(+m[met]) : -1;
            if (v >= 0) { val = sprintf("%d%%", v); pct = v; col = v >= 85 ? C.orange : C.cyan; }
            if (met == "cpu" && m.mem != null)
                extra = sprintf("%s %d%%", tr("Memory"), int(+m.mem));
            if (met == "mem" && m.disk != null)
                extra = sprintf("%s %d%%", tr("Disk"), int(+m.disk));
        } else if (met == "ping") {
            let ms = m.ping != null ? int(+m.ping) : -1;
            if (ms >= 0) {
                val = sprintf("%d %s", ms, tr("ms"));
                col = ms < 80 ? C.green : (ms < 250 ? C.orange : C.red);
            }
        } else if (met == "up") {
            if (m.up != null) {
                let s = int(+m.up) * 60;
                val = wide ? fmt_uptime(s) : fmt_uptime_c(s);
                col = A_CYAN;
            }
        } else if (met == "vpn") {
            let von = int(+(m.vpn ?? 0)) == 1;
            val = von ? tr("on") : tr("off");
            col = von ? A_PURPLE : C.dim;
            if ((m.vpn_node ?? "") != "") extra = tcut(m.vpn_node, 24);
        } else if (met == "link") {
            let zr = int(+(n.rssi ?? 0));
            val = sprintf("%d dBm", zr);
            col = zig_rssi_col(zr);
            pct = zig_rssi_bar(zr);
            extra = sprintf("LQI %d", int(+(n.lqi ?? 0)));
            extra2 = sprintf("%d %s", int(+(n.age ?? 0)), tr("sec"));
        } else if (met == "tx") {
            if (m.tx != null) { val = fmt_bytes(int(+m.tx)); col = A_TEAL; }
            if (m.rx != null) extra = "RX " + fmt_bytes(int(+m.rx));
        }
    }

    // Тишина дольше минуты приглушает акцент, значения ещё живут.
    let semi = fresh && int(+(n.age ?? 999)) >= 60;
    let acc = semi ? C.dim : col;

    zp_card(b, o, acc);
    if (!wide && !tall) {
        // 1x1: метрика сверху (как у родных), хвост имени в углу, значение;
        // у гейджей внизу полоса, у остальных - полное имя владельца.
        let tl = zp_tail(t.p);
        lcd_text_r(b.x + b.w - 6, b.y + 6, tl, o.dim, "none", 1);
        lcd_text(b.x + 12, b.y + 6,
                 tcut(lbl, int((b.w - 22 - twpx(tl, 1)) / 6)), o.dim, "none", 1);
        dash_val(b, o, val, col);
        if (pct >= 0) dash_bar(b, o, pct, col, sprintf("z%d_%d_%s", b.x, b.y, met));
        else dash_sub(b, o, tcut(t.p, 9));
        return;
    }

    dash_lab(b, o, lbl);
    dash_right(b, o, b.y + 6, tcut(t.p, (t.cw ?? 1) >= 4 ? 14 : 10));
    if (tall) {
        // 2x2: значение крупным кеглем, ниже доп.строки, у гейджей полоса.
        let ap = IS_ALMONDPLUS;
        lcd_text_fit(b.x + 12, b.y + (ap ? 24 : 20), val, o.mono ?? col, "none", 3, b.w - 24);
        if (extra) lcd_text(b.x + 12, b.y + (ap ? 24 + fpx(3) + 10 : 56), tcut(extra, 22), o.dim, "none", 1);
        if (extra2) lcd_text(b.x + 12, b.y + (ap ? 24 + fpx(3) + 26 : 70), tcut(extra2, 22), o.dim, "none", 1);
    } else {
        dash_val(b, o, val, col);
        // В один ряд высоты доп.строка одна: на 4x1 вторая приклеивается к
        // первой, ниже места нет - там полоса.
        let ex = extra;
        if (extra2 && (t.cw ?? 1) >= 4) ex = ex ? ex + "  " + extra2 : extra2;
        if (ex) dash_right(b, o, b.y + (IS_ALMONDPLUS ? 24 : 21), tcut(ex, (t.cw ?? 1) >= 4 ? 34 : 20));
    }
    if (pct >= 0)
        dash_bar(b, o, pct, col, sprintf("z%d_%d_%s", b.x, b.y, met));
}

// Редактор: сетка 4x4 и двухшаговый выбор (устройство, затем метрика).
function dc_cell_rect(i) {
    let cw = int((GW - 3 * GG) / 4), chh = int((GVB - GVT - 14 - 3 * GG) / 4);
    return { x: GX + (i % 4) * (cw + GG),
             y: GVT + 14 + int(i / 4) * (chh + GG), w: cw, h: chh };
}

let DC_DEL_H = IS_ALMONDPLUS ? 38 : 30;

function dc_opt_rect(i) {
    let w = int((GW - GG) / 2);
    if (!IS_ALMONDPLUS)
        return { x: GX + (i % 2) * (w + GG), y: GVT + 16 + int(i / 2) * 28,
                 w: w, h: 24 };
    let v = vfit(GVT + 16, GVB - DC_DEL_H - GG, 6);
    return { x: GX + (i % 2) * (w + GG), y: v.y0 + int(i / 2) * v.step, w: w, h: v.h };
}

// Прямоугольник слота с размером: те же клетки, растянутые через зазоры.
function dc_slot_rect(i, cw, ch) {
    let b = dc_cell_rect(i);
    return { x: b.x, y: b.y,
             w: cw * b.w + (cw - 1) * GG,
             h: ch * b.h + (ch - 1) * GG };
}

// Чья это клетка: номер слота, который её накрывает, или -1. Клетки
// абсолютные (страница*16+позиция), слоты не пересекают границы страниц.
function dc_covered(d, cell) {
    let pg = int(cell / 16), c = (cell % 16) % 4, r = int((cell % 16) / 4);
    for (let k, v in d) {
        if (int(int(k) / 16) != pg) continue;
        let c0 = (int(k) % 16) % 4, r0 = int((int(k) % 16) / 4);
        if (c >= c0 && c < c0 + (v.cw ?? 1) && r >= r0 && r < r0 + (v.ch ?? 1))
            return int(k);
    }
    return -1;
}

// Сколько страниц показывает редактор: занятые плюс одна пустая про запас
// (потолок - четыре). Заполнил последнюю - появляется следующая.
function dc_edit_pages() {
    let mx = -1;
    for (let k, v in dcust_load()) {
        let pg = int(int(k) / 16);
        if (pg > mx) mx = pg;
    }
    let n = mx + 2;
    if (n < 1) n = 1;
    if (n > 4) n = 4;
    return n;
}

let DC_SIZES = [ [1,1], [2,1], [4,1], [2,2] ];

function dc_opts() {
    let o = [];
    if (st.dcp?.stage == "peer") {
        let zd = zp_data();
        let peers = type(zd?.peers) == "array" ? zd.peers : [];
        for (let p in peers)
            if ((p.name ?? "") != "") push(o, { l: tcut(p.name, 20), v: p.name });
    } else if (st.dcp?.stage == "size") {
        let c = (st.dcp.cell % 16) % 4, r = int((st.dcp.cell % 16) / 4);
        for (let s in DC_SIZES)
            if (c + s[0] <= 4 && r + s[1] <= 4)
                push(o, { l: sprintf("%d x %d", s[0], s[1]),
                          v: sprintf("%dx%d", s[0], s[1]) });
    } else {
        for (let x in DC_METS) push(o, { l: dc_met_label(x.k), v: x.k });
    }
    return o;
}

// Пустой слот - пунктирной рамкой с плюсом, как карточка ожидания STA в
// «Сети»: то же перо (штрих 3px с шагом 6), тот же приглушённый цвет.
function dc_dashed_cell(b) {
    for (let dx = 0; dx < b.w - 3; dx += 6) {
        lcd_rect(b.x + dx, b.y, 3, 1, C.dim);
        lcd_rect(b.x + dx, b.y + b.h - 1, 3, 1, C.dim);
    }
    for (let dy = 0; dy < b.h - 3; dy += 6) {
        lcd_rect(b.x, b.y + dy, 1, 3, C.dim);
        lcd_rect(b.x + b.w - 1, b.y + dy, 1, 3, C.dim);
    }
    lcd_text_c(b.x + int(b.w / 2), mid_y(b, 2), "+", C.dim, C.bg, 2);
}

function draw_dcust_page() {
    lcd_clear(C.bg);
    draw_header(tr("Custom widgets"));
    let d = dcust_load();
    if (st.dcp == null) {
        lcd_text(GX + 2, GVT, tr("tap a cell to assign"), C.ontop_dim, C.bg, 1);
        let pg = st.dc_pg ?? 0;
        for (let i = 0; i < 16; i++) {
            let cell = pg * 16 + i;
            let own = dc_covered(d, cell);
            if (own == cell) {
                // Та же плитка, что в меню и на заставке: полоска-акцент,
                // свечение, мелкая строка сверху, название вторым кеглем.
                let s = d[cell];
                draw_btn(dc_slot_rect(i, s.cw ?? 1, s.ch ?? 1), null,
                         dc_met_label(s.m), null, null, null, null,
                         null, null, dc_met_accent(s.m), tcut(s.p, 11));
            } else if (own < 0) {
                dc_dashed_cell(dc_cell_rect(i));
            }
            // клетка под чужим слотом не рисуется - её накрыла плитка
        }
        draw_back_pager(pg, dc_edit_pages());
        lcd_flush();
        return;
    } else {
        lcd_text(GX + 2, GVT,
                 st.dcp.stage == "peer" ? tr("pick a device")
                 : (st.dcp.stage == "size" ? tr("pick a size") : tr("pick a metric")),
                 C.ontop_dim, C.bg, 1);
        let o = dc_opts();
        if (length(o) == 0)
            lcd_text(GX + 12, GVT + 40, tr("no peers heard"), C.ontop_dim, C.bg, 2);
        for (let i = 0; i < length(o) && i < 12; i++) {
            let b = dc_opt_rect(i);
            let acc = st.dcp.stage == "met" ? dc_met_accent(o[i].v) : C.cyan;
            let c = gcard(b.x, b.y, b.w, b.h, acc);
            lcd_text(c.ix, mid_y(b, 1), tcut(o[i].l, 22), C.white, C.widget, 1);
        }
        // Настроенный слот: внизу его строка с красным минусом за
        // разделителем - как карточка интерфейса в «Сети». Тап - удалить.
        let s = st.dcp.stage == "peer" ? d[st.dcp.cell] : null;
        if (s != null) {
            let ry = IS_ALMONDPLUS ? GVB - DC_DEL_H : GVB - 32;
            let c = gcard(GX, ry, GW, DC_DEL_H, dc_met_accent(s.m));
            lcd_text(c.ix, IS_ALMONDPLUS ? mid_y(c, 1) : ry + 11, tcut(dc_met_label(s.m) + "  " + s.p, 32),
                     C.white, C.widget, 1);
            lcd_rect(GX + GW - NP_MINUS_W, ry + 4, 1, DC_DEL_H - 8, C.border);
            lcd_text(GX + GW - NP_MINUS_W + 10, IS_ALMONDPLUS ? ry + int((DC_DEL_H - fpx(3)) / 2) : ry + 4,
                     "-", C.red, C.widget, 3);
        }
    }
    draw_back();
    lcd_flush();
}

// Последнее сообщение перед «смертью»: как только запущен sysupgrade (из
// админки или CLI), пока демон ещё жив, показываем красную карточку. Она
// застынет на экране на всё время прошивки - раньше в этот момент висел
// случайный кадр дашборда, будто аппарат завис.
function draw_fw_flash() {
    lcd_clear(C.bg);
    gcard(GX, GVT, GW, GVB - GVT, C.red);
    let cx = int(LCD_W / 2);
    lcd_text_c(cx, GVT + 56, tr("Flashing…"), C.red, C.widget, 4);
    lcd_text_c(cx, GVT + 104, tr("Do not power off"), C.white, C.widget, 2);
    lcd_text_c(cx, GVT + 134, tr("Screen will freeze for a few minutes"), C.gray, C.widget, 1);
    lcd_flush();
}

function draw_current() {
    // Идёт выключение/перезагрузка - на экране заставка «Выключаю...» /
    // «Перезагружаюсь...», и перерисовывать поверх неё нельзя: reboot лишь
    // сигналит procd и возвращает управление, а тот ещё несколько секунд
    // гасит службы - без этого гварда таймеры успевали нарисовать меню
    // поверх заставки, и пользователь видел интерфейс перед ребутом.
    if (st.halting) return;
    // Идёт прошивка - держим только красную карточку, ничего поверх.
    if (st.flashing_fw) { draw_fw_flash(); return; }

    // Пульт держим включённым на всех страницах раздела «Игры», включая экран
    // с QR-кодами: сканировать код имеет смысл только когда сервер уже слушает.
    // Проверяем здесь, а не в go_page: служебный переход по /tmp/.lcd_goto его
    // не вызывает, да и вернуться в раздел можно разными путями.
    {
        let want = (st.page == "games" || st.page == "gset" ||
                    st.page == "gqr"   || st.page == "gkeys");
        if (want != st.pad_on) {
            st.pad_on = want;
            if (want) pad_start(); else pad_stop();
        }
    }

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
    case "update":    draw_update_page(); break;
    case "relnotes":  draw_relnotes_page(); break;
    case "power":     draw_power_page(); break;
    case "led":       draw_led_page(); break;
    case "battery":   draw_battery_page(); break;
    case "savercfg":  draw_savercfg_page(); break;
    case "saver":     draw_saver_page(); break;
    case "dcust":     draw_dcust_page(); break;
    case "debug":     draw_debug_page(); break;
    case "iconedit":  draw_iconedit_page(); break;
    case "zigbee":    draw_zigbee_page(); break;
    case "zwave":     draw_zwave_page(); break;
    case "zigset":    draw_zigset_page(); break;
    case "zignets":   draw_zignets_page(); break;
    case "mqtt":      draw_mqtt_page(); break;
    case "zigpeer":   draw_zigpeer_page(); break;
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

let DASH_PING_HOST = "77.88.8.8";
let DASH_G = 6, DASH_MX = 7, DASH_MY = 7;
// Нижняя полоса под подпись страницы и точки-пагинатор (крупнее на Almond+ из-за
// укрупнённого шрифта). Сетка виджетов заканчивается над ней, а не в самом низу.
let DASH_BAND = IS_ALMONDPLUS ? 24 : 15;
let DASH_CW = int((LCD_W - 2 * DASH_MX - 3 * DASH_G) / 4);
let DASH_CH = int((LCD_H - DASH_MY - DASH_BAND - 3 * DASH_G) / 4);
let DASH_PAGE_SECS = 16;

let DASH_PAGES = [
    { title: "Overview", tiles: [
        { k: "clock",   c: 0, r: 0, cw: 2, ch: 2 },
        { k: "weather", c: 2, r: 0, cw: 2, ch: 1 },
        { k: "batt",    c: 2, r: 1, cw: 1, ch: 1 },
        { k: "wifi",    c: 3, r: 1, cw: 1, ch: 1 },
        { k: "sig",     c: 0, r: 2, cw: 2, ch: 1 },
        { k: "ping",    c: 2, r: 2, cw: 1, ch: 1 },
        { k: "sms",     c: 3, r: 2, cw: 1, ch: 1 },
        { k: "traffic", c: 0, r: 3, cw: 4, ch: 1 },
    ] },
    { title: "Modem", tiles: [
        // Имя оператора уже подписывает карточку сигнала на «Обзоре» - здесь
        // вместо дубля агрегация несущих и модель модема, их больше нигде нет.
        { k: "ca",      c: 0, r: 0, cw: 2, ch: 1 },
        { k: "band",    c: 2, r: 0, cw: 1, ch: 1 },
        { k: "mtemp",   c: 3, r: 0, cw: 1, ch: 1 },
        // Уровни одним рядом в привычном порядке: мощность, качество,
        // отношение сигнал/шум и напоследок CSQ.
        { k: "rsrp",    c: 0, r: 1, cw: 1, ch: 1 },
        { k: "rsrq",    c: 1, r: 1, cw: 1, ch: 1 },
        { k: "sinr",    c: 2, r: 1, cw: 1, ch: 1 },
        { k: "csq",     c: 3, r: 1, cw: 1, ch: 1 },
        { k: "grsrp",   c: 0, r: 2, cw: 4, ch: 1 },
        { k: "mip",     c: 0, r: 3, cw: 2, ch: 1 },
        { k: "apn",     c: 2, r: 3, cw: 2, ch: 1 },
    ] },
    { title: "Machine", tiles: [
        // CPU занял и своё место, и освободившееся от VPN: ядрам нужна ширина
        // под нормальные горизонтальные полосы.
        { k: "cpu",     c: 0, r: 0, cw: 2, ch: 2 },
        { k: "mem",     c: 2, r: 0, cw: 1, ch: 1 },
        { k: "disk",    c: 3, r: 0, cw: 1, ch: 1 },
        { k: "lan",     c: 2, r: 1, cw: 2, ch: 1 },
        { k: "gping",   c: 0, r: 2, cw: 4, ch: 1 },
        { k: "ver",     c: 0, r: 3, cw: 2, ch: 1 },
        { k: "up",      c: 2, r: 3, cw: 1, ch: 1 },
        { k: "load",    c: 3, r: 3, cw: 1, ch: 1 },
    ] },
];

// Almond+: батареи нет - убираем плитку «Батарея» с «Обзора», Wi-Fi занимает её место.
if (!HAS_BATTERY) {
    let nt = [];
    for (let t in DASH_PAGES[0].tiles) {
        if (t.k == "batt") continue;
        if (t.k == "wifi") { t.c = 2; t.cw = 2; }
        push(nt, t);
    }
    DASH_PAGES[0].tiles = nt;
}

// Карусель заставки: базовые страницы плюс «Свои виджеты» (до четырёх
// собственных страниц, в карусель попадают только непустые).
function modem_present() {
    let d = st.data;
    if ((d?.lte?.mode ?? "") != "" || int(+(d?.lte?.rsrp ?? 0)) != 0) return true;
    return fs.access("/dev/cdc-wdm0") || fs.access("/sys/class/net/wwan0") ||
           fs.access("/dev/ttyUSB0") || fs.access("/dev/cdc-wdm1");
}

function dash_pages() {
    let mp = modem_present();
    if (DCUST_PAGES != null && DCUST_MP == mp) return DCUST_PAGES;
    DCUST_MP = mp;
    let d = dcust_load();
    let pages = [];
    for (let pgd in DASH_PAGES) {
        if (pgd.title == "Modem" && !mp) continue;
        push(pages, pgd);
    }
    let cn = 0;
    for (let pg = 0; pg < 4; pg++) {
        let tiles = [];
        for (let k, v in d) {
            if (int(int(k) / 16) != pg) continue;
            let idx = int(k) % 16;
            push(tiles, { k: "zp", c: idx % 4, r: int(idx / 4),
                          cw: v.cw ?? 1, ch: v.ch ?? 1, p: v.p, m: v.m });
        }
        if (length(tiles) > 0) {
            cn++;
            push(pages, { title: cn == 1 ? "Custom" : sprintf("Custom %d", cn),
                          tiles: tiles });
        }
    }
    DCUST_PAGES = pages;
    return DCUST_PAGES;
}

let dash_vpn = { ts: 0, node: "", group: "", cc: "" };

function dash_vpn_now() {
    let now = time();
    if (now - dash_vpn.ts < 20) return dash_vpn;
    dash_vpn.ts = now;
    dash_vpn.node = ""; dash_vpn.group = ""; dash_vpn.cc = "";
    if (!st.vpn_on) return dash_vpn;
    let raw = vpn_sh("groups");
    if (!raw) return dash_vpn;
    try {
        let px = json(raw)?.proxies ?? {};
        for (let name in px) {
            let e = px[name];
            if (e?.hidden || name == "GLOBAL") continue;
            if (type(e?.all) != "array" || length(e.all) == 0) continue;
            let nw = e?.now ?? "";
            if (nw == "") continue;
            let fl = vpn_flag(nw);
            dash_vpn.cc = fl[0];
            dash_vpn.node = fl[1];
            dash_vpn.group = vpn_flag(name)[1];
            break;
        }
    } catch(e) {}
    return dash_vpn;
}

function dash_date() {
    let t = localtime();
    if (!t) return "--";
    let M = lang() == "ru" ? MONTHS_RU : MONTHS_EN;
    return sprintf("%d %s", t.mday, M[clampi(t.mon, 1, 12) - 1]);
}

// Номер текущей страницы держим явно, а не выводим из часов: выбор страницы
// пальцем должен переводить ровно на неё и начинать её показ с полного
// интервала, а дальше цикл продолжается уже от неё.
// Пауза перелистывания заставки. Живёт в настройках, поэтому переживает и
// выход из заставки, и перезапуск службы: человек оставил нужный экран - он
// там и останется.
function dash_hold() {
    return (ucur ? ucur.get("almond3s", "display", "dash_hold") : null) == "1";
}

function dash_hold_set(on) {
    if (!ucur) return;
    ucur.set("almond3s", "display", "dash_hold", on ? "1" : "0");
    ucur.commit("almond3s");
}

function dash_page() {
    let n = length(dash_pages());
    if (st.dash_t0 == null) { st.dash_t0 = time(); st.dash_cur = 0; }
    if (dash_hold()) {
        // Отсчёт держим сдвинутым, иначе при снятии паузы страница
        // перескочила бы сразу на несколько вперёд.
        st.dash_t0 = time();
        return st.dash_cur ?? 0;
    }
    let steps = int((time() - st.dash_t0) / DASH_PAGE_SECS);
    if (steps > 0) {
        st.dash_cur = ((st.dash_cur ?? 0) + steps) % n;
        st.dash_t0 += steps * DASH_PAGE_SECS;
    }
    return st.dash_cur ?? 0;
}

function dash_goto(i) {
    st.dash_cur = i % length(dash_pages());
    st.dash_t0 = time();
}

// Пасхалка: точки-страницы внизу заставки выбирают страницу, а не будят экран.
// Возвращает номер точки под пальцем или -1.
// Кнопка паузы - в том же нижнем ряду, слева перед названием страницы, того
// же размера, что и точки страниц.
function dash_hold_btn(x, y, col) {
    if (dash_hold()) {
        // Значок показывает СОСТОЯНИЕ, а не действие: стоит пауза - видна
        // пауза, идёт перелистывание - видно «играть».
        lcd_rect(x, y, 2, 7, col);
        lcd_rect(x + 4, y, 2, 7, col);
    } else {
        for (let i = 0; i < 4; i++)
            lcd_rect(x + i, y + i, 1, 7 - i * 2, col);
    }
}

function dash_hold_at(tx, ty) {
    let ox = st.ox ?? 0, oy = st.oy ?? 0;
    return ty >= LCD_H - 22 + oy && ty <= LCD_H + oy && tx >= 4 + ox && tx <= 22 + ox;
}

function dash_dot_at(tx, ty) {
    let ox = st.ox ?? 0, oy = st.oy ?? 0;
    let n = length(dash_pages());
    if (ty < LCD_H - 22 + oy || ty > LCD_H + oy) return -1;
    for (let i = 0; i < n; i++) {
        let dx = LCD_W - 10 - (n - i) * 12 + ox;
        if (tx >= dx - 2 && tx <= dx + 9) return i;
    }
    return -1;
}


function dash_box(t) {
    return {
        x: DASH_MX + t.c * (DASH_CW + DASH_G) + (st.ox ?? 0),
        y: DASH_MY + t.r * (DASH_CH + DASH_G) + (st.oy ?? 0),
        w: t.cw * DASH_CW + (t.cw - 1) * DASH_G,
        h: t.ch * DASH_CH + (t.ch - 1) * DASH_G,
    };
}

function dash_tile(t, d, o) {
    let b = dash_box(t);

    if (t.k == "zp") {
        let zd = zp_data(), n = null;
        let peers = type(zd?.peers) == "array" ? zd.peers : [];
        for (let q in peers) if ((q.name ?? "") == t.p) { n = q; break; }
        dash_zmetric(b, o, t, n);
        return;
    }

    if (t.k == "clock") {
        dash_card(b, o, A_CYAN);
        let ap = IS_ALMONDPLUS;
        lcd_text(b.x + 12, b.y + 14, clock_str(), o.fg, "none", 4);
        lcd_text(b.x + 12, b.y + (ap ? 14 + fpx(4) + 8 : 56), dash_date(), o.mono ?? A_CYAN, "none", 2);
        lcd_text(b.x + 12, ap ? b.y + b.h - 18 : b.y + 82, fmt_uptime(d?.uptime), o.dim, "none", 1);
        return;
    }

    if (t.k == "batt" || t.k == "batt2") {
        let bt = d?.battery, pc = int(+(bt?.percent ?? -1));
        let col = pc < 0 ? C.dim : (pc >= 40 ? C.green : (pc >= 15 ? C.orange : C.red));
        dash_gauge(b, o, col, tr("Battery"), pc >= 0 ? sprintf("%d%%", pc) : "--", pc, col);
        if (t.k == "batt2")
            dash_right(b, o, b.y + 6, bt?.charging ? tr("charging") : tr("on battery"));
        return;
    }

    if (t.k == "wifi") {
        let nc = type(d?.wifi?.clients) == "array" ? length(d.wifi.clients) : 0;
        let wcol = nc > 0 ? A_TEAL : C.dim;
        dash_simple(b, o, wcol, "Wi-Fi", sprintf("%d", nc), tr("clients"), wcol);
        return;
    }

    if (t.k == "sig") {
        let pct = dash_sig_pct(d), col = dash_lvl_col(pct);
        let rsrp = int(+(d?.lte?.rsrp ?? 0));
        dash_gauge(b, o, col, tcut(d?.lte?.operator ?? tr("no network"), 14),
                   pct >= 0 ? sprintf("%d%%", pct) : "--", pct >= 0 ? pct : 0, col);
        let badge = trim(sprintf("%s %s", d?.lte?.mode ?? "", d?.lte?.band ?? ""));
        if (badge != "") dash_right(b, o, b.y + 6, badge, A_CYAN);
        if (rsrp != 0) dash_right(b, o, b.y + (IS_ALMONDPLUS ? 24 : 21), sprintf("%d dBm", rsrp));
        return;
    }

    if (t.k == "traffic") {
        dash_card(b, o, A_GREEN);
        let rx = length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0;
        let tx = length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0;
        let ap = IS_ALMONDPLUS;
        lcd_text(b.x + 12, b.y + 8, fmt_bytes(rx) + "/s", o.mono ?? C.green, "none", 2);
        lcd_text(b.x + 12, b.y + (ap ? 8 + fpx(2) + 6 : 28), fmt_bytes(tx) + "/s", o.mono ?? C.cyan, "none", 2);
        let gx = b.x + (ap ? 170 : 100), gy = b.y + 5, gw = b.w - (ap ? 182 : 112), gh = b.h - 10;
        let rm = arr_minmax(hist.rx), tm = arr_minmax(hist.tx);
        let mx = rm.max > tm.max ? rm.max : tm.max;
        if (mx < 512) mx = 512;
        bar_graph(gx, gy, gw, gh,
                  [ { data: hist.rx, color: o.mono ?? C.green },
                    { data: hist.tx, color: o.mono ?? C.cyan } ], 0, mx);
        return;
    }

    if (t.k == "vpn") {
        let v = dash_vpn_now();
        let on = st.vpn_on == true && v.node != "";
        dash_card(b, o, on ? A_PURPLE : C.dim);
        dash_lab(b, o, "VPN");
        if (on) {
            let vx = b.x + 12, vy = b.y + (IS_ALMONDPLUS ? 26 : 20);
            if (v.cc != "" && !o.mono) { draw_cflag(vx, vy, v.cc); vx += 20; }
            lcd_text(vx, vy, tcut(v.node, int((b.w - (vx - b.x) - 12) / 6)),
                     o.mono ?? A_PURPLE, o.card, 1);
            dash_sub(b, o, tcut(v.group, 22));
        } else {
            dash_val(b, o, tr("off"), o.dim);
        }
        return;
    }

    if (t.k == "ping") {
        let ms = int(+(d?.ping?.google_ms ?? -1));
        let col = ms < 0 ? C.dim : (ms < 80 ? C.green : (ms < 250 ? C.orange : C.red));
        dash_simple(b, o, col, tr("Ping"), ms >= 0 ? sprintf("%d", ms) : "--", DASH_PING_HOST, col);
        return;
    }

    if (t.k == "sms") {
        let n = int(+(d?.sms_new ?? 0));
        dash_simple(b, o, n > 0 ? A_ORANGE : C.dim, "SMS", sprintf("%d", n), tr("new msgs"), n > 0 ? A_ORANGE : o.dim);
        return;
    }

    if (t.k == "oper") {
        dash_simple(b, o, A_CYAN, tr("Operator"), tcut(d?.lte?.operator ?? "--", 22),
                    tcut(sprintf("%s  %s", d?.lte?.mode ?? "", d?.lte?.modem ?? ""), 22),
                    o.mono ?? A_CYAN);
        return;
    }

    if (t.k == "rsrp") {
        let v = int(+(d?.lte?.rsrp ?? 0));
        let rcol = dash_lvl_col(v != 0 ? clampi(int(MET.rsrp.bar(v)), 0, 100) : -1);
        dash_simple(b, o, rcol, "RSRP", v != 0 ? sprintf("%d", v) : "--", "dBm", rcol);
        return;
    }

    if (t.k == "rsrq") {
        let v = int(+(d?.lte?.rsrq ?? 0));
        let qcol = v == 0 ? C.dim : (v >= -10 ? C.green : (v >= -15 ? C.orange : C.red));
        dash_simple(b, o, qcol, "RSRQ", v != 0 ? sprintf("%d", v) : "--", "dB", qcol);
        return;
    }

    if (t.k == "sinr") {
        let v = int(+(d?.lte?.sinr ?? 0));
        let scol = v >= 10 ? C.green : (v >= 0 ? C.orange : C.red);
        dash_simple(b, o, scol, "SINR", sprintf("%d", v), "dB", scol);
        return;
    }

    if (t.k == "csq") {
        let v = int(+(d?.lte?.csq ?? 0));
        let qq = v == 0 ? C.dim : (v >= 20 ? C.green : (v >= 10 ? C.orange : C.red));
        dash_simple(b, o, qq, "CSQ", sprintf("%d", v), "0-31", qq);
        return;
    }

    if (t.k == "mtemp") {
        let v = int(+(d?.lte?.temp ?? 0));
        let tc = v == 0 ? C.dim : (v >= 70 ? C.red : A_ORANGE);
        dash_simple(b, o, tc, tr("Temp"), v != 0 ? sprintf("%d°C", v) : "--", tr("Modem"), tc);
        return;
    }

    if (t.k == "band") {
        dash_simple(b, o, A_CYAN, "Band", tcut(d?.lte?.band ?? "--", 4),
                    sprintf("PCI %d", int(+(d?.lte?.pci ?? 0))), A_CYAN);
        return;
    }

    if (t.k == "grsrp") {
        dash_card(b, o, A_GREEN);
        dash_lab(b, o, "RSRP");
        let mm = arr_minmax(hist.rsrp);
        let lo = mm.min < 0 ? mm.min - 2 : -120, hi = mm.max < 0 ? mm.max + 2 : -60;
        if (hi <= lo) hi = lo + 10;
        dash_right(b, o, b.y + 6, sprintf("%d..%d dBm", lo, hi));
        bar_graph(b.x + 12, b.y + 16, b.w - 24, b.h - 22,
                  [ { data: hist.rsrp, color: o.mono ?? A_GREEN } ], lo, hi);
        return;
    }

    if (t.k == "gping") {
        dash_card(b, o, A_TEAL);
        dash_lab(b, o, tr("Ping"));
        let mm = arr_minmax(hist.ping);
        let hi = mm.max > 20 ? mm.max : 20;
        dash_right(b, o, b.y + 6, sprintf("0..%d ms", hi));
        bar_graph(b.x + 12, b.y + 16, b.w - 24, b.h - 22,
                  [ { data: hist.ping, color: o.mono ?? A_TEAL } ], 0, hi);
        return;
    }

    if (t.k == "mip") {
        dash_simple(b, o, A_TEAL, "IP", tcut(d?.lte?.ip ?? "--", 22), tr("Modem"),
                    o.mono ?? A_TEAL);
        return;
    }

    if (t.k == "ca") {
        // Показываем ВСЕ несущие: активные акцентом, спящие приглушённо - как
        // 5gmodem. Полоса-акцент карточки цветная, только когда есть хотя бы
        // одна активная вторичная несущая (реальная агрегация).
        let segs = carrier_segs(d?.lte ?? {});
        let agg = (d?.lte?.ca ?? "") != "" && (d?.lte?.ca ?? "") != "-";
        dash_card(b, o, agg ? A_TEAL : C.dim);
        dash_lab(b, o, tr("Aggregation"));
        if (length(segs) == 0) {
            dash_val(b, o, "--", o.dim ?? C.dim);
        } else {
            let con = o.mono ?? A_TEAL, coff = o.dim ?? C.dim;
            let sz = ca_width(segs, 2) > b.w - 24 ? 1 : 2;
            draw_ca(b.x + 12, b.y + (IS_ALMONDPLUS ? TILE_TTL_Y : 19), segs, sz, "none", con, coff);
        }
        dash_sub(b, o, tcut(d?.lte?.modem ?? "", 22));
        return;
    }

    if (t.k == "apn") {
        dash_simple(b, o, A_PURPLE, "APN", tcut(d?.lte?.apn ?? "--", 22),
                    tcut(sprintf("%s %s", tr("online"), conn_fmt(d?.lte?.conn_time)), 22),
                    o.mono ?? A_PURPLE);
        return;
    }

    if (t.k == "cpu") {
        let busy = int(+(d?.cpu_busy ?? -1));
        let col = busy >= 85 ? A_ORANGE : A_CYAN;
        let cores = type(d?.cpu_core_busy) == "array" ? d.cpu_core_busy : [];
        let n = length(cores);
        if (n < 1 || b.w < 120) {
            dash_gauge(b, o, col, "CPU", busy >= 0 ? sprintf("%d%%", busy) : "--",
                       busy, col);
            return;
        }
        // Высокая карточка - ядра ложатся горизонтально: полосы получаются
        // длинными, и это те же секционные прогрессбары, что и везде.
        if (b.h > 60) {
            dash_card(b, o, col);
            dash_lab(b, o, "CPU");
            dash_val(b, o, busy >= 0 ? sprintf("%d%%", busy) : "--", col);
            // Кто именно ест процессор - списком справа, по правому краю.
            // Сборщик отдаёт долю от всей машины по приращению между тиками,
            // поэтому список показывает текущих едоков, а не долгожителей.
            let top = type(d?.cpu_top) == "array" ? d.cpu_top : [];
            let half = b.x + int(b.w / 2) - 4;
            // Строки по 9 пикселей от y+6: в карточку 106 пикселей высотой их
            // помещается десять, ровно столько сборщик и присылает.
            let rows = int((b.h - 12) / 9);
            if (rows > (IS_ALMONDPLUS ? 14 : 10)) rows = IS_ALMONDPLUS ? 14 : 10;
            for (let i = 0; i < length(top) && i < rows; i++) {
                let nm = tcut(top[i].n ?? "", 12);
                if (nm == "") continue;
                lcd_text_r(b.x + b.w - 10, b.y + 6 + i * 9, nm,
                           i == 0 ? (o.mono ?? col) : o.dim, o.card, 1);
            }
            let ap = IS_ALMONDPLUS;
            let pitch = int((b.h - (ap ? 66 : 52)) / n);
            if (pitch > 16) pitch = 16;
            if (pitch < 9) pitch = 9;
            let y1 = b.y + (ap ? 60 : 46), bw2 = half - (b.x + 24);
            if (length(top) == 0) bw2 = b.w - 36;
            for (let i = 0; i < n; i++) {
                let v = clampi(int(+(cores[i] ?? 0)), 0, 100);
                let yy = y1 + i * pitch;
                lcd_text(b.x + 12, yy - 1, sprintf("%d", i), o.dim, "none", 1);
                seg_bar(b.x + 24, yy, bw2, 6, v,
                        o.mono ?? (v >= 85 ? A_ORANGE : A_CYAN),
                        o.mono ? "#0A2A16" : C.btn, sprintf("cpuh%d", i));
            }
            return;
        }
        dash_card(b, o, col);
        dash_lab(b, o, "CPU");
        dash_val(b, o, busy >= 0 ? sprintf("%d%%", busy) : "--", col);
        let bwid = 8, gap = 4, gh = IS_ALMONDPLUS ? b.h - 26 : 31;
        let x0 = b.x + b.w - 12 - n * bwid - (n - 1) * gap, y0 = b.y + 6;
        for (let i = 0; i < n; i++) {
            let v = clampi(int(+(cores[i] ?? 0)), 0, 100);
            let bx = x0 + i * (bwid + gap);
            seg_vbar(bx, y0, bwid, gh, v,
                     o.mono ?? (v >= 85 ? A_ORANGE : A_CYAN),
                     o.mono ? "#0A2A16" : C.btn, sprintf("cpu%d", i), 3);
            lcd_text(bx + 1, y0 + gh + 4, sprintf("%d", i), o.dim, "none", 1);
        }
        return;
    }

    if (t.k == "mem") {
        let tot = int(+(d?.mem_total_mb ?? 0)), fr = int(+(d?.mem_free_mb ?? 0));
        let used = tot > 0 ? int((tot - fr) * 100 / tot) : -1;
        let mcol = used >= 85 ? C.orange : C.cyan;
        dash_gauge(b, o, mcol, tr("Memory"), used >= 0 ? sprintf("%d%%", used) : "--", used, mcol);
        return;
    }

    if (t.k == "disk") {
        let tot = int(+(d?.storage?.total_kb ?? 0)), fr = int(+(d?.storage?.free_kb ?? 0));
        let used = tot > 0 ? int((tot - fr) * 100 / tot) : -1;
        let dcol = used >= 85 ? C.orange : C.cyan;
        dash_gauge(b, o, dcol, tr("Disk"), used >= 0 ? sprintf("%d%%", used) : "--", used, dcol);
        return;
    }

    if (t.k == "up") {
        dash_simple(b, o, A_ORANGE, tr("Uptime short"), fmt_uptime_c(d?.uptime), "", o.fg);
        return;
    }

    if (t.k == "load") {
        let la = +(d?.cpu_load ?? 0);
        let nc = int(+(d?.cpu_cores ?? 1)); if (nc < 1) nc = 1;
        dash_simple(b, o, la > nc ? C.orange : A_PURPLE, tr("Load"), sprintf("%.2f", la),
                    tr("1 min"), la > nc ? C.orange : (o.mono ?? A_PURPLE));
        return;
    }

    if (t.k == "weather") {
        let w2 = d?.weather;
        // Акцент и цифра температуры - одним динамическим цветом по значению
        // (тепло-холод), как у других температурных виджетов дашборда.
        let wcol = w2 ? (o.mono ?? weather_temp_col(w2.temp)) : (o.mono ?? A_ORANGE);
        dash_card(b, o, wcol);
        dash_lab(b, o, w2 ? tcut(city_name(w2.city) ?? tr("Weather"), 16) : tr("Weather"));
        if (w2) {
            lcd_text(b.x + 12, b.y + (IS_ALMONDPLUS ? TILE_TTL_Y : 19), tcut(w2.temp ?? "?", 5), wcol, "none", 2);
            dash_sub(b, o, tcut(wcond_tr(w2.desc ?? ""), 18));
            if (!o.mono) {
                if (IS_ALMONDPLUS) draw_weather_icon(b.x + b.w - 60, b.y + int((b.h - 48) / 2), w2.desc ?? "", 2, null);
                else draw_weather_icon(b.x + b.w - 36, b.y + 13, w2.desc ?? "", 1, null);
            }
        } else {
            dash_val(b, o, "--", o.dim);
        }
        return;
    }

    if (t.k == "lan") {
        dash_simple(b, o, A_CYAN, "LAN", tcut(d?.lan?.ip ?? "--", 22),
                    tcut(uc(d?.lan?.mac ?? ""), 22), o.mono ?? A_CYAN);
        return;
    }

    if (t.k == "ver") {
        let bi = board_info();
        dash_simple(b, o, A_PINK, tcut(bi?.model ?? "OpenWrt", 22),
                    tcut(bi?.release?.version ?? "--", 22), tcut(bi?.kernel ?? "", 22),
                    o.mono ?? A_PINK);
        return;
    }
}

function draw_dash_saver(o) {
    let d = st.data;
    let dps = dash_pages();
    let pg = dash_page(), page = dps[pg];
    for (let i = 0; i < length(page.tiles); i++)
        dash_tile(page.tiles[i], d, o);

    let ox = st.ox ?? 0, oy = st.oy ?? 0;
    let by = (IS_ALMONDPLUS ? LCD_H - 18 : 230) + oy;
    let dot_dy = IS_ALMONDPLUS ? 4 : 0;
    // Цвет тот же, что у активной точки страницы.
    dash_hold_btn(9 + ox, by, o.mono ?? "#FFFFFF");
    lcd_text(22 + ox, by, tr(page.title), o.mono ?? C.ontop, o.bg, 1);
    for (let i = 0; i < length(dps); i++) {
        let dx = LCD_W - 10 - (length(dps) - i) * 12 + ox;
        // Активная точка своим цветом, а не цветом текста: в светлой теме текст
        // почти чёрный, и точка выглядела чернильной кляксой на синем фоне.
        lcd_rect(dx, by + dot_dy, 7, 7, i == pg ? (o.mono ?? "#FFFFFF")
                                            : (o.mono ? "#0A2A16" : C.dim));
    }
}

function draw_screensaver_body() {
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
                  empty: night ? "#0A2A16" : null,
                  no_sig: !fl.sig, no_batt: !fl.batt, no_env: !fl.env };

    if (style == "dash") {
        draw_dash_saver({ card: night ? "#07140C" : C.widget, bg: bg,
                          line: night ? "#123D22" : C.border,
                          fg: primary, dim: secondary,
                          mono: night ? primary : null });
        lcd_flush();
        return;
    }

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
        // Единая сетка: часы/дата сверху, ниже равномерно — герой, условие,
        // ряд метрик, у низа остаётся воздух (раньше метрики прилипали к краю).
        let ap = IS_ALMONDPLUS;
        lcd_text(int((LCD_W - twpx(ts, 4)) / 2), 26, ts, primary, "none", 4);
        if (fl.date)
            lcd_text_thin(int(LCD_W / 2), ap ? 26 + fpx(4) + 8 : 58, ds, secondary, "none", 2, "c");

        if (!w2) {
            let c = gcard_pos(GX, ap ? 112 : 84, GW, 76);
            lcd_text(c.ix, c.iy + 20, tr("No data yet"), secondary, "none", 2);
            lcd_text(c.ix, c.iy + (ap ? 52 : 44), tr("Open menu > Weather to fetch"), secondary, "none", 1);
            lcd_flush();
            return;
        }

        let desc = w2.desc ?? "";
        // Герой: температура крупно, иконка справа; город и «обновлено N назад»
        // под ней с одинарным межстрочным отступом (12px при кегле 1).
        let h = gcard_pos(GX, ap ? 108 : 80, GW, ap ? 100 : 70);
        if (ap) draw_weather_icon(h.r - 106, h.y + 2, desc, 4, night ? primary : null);
        else draw_weather_icon(h.r - 82, h.y + 4, desc, 3, night ? primary : null);
        lcd_text(h.ix, h.y + 8, w2.temp ?? "?",
                 night ? primary : weather_temp_col(w2.temp), "none", 4);
        lcd_text(h.ix, h.y + (ap ? 8 + fpx(4) + 6 : 42), city_name(w2.city) ?? "", secondary, "none", 1);
        {
            let ws = fs.stat("/tmp/lcd_weather.txt");
            if (ws && ws.mtime)
                lcd_text(h.ix, h.y + (ap ? 8 + fpx(4) + 20 : 54),
                         sprintf("%s %s", tr("Updated"), fmt_ago(ws.mtime)),
                         night ? primary : C.dim, "none", 1);
        }

        // Условие
        let cc = gcard_pos(GX, ap ? 216 : 156, GW, ap ? 28 : 22);
        lcd_text(cc.ix, cc.y + 4, tcut(wcond_tr(desc), 24), accent, "none", 2);

        // Метрики тремя карточками, подняты от нижнего края.
        let mw = int((GW - 2 * GG) / 3);
        let mets = [ [ tr("Feels"), w2.feels ?? "?" ],
                     [ tr("Humidity"), w2.humidity ?? "?" ],
                     [ tr("Wind"), wind_fmt(w2.wind ?? "") ] ];
        for (let i = 0; i < 3; i++) {
            let mx = GX + i * (mw + GG);
            let mc = gcard_pos(mx, ap ? 252 : 184, (i < 2) ? mw : (GX + GW - mx), ap ? 56 : 42);
            lcd_text(mc.ix, mc.y + 7, mets[i][0], secondary, "none", 1);
            let mv = split_unit(mets[i][1]);
            lcd_text(mc.ix, mc.y + (ap ? 24 : 20), mv[0], primary, "none", 2);
            if (mv[1] != "")
                lcd_text(mc.ix + twpx(mv[0], 2) + 1, mc.y + (ap ? 38 : 19), mv[1], secondary, "none", 1);
        }
        lcd_flush();
        return;
    }

    // В режиме «часы» экран занят только ими, поэтому вдвое крупнее.
    // Ширина знакоместа - ровно 6*масштаб, иначе центрирование врёт.
    let clk_sz = (style == "clock")
               ? (fl.size == "s" ? 6 : (fl.size == "l" ? 10 : 8)) : 5;
    let clk_w = tlen(ts) * 6 * fsz(clk_sz);

    // Дата не должна быть шире часов, иначе строка снизу перевешивает.
    // Берём самый крупный масштаб, который в эту ширину укладывается, а
    // если и двойной не влезает - сокращаем месяц, но масштаб не роняем:
    // «12 авг 2026» вторым читается лучше, чем «12 августа, 2026» первым.
    let date_sz = 0;
    for (let z = 4; z >= 2; z--) {
        if (tlen(ds) * 6 * fsz(z) <= clk_w) { date_sz = z; break; }
    }
    if (date_sz == 0) {
        ds = date_str(true);
        date_sz = (tlen(ds) * 6 * fsz(2) <= clk_w) ? 2 : 1;
    }
    let date_w = tlen(ds) * 6 * fsz(date_sz);
    let date_gap = 10;

    // В режиме «часы» центрируем по вертикали пару целиком - часы и дату.
    if (!fl.date) { date_sz = 0; date_gap = 0; }
    let blk_h = 7 * fsz(clk_sz) + date_gap + 7 * fsz(date_sz);
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
        // Дата тонким начертанием: на парных шрифтах (Комбо/Pixel) заголовок
        // жирный, а служебная строка - светлая; на остальных fnt:-1 игнорится.
        lcd_text_thin(dx, date_y, ds, secondary, bg, date_sz);
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
    // Уровень считает warm_now по текущему времени; on здесь только для Wi-Fi.
    warm_apply();

    let ap_off = on && night_act("night_wifi");
    system(sprintf("%s/night_wifi.sh %s >/dev/null 2>&1 &", SCRIPTS, ap_off ? "off" : "on"));
}

// Ночная тема: если действие включено, ночью уходим в тёмную независимо от
// дневной настройки. Оттенок пересчитываем следом - пары у тем свои.
function night_theme_apply(n) {
    theme_apply((n && night_act("night_theme")) ? "dark" : theme_cfg());
    bg_tint_apply(BG_TINT);
}

function night_tick() {
    let n = night_now();
    if (st.night_was == null) {
        // Применяем в ОБЕ стороны. Раньше при старте днём не делалось ничего -
        // и если ночь застала перезагрузка (или падение интерфейса), точки
        // доступа оставались выключенными на весь день: восстановить их было
        // некому. Скрипт при этом ничего не делает, если гасить было нечего.
        st.night_was = n;
        night_theme_apply(n);
        night_apply(n);
        return;
    }
    if (n == st.night_was) return;
    st.night_was = n;
    night_theme_apply(n);
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

let BL_TOUCH_MIN = 26;
let BL_BOOST_SEC = 15;

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
    if (on && lvl < BL_TOUCH_MIN && st.bl_boost
        && (time() - st.bl_boost) < BL_BOOST_SEC)
        lvl = BL_TOUCH_MIN;
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
function bl_level_now() {
    let lvl = night_dim(int(bright_cfg() * 255 / 100));
    if (lvl > 255) lvl = 255;
    if (lvl < BL_TOUCH_MIN && st.bl_boost && (time() - st.bl_boost) < BL_BOOST_SEC)
        lvl = BL_TOUCH_MIN;
    return lvl;
}

// Погода, Часы и Статусбар рисуем без градиента-подложки, какой бы он ни был
// выбран: это виды с крупными цифрами на пустом поле, и цветная подложка под
// ними только мешает. Тему при этом НЕ трогаем - на тёмной фон чёрный, на
// светлой светлый. Виджеты и сцены не трогаем вовсе, у них своя логика.
function saver_wants_flat(style) {
    return style == "full" || style == "clock" || style == "line";
}

// Градиент гасим только на время кадра и возвращаем сразу после: тело заставки
// успевает отправить кадр (lcd_flush внутри), а страницы продолжают рисоваться
// с выбранной подложкой. Заодно пересчитываем цвета надписей поверх фона - на
// плоской заливке они другие, чем на цветном градиенте.
function draw_screensaver() {
    if (!GRAD_ON || !saver_wants_flat(saver_style())) {
        draw_screensaver_body();
        return;
    }
    GRAD_ON = false;
    ontop_apply();
    draw_screensaver_body();
    GRAD_ON = true;
    ontop_apply();
}

function draw_saver_tick() {
    draw_screensaver();
}

function bl_reassert() {
    if (st.blank || st.halting) return;
    system(sprintf("almond3s-lcd dim %d >/dev/null 2>&1", bl_level_now()));
}

function bl_boost() {
    let was = st.bl_boost;
    st.bl_boost = time();
    if (!st.blank && (was == null || (time() - was) >= BL_BOOST_SEC))
        backlight_write(true);
}

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
    // Автопроверка только при первом заходе (из настроек), не при возврате из
    // релиз-нот - иначе чтение нот сбрасывало бы уже готовый результат.
    if (p == "update" && p != st.page && !is_back) upd_kick_all(false);
    if (p == "relnotes" && p != st.page && !is_back) upd_kick_notes(st.notes_src ?? "almond");
    // Редактор открываем с пикера-хаба: «+» новый рисунок, вшитые иконки, свои
    // сохранённые art-файлы.
    if (p == "iconedit" && st.page != "iconedit") { ed_pick = true; ed_cpick = false; }
    if (p == "dcust" && st.page != "dcust") st.dcp = null; // редактор всегда с сетки
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
    // Запоминаем страницу в tmpfs: служба перезапускается при каждом обновлении
    // пакета, и без этого интерфейс всякий раз поднимался на «Модеме», куда
    // человек не просил. После настоящей перезагрузки файла нет - стартуем с
    // умолчания, как и раньше.
    fs.writefile("/tmp/.lcd_page", p);
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
    if (IS_ALMONDPLUS) {
        lcd_text_thin(6, 3, title, C.white, C.hdr, 2, "l", 1);
        lcd_text_thin(LCD_W - 6, 3, clock_str(), C.cyan, C.hdr, 2, "r", 1);
    } else {
        lcd_text(4, 2, title, C.white, C.hdr, 2);
        lcd_text(LCD_W - 60, 2, clock_str(), C.cyan, C.hdr, 2);
    }

    // Подзаголовок в три знакоместа шириной: "Перезапуск модема..." не влезал
    // в 320 пикселей и уезжал за край. Переносим по словам.
    {
        let sz = 3, cw2 = 6 * sz;
        let words = split(subtitle ?? "", " ");
        let lines = [], cur = "";
        for (let w in words) {
            let t = cur == "" ? w : cur + " " + w;
            if (twpx(t, sz) > LCD_W - 40 && cur != "") { push(lines, cur); cur = w; }
            else cur = t;
        }
        if (cur != "") push(lines, cur);
        let lstep = IS_ALMONDPLUS ? fpx(sz) + 8 : 26;
        let y0 = IS_ALMONDPLUS ? int((LCD_H - fpx(sz)) / 2) - int((length(lines) - 1) * lstep / 2)
                               : 90 - (length(lines) - 1) * 13;
        for (let i = 0; i < length(lines); i++)
            lcd_text(int((LCD_W - twpx(lines[i], sz)) / 2), y0 + i * lstep, lines[i], color, C.bg, sz);
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
    lcd_rect(0, BACK_Y, LCD_W, BACK_H, C.press);
    if (label != null)
        lcd_text(int((LCD_W - twpx(label, 2)) / 2), bar_y(14), label, C.white, C.press, 2);
    else
        draw_back_arrow(int(LCD_W / 2), bar_y(14), C.press);
    lcd_flush();
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
// Без паузы: вдавленный кадр висит, пока рисуется целевая страница.
function menu_press_fx(act) {
    menu_pressed = act;
    draw_menu();
    menu_pressed = null;
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
    lcd_text(int((LCD_W - twpx(tt, 3)) / 2), wy + 12, tt, C.white, C.back, 3);
    let bl = [ tr("Restart"), tr("Shut down"), tr("Cancel") ];
    for (let i = 0; i < 3; i++) {
        let by = wy + 44 + i * 40;
        lcd_rect(40, by, 240, 34, C.btn);
        lcd_rect(40, by + 31, 240, 3, C.border);
        lcd_text(40 + int((240 - twpx(bl[i], 2)) / 2), by + 9, bl[i], C.white, C.btn, 2);
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
    // Фоново, без заглушки: uci уже сменён, кнопка сразу показывает новое
    // состояние. Перезагружаем ТОЛЬКО затронутое радио (короче окно), а не
    // всю беспроводку. Плюс ставим кулдаун: пока идёт reload, netifd занят и
    // ubus-вызовы в refresh_data блокировали бы весь UI (нельзя было нажать
    // второй тумблер или выйти) - на это время refresh их пропускает.
    st.wifi_cd = time();
    system(sprintf("wifi reload %s >/dev/null 2>&1 &", sh_quote(radio)));
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
        in_rect(tx, ty, GX, SCAN_BTN_Y, GW, SCAN_BTN_H)) {
        sta.band = tx < int(LCD_W / 2) ? 2 : 5;
        sta.nets = null;
        sta.pg = 0;          // новый скан - снова с первой страницы
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

    if (st.page == "zigbee" && ty < BACK_Y) {
        if (zig_ui_mode() == "peers") {
            let rows = zig_rows();
            let ay = GY + ZIG_HDR_H + GG;
            if (length(rows) > 0) {
                let more = length(rows) > ZIG_ROWS;
                let show = more ? ZIG_ROWS - 1 : length(rows);
                let off = (st.zig.poff ?? 0) % length(rows);
                for (let k = 0; k < show; k++) {
                    let y = ay + 6 + k * ZIG_ROW_STEP;
                    if (ty < y - 5 || ty >= y + ZIG_ROW_STEP - 5) continue;
                    let n = rows[(off + k) % length(rows)];
                    if (n.pi < 0) return;
                    st.zig.peer = n.pi;
                    go_page("zigpeer");
                    return;
                }
                let fy = ay + 6 + show * ZIG_ROW_STEP;
                if (more && ty >= fy - 5 && ty < fy + ZIG_ROW_STEP - 5) {
                    st.zig.poff = (off + show) % length(rows);
                    draw_zigbee_page();
                    return;
                }
            }
        }
        for (let i = 0; i < 3; i++) {
            let b = zig_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            if (i == 2) {
                system(sprintf("%s state > /tmp/lcd_zig_state.json 2>/dev/null &", ZIG_BIN));
                st.zig.form_msg = null;
                go_page("zigset");
                return;
            }
            if (i == 1) { st.zig.mode = "peers"; draw_zigbee_page(); return; }
            st.zig.mode = "escan";
            // Скан держит порт, поэтому маячок на время глушим и поднимаем после.
            zig_beacon_stop();
            zig_run("escan", ZIG_ESCAN, "3");
            st.zig.restart = true;
            draw_zigbee_page();
            return;
        }
        return;
    }

    if (st.page == "zignets" && ty < BACK_Y) {
        let nets = zignet_list();
        for (let i = 0; i < length(nets) && i < 5; i++) {
            let b = zignet_row(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            let n = nets[i];
            let c2 = zig_cfg();
            st.zig ??= {};
            st.zig.form_msg = tr("looking for a network");
            st.zig.msg_ts = time();
            zig_cmd_bg(sprintf("%s/zig_join.sh %s %d %d", SCRIPTS, c2.key,
                               int(+(n.pan ?? 0)), int(+(n.ch ?? 0))));
            go_back();
            return;
        }
        return;
    }

    if (st.page == "zigset" && ty < BACK_Y) {
        // Читаем конфиг с диска: его правит и цепочка команд из шелла, а свой
        // курсор держит значения в памяти - кнопка «Поднять» могла уйти со
        // старым PAN.
        if (ucur) ucur.load("almond3s");
        let c = zig_cfg();
        let r0 = zigset_row(0), m0 = zigset_pm(0, false);
        if (in_rect(tx, ty, r0.x, r0.y, m0.x - r0.x, r0.h)) {
            st.kbmode = "zigpan";
            st.zigpanbuf = sprintf("%04X", c.pan);
            st.citykb = { pg: "symA", caps: true };
            go_page("kbd");
            return;
        }
        for (let i = 0; i < 3; i++) {
            let m = zigset_pm(i, false), pl = zigset_pm(i, true);
            let hit = in_rect(tx, ty, m.x, m.y, m.w, m.h) ? -1 :
                      (in_rect(tx, ty, pl.x, pl.y, pl.w, pl.h) ? 1 : 0);
            if (hit == 0) continue;
            st.zig ??= {};
            st.zig.edit = time();
            let step = function() {
                st.zig.edit = time();
                let cc = zig_cfg();
                if (i == 0) zig_set("pan", clampi(cc.pan + hit, 1, 65534));
                if (i == 1) zig_set("channel", clampi(cc.ch + hit, 11, 26));
                if (i == 2) {
                    let idx = 0;
                    for (let k = 0; k < length(ZIG_POWERS); k++)
                        if (ZIG_POWERS[k] == cc.power) idx = k;
                    idx = clampi(idx + hit, 0, length(ZIG_POWERS) - 1);
                    zig_set("power", ZIG_POWERS[idx]);
                }
                draw_zigset_page();
            };
            step();
            hold_repeat(hit < 0 ? m : pl, step);
            return;
        }
        {
            let bb = zigset_row(3);
            if (in_rect(tx, ty, bb.x, bb.y, bb.w, bb.h)) {
                let mesh = zig_mode() == "mesh";
                // Включение ведёт сразу в «сеть»: это основной режим, и после
                // «выкл» человек ждёт назад свою сеть, а не одиночный маячок.
                if (!c.beacon) {
                    zig_set("beacon", 1);
                    zig_set("mode", "mesh");
                } else if (mesh) {
                    zig_set("mode", "beacon");
                } else {
                    zig_set("beacon", 0);
                }
                zig_beacon_stop();
                zig_beacon_start();
                draw_zigset_page();
                return;
            }
        }
        for (let i = 0; i < 4; i++) {
            let b = zigset_act(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            st.zig ??= {};
            if (i == 3) {
                let mq = mqtt_cfg();
                zig_btn_fx(b, mq.on ? "MQTT+" : "MQTT", mq.on ? C.green : C.gray);
                go_page("mqtt");
                return;
            }
            if (i == 2) {
                zig_btn_fx(b, tr("Flash short"), C.cyan);
                let fw = zig_fw_file();
                if (fw == null) {
                    toast(tr("no firmware in image"), C.orange, "#2A1A06", 2);
                    return;
                }
                let g = confirm_geo({ x: 20, y: 40, w: 280, h: 150, x1: 40, x2: 170,
                                      by: 135, bw: 110, bh: 40 });
                lcd_clear("#1A1000");
                lcd_rect(g.x, g.y, g.w, g.h, "#2A1A06");
                lcd_rect(g.x, g.y, g.w, 2, C.orange);
                if (IS_ALMONDPLUS) {
                    lcd_text(g.tx, g.ty, tr("Update Zigbee chip?"), C.orange, "#2A1A06", 2);
                    lcd_text(g.tx, g.ty + 36, tr("Takes about a minute."), C.gray, "#2A1A06", 1);
                    lcd_text(g.tx, g.ty + 52, tr("Factory version cannot be restored."), C.gray, "#2A1A06", 1);
                    lcd_text(g.tx, g.ty + 68, tr("Do not power off."), C.gray, "#2A1A06", 1);
                    confirm_btn_text(g.yes, tr("YES"), C.white, C.orange);
                    confirm_btn_text(g.no, tr("NO"), C.white, C.graph);
                } else {
                    lcd_text(34, 54, tr("Update Zigbee chip?"), C.orange, "#2A1A06", 2);
                    lcd_text(34, 80, tr("Takes about a minute."), C.gray, "#2A1A06", 1);
                    lcd_text(34, 94, tr("Factory version cannot be restored."), C.gray, "#2A1A06", 1);
                    lcd_text(34, 108, tr("Do not power off."), C.gray, "#2A1A06", 1);
                    lcd_rect(40, 135, 110, 40, C.orange);
                    lcd_text(72, 148, tr("YES"), C.white, C.orange, 2);
                    lcd_rect(170, 135, 110, 40, C.graph);
                    lcd_text(202, 148, tr("NO"), C.white, C.graph, 2);
                }
                lcd_flush();
                // Ждём НОВОЕ нажатие (см. modal_touch) и проверяем попадание
                // ровно в кнопку ДА, а не в грубую полуплоскость.
                let ct = modal_touch(15);
                if (!ct || !in_rect(ct.x, ct.y, g.yes.x, g.yes.y, g.yes.w, g.yes.h)) {
                    draw_zigset_page();
                    return;
                }
                zig_beacon_stop();
                st.zig.flashing = time();
                st.zig.flash_done = null;
                fs.unlink(ZIG_FLASH_LOG);
                fs.unlink(ZIG_PEERS);
                fs.unlink(ZIG_INFO);
                system(sprintf("(%s flash %s 1 > /tmp/lcd_zig_flash.json 2>%s; %s info > %s 2>/dev/null) </dev/null &",
                               ZIG_BIN, fw, ZIG_FLASH_LOG, ZIG_BIN, ZIG_INFO));
                draw_zigset_page();
                return;
            }
            if (i == 0) {
                let stt3 = zig_json("/tmp/lcd_zig_state.json");
                // Настройки разошлись с эфиром - значит человек поменял PAN
                // или канал и ждёт, что сеть поднимется заново, а не что
                // откроется приём. Роль - из живых данных, как на отрисовке:
                // иначе кнопка и палец видели разное состояние.
                let ln3 = zig_live_node();
                let co3 = ln3 != null ? ln3 == 1
                        : (stt3?.state == 2 && int(+(stt3?.node ?? 0)) == 1);
                let lvp = zig_live_pan() ?? 0, lvc = zig_live_ch() ?? 0;
                let diff = lvp > 0 && (lvp != c.pan || (lvc > 0 && lvc != c.ch));
                if (!diff && co3) {
                    // Кнопка-переключатель: открыт - закрываем, закрыт -
                    // открываем на четыре минуты. Окно держит демон, он же
                    // продлевает и закрывает его по этому файлу.
                    if (zig_permit_left() > 0) {
                        zig_btn_fx(b, tr("Permit short"), C.gray);
                        zig_permit_close();
                        toast(tr("joining closed"), C.gray, "#101820", 2);
                    } else {
                        zig_btn_fx(b, tr("Permit short"), C.orange);
                        zig_permit_open(240);
                        toast(tr("pairing window open"), C.orange, "#2A1A06", 2);
                    }
                    draw_zigset_page();
                    return;
                }
                zig_btn_fx(b, tr("Form short"), C.green);
                // Свежая сеть пуста, и первым делом в неё надо кого-то
                // впустить: открываем приём сразу, не заставляя человека
                // искать отдельную кнопку.
                zig_permit_open(240);
                st.zig.act_msg = tr("network up, joining open");
                // Сперва «выйти»: чип, оставшийся в старой сети, отвечает на
                // form ошибкой 112 (недопустимый вызов) и молча остаётся где
                // был - именно поэтому «Поднять» ничего не делала. На
                // свободном чипе leave безвреден.
                zig_cmd_bg(sprintf("%s leave >/dev/null 2>&1; %s form %d %d %d %s",
                                   ZIG_BIN, ZIG_BIN, c.pan, c.ch, c.power, c.key));
            }
            else {
                let stt2 = zig_json("/tmp/lcd_zig_state.json");
                let ln2 = zig_live_node();
                let in2 = ln2 != null ? ln2 > 0 : stt2?.state == 2;
                zig_btn_fx(b, in2 ? tr("Leave short") : tr("Join short"),
                           in2 ? C.red : A_PURPLE);
                if (in2) {
                    st.zig.act_msg = tr("leaving network");
                    zig_cmd_bg(sprintf("%s leave", ZIG_BIN));
                } else {
                    // Вслепую не вступаем: сканируем эфир и показываем, что
                    // слышно, - выбирает человек. Так это и устроено в
                    // стандарте: вступают в сеть, которая слышна и открыта.
                    fs.unlink(ZIG_JOIN);
                    zig_beacon_stop();
                    zig_run("ascan", ZIG_ASCAN, "5");
                    st.zig.restart = true;
                    go_page("zignets");
                    return;
                }
            }
            // Сообщение по действию: «поднимаю» у координатора, «выхожу» при
            // выходе. Раньше на любую кнопку писалось «ищу сеть в эфире» -
            // при поднятии своей сети это просто неправда.
            st.zig.form_msg = st.zig.act_msg ?? tr("looking for a network");
            st.zig.act_msg = null;
            st.zig.msg_ts = time();
            draw_zigset_page();
            return;
        }
        return;
    }

    // У сервисов внизу две кнопки, поэтому общее правило «низ - назад» для
    // этой страницы не годится: левая половина запускает проверку.
    // Порог по видимой полосе, без 6px запаса выше: 3-й ряд карточек
    // (5-6 хостов) кончается на 168, а SVC_BAR_Y-6=166 съедал их низ.
    if (st.page == "services" && ty >= SVC_BAR_Y && ty < BACK_Y) {
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
            let ex = 50 + (rat == "" || rat == "-" ? 0 : twpx(rat, 2) + 8);
            if (ex + ENV_W + 8 > t_x) ex = t_x - ENV_W - 8;
            if (in_rect(tx, ty, ex - 4, 0, ENV_W + 8, HDR_H)) {
                st.sms_pg = 0;
                st.sms_i = -1;
                sms_refresh();
                go_page("sms");
                return;
            }
        }
        let hb_x = IS_ALMONDPLUS ? LCD_W - 85 : 235;
        let hc0 = IS_ALMONDPLUS ? int(LCD_W / 2) - 60 : 120, hc1 = IS_ALMONDPLUS ? int(LCD_W / 2) + 60 : 200;
        if (tx >= hb_x && st.page != "battery" && HAS_BATTERY) {
            go_page("battery");
            return;
        }
        if (tx >= hc0 && tx < hc1 && st.page != "saver") {
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
        let hit = pager_hit(tx, ty, pages);
        if (hit == PAGER_BACK) { back_press_fx(); go_back(); return; }
        if (hit != PAGER_NONE) {
            st.wcli_pg = ((st.wcli_pg ?? 0) + pages + hit) % pages;
            draw_wifi_clients_page();
        }
        return;
    }

    // Back button (all sub-pages except menu). Страницы со своей листалкой сюда
    // не попадают: у них нижняя полоса поделена на стрелки и «назад», а общее
    // правило «низ - это назад» съедало нажатия по стрелкам целиком.
    // Порог ровно по видимой полосе «Назад» (BACK_Y=208, бар 32px), без
    // прежних 10px запаса выше неё: этот запас (198..208) съедал нижние
    if (st.page == "mqtt" && ty < BACK_Y) {
        let c = mqtt_cfg();
        for (let i = 0; i < length(MQTT_FIELDS); i++) {
            let r = mqtt_row(i);
            if (!in_rect(tx, ty, r.x, r.y, r.w, r.h)) continue;
            let f = MQTT_FIELDS[i];
            st.kbmode = "mqtt";
            st.kbfield = f.key;
            st.mqttbuf = c[f.key] ?? "";
            st.citykb = { pg: (f.key == "port" || f.key == "period") ? "symA" : "abc",
                          caps: false };
            go_page("kbd");
            return;
        }
        let cb = mqtt_ctl_btn();
        if (in_rect(tx, ty, cb.x, cb.y, cb.w, cb.h)) {
            let ix = 0;
            for (let i = 0; i < length(MQTT_CTL); i++)
                if (MQTT_CTL[i] == c.control) ix = i;
            mqtt_set("control", MQTT_CTL[(ix + 1) % length(MQTT_CTL)]);
            if (c.on) system("/etc/init.d/almond3s-mqtt restart");
            draw_mqtt_page();
            return;
        }
        let rb2 = mqtt_retain_btn();
        if (in_rect(tx, ty, rb2.x, rb2.y, rb2.w, rb2.h)) {
            mqtt_set("retain", c.retain ? "0" : "1");
            if (c.on) system("/etc/init.d/almond3s-mqtt restart");
            draw_mqtt_page();
            return;
        }
        let b = mqtt_toggle_btn();
        if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
            if (c.host == "") {
                toast(tr("set broker address first"), C.orange, "#2A1A06", 2);
                return;
            }
            mqtt_set("enabled", c.on ? "0" : "1");
            system(c.on ? "/etc/init.d/almond3s-mqtt stop; /etc/init.d/almond3s-mqtt disable"
                        : "/etc/init.d/almond3s-mqtt enable; /etc/init.d/almond3s-mqtt restart");
            toast(c.on ? tr("MQTT off") : sprintf("%s %s", tr("MQTT on"), c.host),
                  c.on ? C.gray : C.green, "#06202a", 2);
            draw_mqtt_page();
            return;
        }
        return;
    }

    // Тап по карточке VPN на странице соседа переключает его VPN. Раньше это
    // была отдельная кнопка внизу; карточка и так показывает состояние, так
    // что нажимать логично прямо по ней.
    if (st.page == "zigpeer" && ty < BACK_Y) {
        let vb = zp_box(2, 0, 1);
        if (in_rect(tx, ty, vb.x, vb.y, vb.w, vb.h)) {
            let d = zig_json(ZIG_PEERS);
            let peers = type(d?.peers) == "array" ? d.peers : [];
            let pr = peers[st.zig?.peer ?? 0];
            let pname = pr?.name ?? "";
            if (pname == "") return;
            let von = int(+(pr?.m?.vpn ?? 0)) == 1;
            let act = von ? "vpn_off" : "vpn_on";
            system(sprintf("echo %s %s > /tmp/.zig_cmd", sh_quote(pname), sh_quote(act)));
            toast(tcut(pname, 12) + ": " + (von ? tr("VPN off") : tr("VPN on")),
                  C.white, "#06202a", 1);
            draw_zigpeer_page();
            return;
        }
        return;
    }

    if (st.page == "zigpeer" && ty >= BACK_Y) {
        let d = zig_json(ZIG_PEERS);
        let peers = type(d?.peers) == "array" ? d.peers : [];
        let pr = peers[st.zig?.peer ?? 0];
        let pname = pr?.name ?? "";
        let cell = -1;
        for (let i = 0; i < 3; i += 2) {
            let a = zp_act(i);
            if (in_rect(tx, ty, a.x, a.y, a.w, a.h)) cell = i;
        }
        if (cell < 0 || pname == "") { back_press_fx(); go_back(); return; }
        let act = cell == 0 ? "modem" : "reboot";
        let lab = cell == 0 ? tr("Reboot modem") : tr("Reboot router");
        system(sprintf("echo %s %s > /tmp/.zig_cmd", sh_quote(pname), sh_quote(act)));
        toast(tcut(pname, 12) + ": " + lab, C.white, "#06202a", 1);
        draw_zigpeer_page();
        return;
    }

    // пиксели кнопок всех страниц со своим нижним рядом - стрелки листания
    // «Соты»/«Города», размер часов, ШИМ, ночная яркость, 6-я строка сетей.
    // Страницы из этого списка разбирают нижнюю полосу САМИ - у них там своя
    // листалка или свои кнопки. Правило для них одно: разбор полосы стоит
    // ПЕРВЫМ в их ветке, до любых проверок и досрочных выходов. Иначе тап по
    // «назад» проваливается в никуда и со страницы не выйти - так уже было на
    // VPN с незапущенной службой и на скане, пока сети ещё ищутся.
    if (st.page != "menu" && st.page != "sms" && st.page != "sms1" &&
        st.page != "kbd" && st.page != "term" &&
        st.page != "cell" && st.page != "games" && st.page != "vpn" &&
        st.page != "stascan" && st.page != "dcust" &&
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
        if (ty >= BACK_Y) {
            let hit = pager_hit(tx, ty, pages);
            if (hit == PAGER_BACK) { back_press_fx(); go_page("menu"); return; }
            if (hit != PAGER_NONE) {
                st.sms_pg = (st.sms_pg + pages + hit) % pages;
                draw_sms_page();
            }
            return;
        }
        for (let r = 0; r < SMS_ROWS; r++) {
            let idx = st.sms_pg * SMS_ROWS + r;
            if (idx >= n) break;
            let sb = sms_row(r), y = sb.y;
            let mr = IS_ALMONDPLUS ? GX + GW : 310;
            // Красный минус справа - удалить сообщение СРАЗУ (без попапа).
            if (in_rect(tx, ty, mr - NP_MINUS_W, y, NP_MINUS_W, sb.h)) {
                sms_delete(list[idx]);
                // Мгновенно убираем из списка - фоновый recv потом подтвердит.
                let nl = [];
                for (let k = 0; k < length(st.sms ?? []); k++)
                    if (k != idx) push(nl, st.sms[k]);
                st.sms = nl;
                draw_sms_page();
                return;
            }
            if (in_rect(tx, ty, sb.x, y, sb.w - NP_MINUS_W, sb.h)) {
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
        if (ty >= BACK_Y) {
            let hit = pager_hit(tx, ty, pages);
            if (hit == PAGER_BACK) { back_press_fx(); go_page("sms"); return; }
            if (hit != PAGER_NONE) {
                st.sms_tp = (st.sms_tp + pages + hit) % pages;
                draw_sms_one();
            }
        }
        return;
    }

    if (st.page == "menu") {
        let items = menu_items();
        let pages = menu_pages();
        // Листание переехало в общую полосу навигации: слева - страница назад,
        // справа - вперёд, по кругу. Плитка-пейджер больше не нужна, и её место
        // занял шестой пункт меню.
        if (ty >= BACK_Y) {
            let dot = pager_dot_hit(tx, ty, pages);
            if (dot >= 0) {
                if (dot != st.mpg - 1) { st.mpg = dot + 1; draw_menu(); }
                return;
            }
            let hit = pager_hit(tx, ty, pages);
            if (hit == PAGER_PREV || hit == PAGER_NEXT) {
                st.mpg = ((st.mpg - 1) + pages + hit) % pages + 1;
                draw_menu();
            }
            return;
        }
        let page = MENU_LAYOUT[(st.mpg ?? 1) - 1];
        for (let i = 0; i < length(page); i++) {
            let t = page[i];
            let b = menu_cell(t);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            let m = menu_by_act(items, t.act);
            if (m == null) { draw_menu(); return; }
            menu_press_fx(t.act);
            switch (t.act) {
            case "dashboard": netpri_refresh(); go_page("dashboard"); return;
            case "wifi":      go_page("wifi"); return;
            case "lte":       go_page("lte"); return;
            case "vpn":       st.vpn_exp = null; st.vpn_gpg = 0; st.vpn_ping = null; st.vpn_gwait = 0; vpn_refresh(true); go_page("vpn"); return;
            case "services":  go_page("services"); return;
            case "speedtest": speedtest_read(); spd_run_watch(); spd_hist_load();
                st.spd_poll = int(+(st.spd?.running ?? 0)) > 0; go_page("speedtest"); return;
            case "traffic":   go_page("traffic"); return;
            case "sms":       st.sms_pg = 0; st.sms_i = -1; sms_refresh(); go_page("sms"); return;
            case "settings":  go_page("settings"); return;
            case "display":   go_page("display"); return;
            case "saver":     go_page("saver"); return;
            case "weather":   run_script("weather_fetch.sh", true); go_page("weather"); return;
            case "alarm":     alarm_load(); go_page("alarm"); return;
            case "battery":   go_page("battery"); return;
            case "iconedit":  ed_armed = false; go_page("iconedit"); return;
            case "term":      term_start(); go_page("term"); return;
            case "zigbee":
                if (!fs.stat(ZIG_INFO)) zig_run("info", ZIG_INFO);
                go_page("zigbee");
                return;
            case "zwave":     zw_probe(true); go_page("zwave"); return;
            case "games":     go_page("games"); return;
            case "info":      go_page("info"); return;
            case "power":     go_page("power"); return;
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
        let sx = GX + st.ox, sy = GVT + st.oy + gcard_h(3) + GG;
        if (in_rect(tx, ty, sx, sy, GW, gcard_h(3))) {
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
                astripe(b.x, b.y, b.h, C.yellow);
                if (IS_ALMONDPLUS) lcd_rect(b.x + b.w - 22, b.y + 12, 12, 12, C.yellow);
                else lcd_rect(b.x + b.w - 14, b.y + 8, 8, 8, C.yellow);
                lcd_flush();
                system("/etc/almond3s/scripts/svcping.sh " + sh_quote(hosts[i]) + " >/dev/null 2>&1");
                refresh_data();
                draw_services_page();
                return;
            }
        }

        return;
    }

    if (st.page == "cell" && ty >= BACK_Y) {
        let h = pager_hit(tx, ty, CELL_PAGES);
        if (h == PAGER_BACK) { back_press_fx(); go_back(); return; }
        if (h != PAGER_NONE) {
            st.cpage = (st.cpage + CELL_PAGES + h) % CELL_PAGES;
            draw_cell_page();
        }
        return;
    }

    if (st.page == "vpn") {
        let v = st.vpn ?? {};
        let groups = type(v.groups) == "array" ? v.groups : [];

        // Полосу разбираем ПЕРВОЙ и без всяких условий. Раньше её обработка
        // сидела внутри веток «пакет стоит», «служба запущена» и «группы
        // есть» - и стоило одному условию не сойтись, как «назад» переставала
        // работать вовсе, а страница ловила палец в ловушку.
        if (ty >= BACK_Y) {
            let pages = 1, cur = 0;
            if (st.vpn_exp != null && st.vpn_exp < length(groups)) {
                let n = length(vpn_items(groups[st.vpn_exp]));
                pages = int((n + VPN_MPP - 1) / VPN_MPP); if (pages < 1) pages = 1;
                cur = st.vpn_mpg ?? 0;
            } else if (length(groups) > 0) {
                pages = int((length(groups) + VPN_GPP - 1) / VPN_GPP); if (pages < 1) pages = 1;
                cur = st.vpn_gpg ?? 0;
            }
            let h = pager_hit(tx, ty, pages);
            if (h == PAGER_BACK) {
                back_press_fx();
                // Из раскрытой группы «назад» ведёт к списку групп, а не в меню.
                if (st.vpn_exp != null) { st.vpn_exp = null; draw_vpn_page(); }
                else go_back();
                return;
            }
            if (h != PAGER_NONE) {
                if (st.vpn_exp != null) st.vpn_mpg = (cur + pages + h) % pages;
                else st.vpn_gpg = (cur + pages + h) % pages;
                draw_vpn_page();
            }
            return;
        }
        if (int(+(v.installed ?? 1)) == 0) return;   // не установлен - тапать нечего

        // Раскрытая группа: выбор сервера + листалка.
        if (st.vpn_exp != null && st.vpn_exp < length(groups)) {
            let g = groups[st.vpn_exp];
            let items = vpn_items(g);
            let n = length(items);
            let pages = int((n + VPN_MPP - 1) / VPN_MPP); if (pages < 1) pages = 1;
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
        let WR = stack_rects([ 84, 32, 44 ]);
        if (in_rect(tx, ty, GX + st.ox, WR[0].y + st.oy, GW, WR[0].h + GG + WR[1].h)) {
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
                if ((l[i].type ?? "") == "wifi" && tx >= b.x + b.w - NP_MINUS_W) {
                    let g = confirm_geo({ x: 30, y: 60, w: 260, h: 120, x1: 50, x2: 170,
                                          by: 125, bw: 100, bh: 35 });
                    lcd_clear("#200000");
                    lcd_rect(g.x, g.y, g.w, g.h, "#300000");
                    lcd_rect(g.x, g.y, g.w, 1, C.red);
                    lcd_text(g.tx, g.ty, tr("Forget network?"), C.red, "#300000", 2);
                    lcd_text(g.tx, g.ty + g.lh, tcut(l[i].label ?? "", 20), C.white, "#300000", 2);
                    if (IS_ALMONDPLUS) {
                        confirm_btn_text(g.yes, tr("YES"), C.white, C.red);
                        confirm_btn_text(g.no, tr("NO"), C.white, C.graph);
                    } else {
                        lcd_rect(50, 125, 100, 35, C.red);
                        lcd_text(72, 133, tr("YES"), C.white, C.red, 2);
                        lcd_rect(170, 125, 100, 35, C.graph);
                        lcd_text(196, 133, tr("NO"), C.white, C.graph, 2);
                    }
                    lcd_flush();
                    // Ждём НОВОЕ нажатие (см. modal_touch) и проверяем попадание
                    // ровно в кнопку ДА.
                    let ct = modal_touch(12);
                    if (ct && in_rect(ct.x, ct.y, g.yes.x, g.yes.y, g.yes.w, g.yes.h)) {
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
        // Полоса разбирается ПЕРВОЙ, до проверки результатов скана: пока сети
        // ищутся, список пуст, и выход раньше времени оставлял палец в
        // ловушке - «назад» не работала всю минуту поиска.
        if (ty >= BACK_Y) {
            let pages = (type(nets) == "array") ? stascan_pages(nets) : 1;
            let h = pager_hit(tx, ty, pages);
            if (h == PAGER_BACK) { back_press_fx(); go_back(); return; }
            if (h != PAGER_NONE && type(nets) == "array") {
                sta.pg = (stascan_page(nets) + pages + h) % pages;
                draw_stascan_page();
            }
            return;
        }
        if (type(nets) != "array") return;
        {
            let hb = stascan_hidden_row();
            if (in_rect(tx, ty, hb.x, hb.y, hb.w, hb.h)) {
                sta.sel = -1;              // отметка «сеть названа руками»
                sta.hssid = "";
                st.kbmode = "hssid";
                sta.kb = { pg: "abc", caps: false };
                go_page("kbd");
                return;
            }
        }
        let off = stascan_page(nets) * STASCAN_MAX;
        for (let k = 0; k < STASCAN_MAX && off + k < length(nets); k++) {
            let b = stascan_row(k);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            let i = off + k;
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
        if (ty >= BACK_Y) {
            if (st.kbmode == "city" || st.kbmode == "mqtt" || st.kbmode == "hssid" ||
                st.kbmode == "zigpan")
                st.kbmode = "sta";
            go_back();
            return;
        }
        let e = kb_key_at(tx, ty);
        if (!e) return;
        // Режим города: свой буфер/клавиатура, ↵ = применить город (геокод в фетче).
        if (st.kbmode == "city") {
            kb_press_show(e, st.citykb, KB_Y0);
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
        if (st.kbmode == "ssid") {
            kb_press_show(e, st.citykb, KB_Y0);
            let a = kb_apply(e, st.citykb);
            if (a.t == "char") st.ssidbuf = (st.ssidbuf ?? "") + a.ch;
            else if (a.t == "del") st.ssidbuf = substr(st.ssidbuf ?? "", 0, length(st.ssidbuf ?? "") - 1);
            else if (a.t == "space") st.ssidbuf = (st.ssidbuf ?? "") + " ";
            else if (a.t == "enter") {
                let name = trim(st.ssidbuf ?? "");
                let sec = st.ssidsec;
                st.kbmode = "sta";
                if (name != "" && sec != null && ucur) {
                    ucur.set("wireless", sec, "ssid", name);
                    ucur.commit("wireless");
                    // Перезапуск радио рвёт подключённых - предупреждаем тостом,
                    // чтобы это не выглядело сбоем.
                    toast(tr("Clients will reconnect"), C.orange, "#201406", 2);
                    system("wifi reload >/dev/null 2>&1 &");
                }
                go_page("wifi");
                return;
            }
            draw_kbd_page();
            return;
        }
        if (st.kbmode == "zigpan") {
            kb_press_show(e, st.citykb, KB_Y0);
            let a = kb_apply(e, st.citykb);
            let buf = st.zigpanbuf ?? "";
            if (a.t == "char") {
                let ch = uc(a.ch);
                if (length(buf) < 4 && index("0123456789ABCDEF", ch) >= 0)
                    buf += ch;
            } else if (a.t == "del") {
                buf = substr(buf, 0, length(buf) - 1);
            } else if (a.t == "enter") {
                let n = hex(buf);
                st.kbmode = "sta";
                if (n != null && n >= 1 && n <= 65534) {
                    st.zig ??= {};
                    st.zig.edit = time();
                    zig_set("pan", n);
                }
                go_page("zigset");
                return;
            }
            st.zigpanbuf = buf;
            draw_kbd_page();
            return;
        }
        if (st.kbmode == "mqtt") {
            kb_press_show(e, st.citykb, KB_Y0);
            let a = kb_apply(e, st.citykb);
            if (a.t == "char") st.mqttbuf = (st.mqttbuf ?? "") + a.ch;
            else if (a.t == "del") st.mqttbuf = substr(st.mqttbuf ?? "", 0, length(st.mqttbuf ?? "") - 1);
            else if (a.t == "space") st.mqttbuf = (st.mqttbuf ?? "") + " ";
            else if (a.t == "enter") {
                let val = trim(st.mqttbuf ?? "");
                let fk = st.kbfield ?? "host";
                st.kbmode = "sta";
                mqtt_set(fk, val);
                if (mqtt_cfg().on)
                    system("/etc/init.d/almond3s-mqtt restart");
                go_page("mqtt");
                return;
            }
            draw_kbd_page();
            return;
        }
        if (st.kbmode == "hssid") {
            kb_press_show(e, sta.kb, KB_Y0);
            let a2 = kb_apply(e, sta.kb);
            if (a2.t == "char") sta.hssid = (sta.hssid ?? "") + a2.ch;
            else if (a2.t == "del")
                sta.hssid = substr(sta.hssid ?? "", 0, length(sta.hssid ?? "") - 1);
            else if (a2.t == "space") sta.hssid = (sta.hssid ?? "") + " ";
            else if (a2.t == "enter") {
                let nm = trim(sta.hssid ?? "");
                if (nm == "") { draw_kbd_page(); return; }
                sta.hssid = nm;
                // Имя названо - дальше обычный ввод пароля. Открытую скрытую
                // сеть тоже надо уметь: пустой пароль на ↵ даст encryption=none.
                sta.pass = ""; sta.kb = { pg: "abc", caps: false };
                st.kbmode = "sta";
                draw_kbd_page();
                return;
            }
            draw_kbd_page();
            return;
        }
        kb_press_show(e, sta.kb, KB_Y0);   // вдавить клавишу
        let a = kb_apply(e, sta.kb);
        if (a.t == "char") sta.pass += a.ch;
        else if (a.t == "del") sta.pass = substr(sta.pass, 0, length(sta.pass) - 1);
        else if (a.t == "space") sta.pass += " ";
        else if (a.t == "enter") {
            // sel < 0 - имя названо руками (скрытая сеть), в списке скана его нет.
            let n = sta.sel >= 0 ? sta.nets[sta.sel]
                                 : { ssid: sta.hssid ?? "", band: sta.band };
            if (n.ssid == "") { go_back(); return; }
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
            if (tx >= LCD_W - 42) { t.kbd = !t.kbd; t.scroll = 0; st.term_rows_sent = -1; draw_term_page(); return; }
            back_press_fx(tr("Exit"));
            term_stop();
            st.page = "menu"; st.mpg = 4; draw_menu();
            return;
        }
        // Область вывода (весь экран без клавы, либо над клавой при ty<92)
        // листается перетаскиванием. Тянем вниз (dy>0) - назад в историю.
        let out_area = !t.kbd || ty < KB_Y0;
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
                if (!IS_ALMONDPLUS) b.y = yb;
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
        if (led_rgb()) {
            let b2 = led_row(2);
            if (in_rect(tx, ty, b2.x, b2.y, b2.w, b2.h)) {
                led_set("color", led_color_next(c.color));
                if (led_blinking) led_write("blink");
                else led_apply();
                draw_led_page();
                return;
            }
        }
        return;
    }

    if (st.page == "info") {
        if (st.izoom != null) { st.izoom = null; draw_info_page(); return; }
        let oy = st.oy, ich = gcard_h(3);
        for (let i = 0; i < 3; i++) {
            let iy = GVT + oy + i * (ich + GG);
            if (ty >= iy && ty < iy + ich) { st.izoom = i; draw_info_page(); return; }
        }
        return;
    }

    if (st.page == "traffic") {
        if (st.tzoom != null) { st.tzoom = null; draw_traffic_page(); return; }
        let tgh = int((GVB - GVT - GG) / 2);
        if (ty >= GY && ty < GY + tgh)  { st.tzoom = 0; draw_traffic_page(); return; }
        if (ty >= GY + tgh + GG && ty < GY + 2 * tgh + GG) { st.tzoom = 1; draw_traffic_page(); return; }
        return;
    }

    if (st.page == "debug") {
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
                let px = ED_X + (i % ED_CP_PER) * ED_CP_STEP;
                let py = ED_Y + 14 + int(i / ED_CP_PER) * ED_CP_ROW;
                if (!in_rect(tx, ty, px, py, ED_CP_SZ, ED_CP_SZ)) continue;
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
            let slots = ed_pick_slots();
            for (let i = 0; i < length(slots); i++) {
                let px = ED_X + (i % ED_PK_PER) * ED_PK_STEP;
                let py = ED_Y + 14 + int(i / ED_PK_PER) * ED_PK_ROW;
                if (!in_rect(tx, ty, px, py, ED_PK_SZ, ED_PK_SZ)) continue;
                if (slots[i].kind == "new") {
                    ed_grid = null;     // ed_init нарисует чистый холст 14x14
                    ed_target = null;   // пустой target -> Save создаст новый art
                } else {
                    ed_load(slots[i].name);
                }
                ed_pick = false;
                ed_armed = false;
                draw_iconedit_page();
                return;
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
            if (ed_target != null && match(ed_target, /^art_[0-9]+$/)) {
                // Повторная правка своего рисунка: пишем обратно в его файл,
                // не плодя новый номер.
                system("mkdir -p /etc/almond3s/art");
                fs.writefile("/etc/almond3s/art/" + ed_target + ".txt", out);
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
        if (in_rect(tx, ty, b1.x, b1.y, ED_CLR_W, b1.h)) {
            ed_grid = null;
            ed_target = null;
            draw_iconedit_page();
            return;
        }
        if (in_rect(tx, ty, ED_PICK_X, b1.y, ED_PICK_W, IS_ALMONDPLUS ? b1.h : 24)) {
            ed_pick = true;
            draw_iconedit_page();
            return;
        }
        if (in_rect(tx, ty, ED_PV_X, ED_PV_Y, IS_ALMONDPLUS ? 46 : 34, IS_ALMONDPLUS ? 28 : 20)) {
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
            let hb = in_rect(tx, ty, m.x, m.y, m.w, m.h) ? m
                   : (in_rect(tx, ty, pl.x, pl.y, pl.w, pl.h) ? pl : null);
            if (hb != null) {
                let d = (hb == m) ? 23 : 1;
                let step = function() {
                    let cc = night_cfg();
                    night_set(key, ((r == 0 ? cc.from : cc.to) + d) % 24);
                    night_refresh();
                    draw_night_page();
                };
                step();
                hold_repeat(hb, step);
                return;
            }
        }
        return;
    }

    if (st.page == "power") {
        let items = power_items();
        for (let i = 0; i < length(items); i++) {
            let b = power_btn(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            let act = items[i].act;
            // Отклик нажатия рисуем сразу: скрипты гасят экран не мгновенно, и
            // без него тап выглядел бы как «не сработало».
            st.pwr_press = i;
            draw_power_page();
            st.pwr_press = null;
            if (act == "modem") {
                // Лестница сброса уходит в фон одним скриптом (~14с). Окно
                // питания сразу закрываем в меню: оставаясь открытым, оно
                // ловило второй тап и запускало сброс дважды.
                run_script("lte_reset.sh", true);
                go_page("menu");
                toast(tr("Resetting modem..."), C.orange, "#201406", 3);
                return;
            }
            if (act == "poweroff") {
                // Выключение при воткнутой зарядке бессмысленно: контроллер
                // поднимет плату обратно, как только погаснет.
                let pb = st.data?.battery;
                if (pb?.charging && !pb?.no_battery) {
                    toast(tr("Unplug charger first"), C.orange, "#201406", 2);
                    draw_power_page();
                    return;
                }
                st.halting = true;
                action_splash(tr("Power off"), tr("Powering off..."), C.red);
                lcd_flush();
                run_script("poweroff.sh");
                return;
            }
            st.halting = true;
            action_splash(tr("Reboot"), tr("Rebooting..."), C.red);
            lcd_flush();
            run_script("reboot.sh");
            return;
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

    if (st.page == "update") {
        // Модалка перехватывает все тапы: только ОК/Отмена. ОК ставит всё
        // доступное; так как в наборе модуль ядра - следом уйдём в ребут.
        if (st.upd_confirm) {
            let g = upd_confirm_geo();
            if (in_rect(tx, ty, g.ok.x, g.ok.y, g.ok.w, g.ok.h)) {
                st.upd_confirm = null;
                for (let p in upd_pkgs())
                    if (upd_avail(upd_read(p.key))) upd_mark(p.key, "install");
                upd_run("install", "all");
                draw_update_page();
                return;
            }
            if (in_rect(tx, ty, g.cancel.x, g.cancel.y, g.cancel.w, g.cancel.h)) {
                st.upd_confirm = null;
                draw_update_page();
            }
            return;
        }
        let pk = upd_pkgs(), n = length(pk), R = upd_rows();
        // Тап по строке пакета - его релиз-ноты.
        for (let i = 0; i < n; i++) {
            let p = pk[i], r = R[i];
            if (!in_rect(tx, ty, r.x, r.y, r.w, r.h)) continue;
            st.notes_src = (p.key == "5g") ? "5g" : "almond";
            st.notes_pg = 0;
            go_page("relnotes");
            return;
        }
        // Проверить.
        let cb = upd_row_btn(R[n], 0);
        if (in_rect(tx, ty, cb.x, cb.y, cb.w, cb.h)) {
            upd_kick_all(true);
            draw_update_page();
            return;
        }
        // Обновить всё доступное. Если среди доступного модуль ядра - сперва
        // предупреждение о перезагрузке.
        let ub = upd_row_btn(R[n], 1);
        if (in_rect(tx, ty, ub.x, ub.y, ub.w, ub.h)) {
            if (!upd_any_avail()) return;
            if (upd_avail(upd_read("kmod"))) { st.upd_confirm = "all"; draw_update_page(); return; }
            for (let p in upd_pkgs())
                if (upd_avail(upd_read(p.key))) upd_mark(p.key, "install");
            upd_run("install", "all");
            draw_update_page();
            return;
        }
        return;
    }

    if (st.page == "relnotes") {
        let raw = relnotes_read(st.notes_src ?? "almond");
        let body = "";
        if (raw != null && trim(raw) != "__ERR__") {
            let nl = index(raw, "\n");
            body = (nl >= 0) ? substr(raw, nl + 1) : "";
        }
        let pages = int((length(sms_wrap(body, SMS_COLS)) + SMS_LINES - 1) / SMS_LINES);
        if (pages < 1) pages = 1;
        if (ty >= BACK_Y) {
            let hit = pager_hit(tx, ty, pages);
            if (hit == PAGER_BACK) { back_press_fx(); go_back(); return; }
            if (hit != PAGER_NONE) {
                st.notes_pg = ((st.notes_pg ?? 0) + pages + hit) % pages;
                draw_relnotes_page();
            }
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
        let glb = glow_btn();
        if (in_rect(tx, ty, glb.x, glb.y, glb.w, glb.h)) {
            GLOW_ON = !GLOW_ON;
            ucur.set("almond3s", "display", "glow", GLOW_ON ? "1" : "0");
            ucur.commit("almond3s");
            draw_display_page();
            return;
        }
        let bsb = bars_btn();
        if (in_rect(tx, ty, bsb.x, bsb.y, bsb.w, bsb.h)) {
            BARS_ON = !BARS_ON;
            ucur.set("almond3s", "display", "bars", BARS_ON ? "1" : "0");
            ucur.commit("almond3s");
            draw_display_page();
            return;
        }
        let cb = radius_btn();
        if (in_rect(tx, ty, cb.x, cb.y, cb.w, cb.h)) {
            RADIUS = (RADIUS + 1) % 5;
            ucur.set("almond3s", "display", "radius", sprintf("%d", RADIUS));
            ucur.commit("almond3s");
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
            FONT_MODE = (FONT_MODE + 1) % length(FONTS);
            ucur.set("almond3s", "display", "font", FONTS[FONT_MODE].key);
            ucur.commit("almond3s");
            draw_display_page();
            return;
        }
        let tb = theme_btn();
        if (in_rect(tx, ty, tb.x, tb.y, tb.w, tb.h)) {
            let nv = (THEME == "dark") ? "light" : "dark";
            theme_apply(nv);
            bg_tint_apply(BG_TINT);   // пары градиента у тем свои
            ucur.set("almond3s", "display", "theme", nv);
            ucur.commit("almond3s");
            draw_display_page();
            return;
        }
        let gb = bg_btn();
        if (in_rect(tx, ty, gb.x, gb.y, gb.w, gb.h)) {
            // Три состояния по кругу: выкл -> светлый -> тёмный.
            if (!GRAD_ON) { GRAD_ON = true; bg_tint_apply("light"); }
            else if (BG_TINT == "light") bg_tint_apply("dark");
            else GRAD_ON = false;
            ontop_apply();
            ucur.set("almond3s", "display", "gradient", GRAD_ON ? "1" : "0");
            ucur.set("almond3s", "display", "bg", BG_TINT);
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

    if (st.page == "dcust") {
        if (ty >= BACK_Y) {
            // На сетке нижняя полоса - пейджер своих страниц; в пикере
            // стрелок нет, любой тап по низу возвращает к сетке.
            if (st.dcp == null) {
                let npg = dc_edit_pages();
                let h = pager_hit(tx, ty, npg);
                if (h == PAGER_PREV || h == PAGER_NEXT) {
                    st.dc_pg = ((st.dc_pg ?? 0) + npg + h) % npg;
                    draw_dcust_page();
                    return;
                }
                back_press_fx();
                go_back();
                return;
            }
            back_press_fx();
            st.dcp = null;
            draw_dcust_page();
            return;
        }
        if (st.dcp == null) {
            for (let i = 0; i < 16; i++) {
                let b = dc_cell_rect(i);
                if (in_rect(tx, ty, b.x, b.y, b.w, b.h)) {
                    // Тап по клетке под большим слотом правит сам слот.
                    let cell = (st.dc_pg ?? 0) * 16 + i;
                    let own = dc_covered(dcust_load(), cell);
                    st.dcp = { cell: own >= 0 ? own : cell, stage: "peer" };
                    draw_dcust_page();
                    return;
                }
            }
            return;
        }
        // Строка удаления настроенного слота (низ пикера устройств).
        if (st.dcp.stage == "peer" && dcust_load()[st.dcp.cell] != null &&
            in_rect(tx, ty, GX, GVB - (IS_ALMONDPLUS ? DC_DEL_H : 32), GW, DC_DEL_H)) {
            delete dcust_load()[st.dcp.cell];
            dcust_save();
            st.dcp = null;
            draw_dcust_page();
            return;
        }
        let o = dc_opts();
        for (let i = 0; i < length(o) && i < 12; i++) {
            let b = dc_opt_rect(i);
            if (!in_rect(tx, ty, b.x, b.y, b.w, b.h)) continue;
            if (st.dcp.stage == "peer") {
                st.dcp.peer = o[i].v;
                st.dcp.stage = "met";
            } else if (st.dcp.stage == "met") {
                st.dcp.met = o[i].v;
                st.dcp.stage = "size";
            } else {
                let sz = split(o[i].v, "x");
                let cw = int(sz[0]), ch = int(sz[1]);
                let d = dcust_load();
                let pg0 = int(st.dcp.cell / 16);
                let c0 = (st.dcp.cell % 16) % 4, r0 = int((st.dcp.cell % 16) / 4);
                // Новый слот вытесняет всё, что накрыл, - как перестановка
                // мебели: собрать пересечения и удалить, потом ставить.
                let kill = [];
                for (let k, v in d) {
                    if (int(int(k) / 16) != pg0) continue;
                    let c1 = (int(k) % 16) % 4, r1 = int((int(k) % 16) / 4);
                    if (int(k) != st.dcp.cell &&
                        c1 < c0 + cw && c0 < c1 + (v.cw ?? 1) &&
                        r1 < r0 + ch && r0 < r1 + (v.ch ?? 1))
                        push(kill, k);
                }
                for (let k in kill) delete d[k];
                d[st.dcp.cell] = { p: st.dcp.peer, m: st.dcp.met, cw: cw, ch: ch };
                dcust_save();
                st.dcp = null;
            }
            draw_dcust_page();
            return;
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
                if (saver_scene_of(SAVER_STYLES[i]) != null || SAVER_STYLES[i] == "off"
                    || SAVER_STYLES[i] == "dash") {
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

        let cb = svcust_btn();
        if (in_rect(tx, ty, cb.x, cb.y, cb.w, cb.h)) {
            st.dcp = null;
            go_page("dcust");
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
                if (IS_ALMONDPLUS)
                    lcd_text(b.x + 12, mid_y(b, 2), tcut(e.name ?? "", 20), C.white, C.press, 2);
                else
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
        let pages = length(roms) > GAMES_PER_PAGE
                  ? int((length(roms) + GAMES_PER_PAGE - 1) / GAMES_PER_PAGE) : 1;
        let base = (st.gpg ?? 0) * GAMES_PER_PAGE;
        if (ty >= BACK_Y) {
            let h = pager_hit(tx, ty, pages);
            if (h == PAGER_BACK) { back_press_fx(); go_back(); return; }
            if (h != PAGER_NONE) {
                st.gpg = ((st.gpg ?? 0) + pages + h) % pages;
                draw_games_page();
            }
            return;
        }
        for (let i = 0; i < GAMES_PER_PAGE && base + i < length(roms); i++) {
            let r = games_btn(i);
            if (!in_rect(tx, ty, r.x, r.y, r.w, r.h)) continue;
            if (!fs.stat(NES_BIN)) {
                toast(tr("emulator not installed"), C.red, "#200000", 3);
                return;
            }
            lcd_rect(r.x, r.y, r.w, r.h, C.press);
            if (IS_ALMONDPLUS)
                text_fit2(r.x + 12, mid_y(r, 2), roms[base + i].name, C.white, C.press, r.w - 24);
            else
                lcd_text(r.x + 12, r.y + 9, tcut(roms[base + i].name, 20), C.white, C.press, 1);
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
                lcd_text_c(b.x + int(b.w / 2), IS_ALMONDPLUS ? mid_y(b, 2) + 2 : b.y + 10 + 2,
                         ct, C.white, C.press, IS_ALMONDPLUS ? 2 : 1);
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
        let y1 = GVT + oy;
        // Кнопка ВКЛ/ВЫКЛ проверяется ПЕРВОЙ: её зона отдельная, но так тап по
        // ней гарантированно не проваливается в переименование.
        let br1 = wifi_onoff_rect(y1);
        if (in_rect(tx, ty, br1.x, br1.y, br1.w, br1.h)) {
            wifi_toggle_radio("radio1", "default_radio1");
            return;
        }
        let n1 = wifi_name_box(y1);
        if (in_rect(tx, ty, n1.x, n1.y, n1.w, n1.h) && ucur) {
            st.ssidsec = "default_radio1";
            st.ssidbuf = ucur.get("wireless", "default_radio1", "ssid") ?? "";
            st.kbmode = "ssid";
            st.citykb = { pg: "abc", caps: false };
            go_page("kbd");
            return;
        }
        let q1 = qr_box(y1);
        if (in_rect(tx, ty, q1.x, q1.y, q1.w, q1.h)
            && ucur && !wifi_is_disabled("radio1", "default_radio1")) {
            st.qr_sec = "default_radio1"; st.qr_band = "2.4 GHz";
            go_page("qr");
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

        // Card 2: 5GHz (radio0) - тот же порядок и та же высота, что в отрисовке
        let y2 = y1 + int((GVB - GVT - GG) / 2) + GG;
        let br2 = wifi_onoff_rect(y2);
        if (in_rect(tx, ty, br2.x, br2.y, br2.w, br2.h)) {
            wifi_toggle_radio("radio0", "default_radio0");
            return;
        }
        let n2 = wifi_name_box(y2);
        if (in_rect(tx, ty, n2.x, n2.y, n2.w, n2.h) && ucur) {
            st.ssidsec = "default_radio0";
            st.ssidbuf = ucur.get("wireless", "default_radio0", "ssid") ?? "";
            st.kbmode = "ssid";
            st.citykb = { pg: "abc", caps: false };
            go_page("kbd");
            return;
        }
        let q2 = qr_box(y2);
        if (in_rect(tx, ty, q2.x, q2.y, q2.w, q2.h)
            && ucur && !wifi_is_disabled("radio0", "default_radio0")) {
            st.qr_sec = "default_radio0"; st.qr_band = "5 GHz";
            go_page("qr");
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
    pad_stop();   /* могла остаться от прошлого сеанса: падение или снятие питания */

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
    // Ядерную таблицу инициализации больше не накатываем: она кладёт панель
    // полосами. Если старая настройка залипла в конфиге - гасим её здесь,
    // иначе аппарат ронялся бы на каждой загрузке.
    if (pancfg().init == "kernel") pancfg_set("pinit", "boot");
    panel_apply();

    // Stop splash: ioctl(0) via flush
    system("printf '\\0' > /dev/lcd 2>/dev/null");

    // Initial data + draw. Стартуем на «Модем» - там же, куда попадаем из
    // заставки: иначе после каждого перезапуска демона экран молча уезжал
    // на «Сеть», и выглядело это как «страница сама перескакивает».
    refresh_data();
    st.alarm_on = alarm_is_on();   // статус-иконка будильника с первого кадра
    st.vpn_on = clash_running();   // и значок VPN тоже - до первого кадра
    // Стек Zigbee после сброса чипа (в том числе по питанию) спит, пока ему не
    // скажут networkInit. Поднятая сеть иначе перестаёт отвечать на запросы
    // маяка, и соседи её не видят. Делаем это фоном при старте службы.
    system(sprintf("%s state > /tmp/lcd_zig_state.json 2>/dev/null &", ZIG_BIN));

    // Погода на буте: cron обновляет раз в 15 мин, но сразу после старта
    // первого фетча нет - до ближайшего */15 экран показывает пустую погоду
    // (/tmp стирается ребутом). Плюс RTC-less: пока NTP не выставит время,
    // TLS к API падает на неверной дате. Поэтому в фоне повторяем фетч, пока
    // не появится кэш (до ~3.5 мин), затем эстафету держит cron.
    if (!fs.readfile("/tmp/lcd_weather.txt"))
        system("(for i in 1 2 3 4 5; do /etc/almond3s/scripts/weather_fetch.sh; " +
               "[ -s /tmp/lcd_weather.txt ] && break; sleep 40; done) >/dev/null 2>&1 &");

    let last = fs.readfile("/tmp/.lcd_page");
    st.page = (last != null && trim(last) != "") ? trim(last) : "menu";
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
            if (st.flashing_fw) { bar_t.set(1000); return; }
            if (bar_moving && st.screen == "active" &&
                (st.page == "lte" || st.page == "cell" || st.page == "dashboard" ||
                 st.page == "zigbee" || st.page == "zigpeer")) {
                bar_moving = false;
                draw_current();
            } else if (bar_moving && st.screen == "screensaver" && !st.blank) {
                bar_moving = false;
                draw_saver_tick();
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

        let anim_t, anim_tick = 0, anim_last = 0;
        anim_t = uloop_mod.timer(700, function() {
            if (st.flashing_fw) { anim_t.set(1000); return; }
            let drew = false;
            // Спидтест: живой опрос кэша + перерисовка карточки (заливка/цифры)
            // пока тест идёт. Кэш пишет бэкенд ~раз в секунду; тик 250мс + счётчик
            // заливку ведут монотонные часы, а не счёт тиков.
            // Тест могли запустить не с нашей кнопки - на своей странице
            // подхватываем такой прогон сами, иначе карточка стоит замершей.
            if (st.page == "speedtest" && !st.spd_poll) {
                speedtest_read();
                spd_run_watch();
                if (int(+(st.spd?.running ?? 0)) > 0) {
                    st.spd_poll = true;
                    st.spd_ebase = -1; st.spd_tref = now_ms();
                }
            }
            if (st.page == "speedtest" && st.spd_poll) {
                speedtest_read();
                spd_run_watch();
                let ne = int(+(st.spd?.elapsed ?? 0));
                if (ne != (st.spd_ebase ?? -1)) {
                    st.spd_ebase = ne; st.spd_tref = now_ms();
                    spd_hist_tick();
                }
                if (int(+(st.spd?.running ?? 0)) == 0) {
                    st.spd_poll = false;
                    spd_hist_save();
                }
                if (st.screen == "active") draw_speedtest_page();
                drew = true;
            }
            let bat = st.data?.battery;
            // Шаг анимации заряда привязан к часам, а не к тику: во время
            // замера таймер частит, и батарейка мигала в разы быстрее. Кадр
            // тоже не дублируем - страницу замера уже нарисовали выше.
            if (bat?.charging && !bat?.no_battery &&
                int(+(bat?.percent ?? 0)) < 100 && now_ms() - anim_last >= 700) {
                anim_last = now_ms();
                anim_tick++;
                if (st.screen == "active") {
                    anim_phase++;
                    if (!drew) draw_current();
                } else if (st.screen == "screensaver" && !st.blank && (anim_tick % 2) == 0) {
                    // На заставке шаг вдвое реже: она и задумана спокойной, а
                    // строк батарейки в кадре всего шестнадцать, так что
                    // перерисовка почти ничего не стоит.
                    anim_phase++;
                    draw_saver_tick();
                }
            }
            // Пока идёт тест скорости - тикаем чаще (плавная заливка).
            anim_t.set((st.page == "speedtest" && st.spd_poll) ? SPD_TICK : 700);
        });

        // Data refresh + redraw (every 2s)
        let data_t;
        data_t = uloop_mod.timer(T.data * 1000, function() {
            // Прошивка: маркеры sysupgrade появляются, пока демон ещё жив.
            // Латчим флаг, зажигаем экран и держим красную карточку до смерти.
            if (fs.stat("/tmp/sysupgrade") || fs.stat("/tmp/sysupgrade.img")) {
                if (!st.flashing_fw) {
                    st.flashing_fw = true;
                    st.blank = false;
                    backlight_write(true);
                }
                draw_fw_flash();
                data_t.set(T.data * 1000);
                return;
            }
            if (st.flashing_fw) {
                // Маркеры исчезли - прошивка не пошла/отменена, возвращаем UI.
                st.flashing_fw = false;
                st.page_sig = "";
            }
            refresh_data();
            st.alarm_on = alarm_is_on();   // статус-иконка будильника
            night_tick();
            // Периодический фетч погоды из самого UI: cron */15 ненадёжен на
            // RTC-less буте (кривое время - задание не срабатывает), а на
            // заставке «Погода» данные тогда замерзают до захода в меню. Тик
            // по счётчику (uptime, не по времени), раз в ~15 мин.
            st.wx_tick = (st.wx_tick ?? 0) + 1;
            if (st.wx_tick >= int(900 / T.data)) {
                st.wx_tick = 0;
                system("/etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1 &");
            }
            if (zig_cfg().beacon) {
                zig_tele_write();
                // Сторож маячка: он же и первый запуск. На старте службы uci
                // ещё не прочитан, а сам процесс может и умереть - смотрим по
                // свежести файла соседей, это дешевле опроса процессов.
                st.zig_tick = (st.zig_tick ?? 99) + 1;
                if (st.zig?.flashing && (time() - st.zig.flashing) > 20) {
                    if (!fs.stat("/tmp/.zig_flashing")
                        || (time() - st.zig.flashing) > 300) {
                        st.zig.flashing = null;
                        st.zig.flash_done = time();
                        st.zig_tick = 99;
                        zig_beacon_start();
                    }
                }
                if (st.zig_tick >= 8 && !zig_busy() && !zig_held() && !st.zig?.flashing
                    && !fs.stat("/tmp/.zig_flashing")) {
                    st.zig_tick = 0;
                    let f = fs.stat(ZIG_PEERS);
                    if (!f || (time() - f.mtime) > 20) zig_beacon_start();
                }
            } else if (index(st.page, "zig") == 0 && !zig_held() && !zig_busy()
                       && !st.zig?.flashing && !fs.stat("/tmp/.zig_flashing")) {
                // Телеметрия выключена - файл состояния никто не освежает, и
                // страницы Zigbee показывали прошлое. Чип в этом режиме
                // свободен: пока открыта любая из этих страниц, спрашиваем
                // его сами раз в десять секунд.
                let f = fs.stat(ZIG_STATE);
                if (!f || (time() - f.mtime) > 10)
                    system(sprintf("(%s state > %s.tmp 2>/dev/null && mv %s.tmp %s) </dev/null &",
                                   ZIG_BIN, ZIG_STATE, ZIG_STATE, ZIG_STATE));
            }
            st.vpn_on = clash_running();
            st.vpn_node = st.vpn_on ? (dash_vpn_now().node ?? "") : "";
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
                if (saver_style() == "dash") {
                    sig += sprintf("|%d|%d|%s|%s", dash_page(),
                                   int(+(st.data?.cpu_busy ?? 0)),
                                   fmt_bytes(length(hist.rx) > 0 ? hist.rx[length(hist.rx) - 1] : 0),
                                   fmt_bytes(length(hist.tx) > 0 ? hist.tx[length(hist.tx) - 1] : 0));
                    // На «Своей» странице данные пиров обновляются мимо st.data -
                    // подмешиваем момент их последнего чтения, иначе плитки замрут.
                    if (dash_page() >= length(dash_pages()))
                        sig += "|" + ZP_TS;
                }
                if (sig != st.saver_sig) {
                    st.saver_sig = sig;
                    draw_saver_tick();
                }
            }
            data_t.set(T.data * 1000);
        });


        // Touch polling (every 100ms)
        let touch_t, term_null = 0;
        touch_t = uloop_mod.timer(100, function() {
            if (st.flashing_fw) { touch_t.set(1000); return; }
            screen_req();
            goto_req();
            let t = read_touch();
            if (t) {
                term_null = 0;
                st.ltch = time();
                bl_boost();
                let on_saver = (st.screen == "screensaver" && !st.blank
                                && saver_style() == "dash" && st.saver_scene == null);
                let dot = on_saver ? dash_dot_at(t.x, t.y) : -1;
                // Переключатель дёргаем только на НАСТОЯЩЕМ нажатии: пока
                // палец лежит на стекле, драйвер шлёт события движения каждые
                // 50 мс, и на них значок щёлкал десяток раз за одно касание.
                // Плюс своя выдержка: резистивная панель дребезжит и повтором
                // нажатия. Движение внутри кнопки ПОГЛОЩАЕМ и ничего не делаем -
                // иначе оно проваливалось в ветку пробуждения и заставка
                // уходила прямо под пальцем.
                if (on_saver && dash_hold_at(t.x, t.y)) {
                    if (!t.move) {
                        let c = clock(true);
                        let ms = c[0] * 1000 + int(c[1] / 1000000);
                        if (st.hold_t == null || (ms - st.hold_t) > 600) {
                            st.hold_t = ms;
                            dash_hold_set(!dash_hold());
                            st.dash_t0 = time();
                            draw_saver_tick();
                        }
                    }
                }
                else if (dot >= 0) {
                    dash_goto(dot);
                    draw_saver_tick();
                }
                else if (st.screen != "active")
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
                        : (st.page == "iconedit" ? 40 : (st.page == "term" ? 50 : TOUCH_MS)));
        });

        // Idle check (every 1s)
        let idle_t;
        idle_t = uloop_mod.timer(1000, function() {
            if (st.flashing_fw) { idle_t.set(1000); return; }
            // Истёк тост - снимаем и перерисовываем страницу (стираем полосу).
            if (st.toast && st.toast.until && time() >= st.toast.until) {
                st.toast = null;
                if (st.screen == "active") draw_current();
            }
            if (st.bl_boost && (time() - st.bl_boost) >= BL_BOOST_SEC) {
                st.bl_boost = null;
                if (!st.blank) backlight_write(true);
            }
            st.bl_tick = (st.bl_tick ?? 0) + 1;
            if (st.bl_tick >= 10) { st.bl_tick = 0; bl_reassert(); }
            let idle = time() - st.ltch;
            if (st.screen == "active" && idle >= saver_timeout()
                && !screen_keep_awake())
                set_screen("screensaver");
            idle_t.set(1000);
        });

        // Anti-burn-in shift (every 30s)
        let burnin_t;
        burnin_t = uloop_mod.timer(T.burnin * 1000, function() {
            if (st.flashing_fw) { burnin_t.set(T.burnin * 1000); return; }
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
                draw_saver_tick();
            }

            sock_poll(st.screen == "off" ? 500 : 100);
        }
    }
}

// Single run — procd handles respawn on crash
main();
