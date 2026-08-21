/*
 * almond_pad.cpp — джойстик в браузере телефона.
 *
 * Поднимаем на время игры маленький сервер: по HTTP отдаём одну страницу с
 * кнопками, дальше держим WebSocket и принимаем состояние кнопок. Обычный HTTP
 * для игры не годится - на каждое нажатие отдельное соединение, задержка под
 * сотню миллисекунд; сырые сокеты браузеру недоступны, поэтому WebSocket.
 *
 * Ввод ДОБАВЛЯЕТСЯ к экранному и клавиатурному, а не заменяет их: если телефон
 * подтормозит на Wi-Fi, играть всё равно можно.
 *
 * Слушаем на всех интерфейсах, но наружу порт не открыт (правил в фаерволе не
 * добавляем) - то есть доступно только из локальной сети.
 *
 * Первый подключившийся получает первого игрока, второй - второго: NES держит
 * два джойстика аппаратно, и эмулятор их принимает.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/stat.h>

#define PAD_PORT 8099

/* Состояние кнопок кладём в файл, эмулятор читает его каждый кадр - ровно так
   же, как уже читает тачскрин. Файл-флаг рядом говорит, идёт ли игра: пульт
   про эмулятор больше ничего не знает и знать не должен. */
#define PAD_STATE "/tmp/.nes_pad"
#define PAD_RUN   "/tmp/.nes_run"
#define MAX_CL   2

/* Звук игры. Эмулятор пишет сюда сырые сэмплы 22050 Гц, моно, 16 бит; мы их
   раздаём телефону теми же кадрами WebSocket, что и состояние пульта. Читающий
   конец держим открытым, только пока звук кто-то просит: без читателя эмулятор
   не сможет открыть трубу и не станет зря считать каналы APU. */
#define SND_FIFO "/tmp/.nes_snd"
#define SND_TAG  0xA0

static int srv_fd = -1;
static struct {
    int fd;
    int ws;        /* рукопожатие пройдено */
    unsigned char pad;
    unsigned char snd;   /* телефон попросил звук */
    char in[1024];
    int  len;
} cl[MAX_CL];

static int snd_fd = -1;

/* ---- SHA-1: нужен только для рукопожатия WebSocket ---- */
struct sha1 { unsigned int h[5]; unsigned char buf[64]; unsigned long long n; int i; };

static void sha1_block(struct sha1* s, const unsigned char* p)
{
    unsigned int w[80], a, b, c, d, e, f, k, t;
    int j;
    for (j = 0; j < 16; j++)
        w[j] = (p[j*4] << 24) | (p[j*4+1] << 16) | (p[j*4+2] << 8) | p[j*4+3];
    for (j = 16; j < 80; j++) {
        t = w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16];
        w[j] = (t << 1) | (t >> 31);
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4];
    for (j = 0; j < 80; j++) {
        if (j < 20)      { f = (b & c) | (~b & d);            k = 0x5A827999; }
        else if (j < 40) { f = b ^ c ^ d;                     k = 0x6ED9EBA1; }
        else if (j < 60) { f = (b & c) | (b & d) | (c & d);   k = 0x8F1BBCDC; }
        else             { f = b ^ c ^ d;                     k = 0xCA62C1D6; }
        t = ((a << 5) | (a >> 27)) + f + e + k + w[j];
        e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e;
}

static void sha1_run(const char* data, int len, unsigned char out[20])
{
    struct sha1 s;
    unsigned char tail[128];
    int i, pad;
    unsigned long long bits = (unsigned long long)len * 8;
    s.h[0] = 0x67452301; s.h[1] = 0xEFCDAB89; s.h[2] = 0x98BADCFE;
    s.h[3] = 0x10325476; s.h[4] = 0xC3D2E1F0;
    for (i = 0; i + 64 <= len; i += 64) sha1_block(&s, (const unsigned char*)data + i);
    pad = len - i;
    memcpy(tail, data + i, pad);
    tail[pad++] = 0x80;
    while ((pad % 64) != 56) tail[pad++] = 0;
    for (i = 7; i >= 0; i--) tail[pad++] = (unsigned char)(bits >> (i * 8));
    for (i = 0; i < pad; i += 64) sha1_block(&s, tail + i);
    for (i = 0; i < 20; i++) out[i] = (unsigned char)(s.h[i / 4] >> (24 - (i % 4) * 8));
}

static void b64(const unsigned char* in, int n, char* out)
{
    static const char* T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int i, o = 0;
    for (i = 0; i < n; i += 3) {
        unsigned v = in[i] << 16;
        if (i + 1 < n) v |= in[i+1] << 8;
        if (i + 2 < n) v |= in[i+2];
        out[o++] = T[(v >> 18) & 63];
        out[o++] = T[(v >> 12) & 63];
        out[o++] = (i + 1 < n) ? T[(v >> 6) & 63] : '=';
        out[o++] = (i + 2 < n) ? T[v & 63] : '=';
    }
    out[o] = 0;
}

/* ---- страница с кнопками ---- */
static const char PAGE[] =
"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,"
"initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover'><title>NES</title><style>"
/* Вид - как у кнопок на самом экранчике: толстая тёмная обводка, плоская
   заливка и светлая полоса сверху и справа. Оттуда же пиксельные глифы A и B
   (тот же шрифт 5x7) и ступенчатые стрелки, что и на панели.
   Размеры ограничены сразу по трём осям - vmin, vh и vw. Только vmin не
   годится: по высоте кнопки вылезали за верх в альбомной ориентации, по
   ширине ряд не помещался в книжной и A уезжала за край.
   Логотип стоит между крестовиной и кнопками, но в книжной ориентации там
   остаётся десяток пикселей - поэтому для неё он поднят наверх, где есть
   ширина. Показывается всегда ровно один.
   Атрибуты в svg закавычены не для красоты: в HTML незакавыченное значение
   поглощает косую черту, и height=1 со слэшем читается как height со слэшем
   внутри - тег не закрывается и фигура не рисуется вовсе. */
"*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}"
"html,body{margin:0;height:100dvh;background:#0d1117;color:#8b949e;"
"font:14px ui-monospace,Menlo,Consolas,monospace;user-select:none;"
"-webkit-user-select:none;touch-action:none;overflow:hidden}"
"body{display:flex;flex-direction:column;padding:calc(env(safe-area-inset-top) + 8px) 8px "
"calc(env(safe-area-inset-bottom) + 8px)}"
/* Строка состояния - тем же пиксельным шрифтом, что кнопки и логотип:
   она стоит внутри корпуса, и обычный системный шрифт рядом с пиксельным
   выглядел чужеродно. Глифы рисует скрипт - текст меняется на ходу. */
/* Строка состояния просто по центру корпуса: отступ над ней и под нижним
   рядом такой же, как по бокам. */
"#s{flex:0 0 auto;display:flex;align-items:center;justify-content:center;gap:9px;"
"padding-bottom:clamp(12px,4.5vmin,26px)}"
/* Лампочка состояния: свечение делаем тенью того же цвета - на
   тёмном фоне это читается как светодиод. Красная ещё и дышит:
   связи нет и попытки идут, статичная точка выглядела бы
   как поломка. */
".dot{width:10px;height:10px;border-radius:50%;flex:0 0 auto}"
".dot.g{background:#3FB950;box-shadow:0 0 7px 2px rgba(63,185,80,.85)}"
".dot.r{background:#F85149;box-shadow:0 0 7px 2px rgba(248,81,73,.85);"
"animation:bl 1.1s ease-in-out infinite}"
"@keyframes bl{0%,100%{opacity:1}50%{opacity:.35}}"
".st{fill:#fff;shape-rendering:crispEdges;display:block;width:auto;"
"height:clamp(11px,3.2vmin,18px)}"
"#pad{flex:1 1 auto;min-height:0;display:flex;flex-direction:column;"
"border:4px solid #3d444d;border-radius:14px;background:#161b22;"
"box-shadow:inset 0 4px 0 rgba(255,255,255,.06),inset -4px 0 0 rgba(255,255,255,.04);"
/* Отступ внутри корпуса одинаковый со всех сторон - иначе кнопки
   липнут к рамке. Он же съедает ширину, поэтому пределы кнопок по
   vw ниже пересчитаны: в книжной ориентации ряд помещается впритык. */
"padding:clamp(12px,4.5vmin,26px);overflow:hidden;"
/* Пределы по высоте: под ряд остаётся высота минус строка состояния и
   отступы корпуса. Слева это 2*--d, справа стопка COMBO + A/B, то есть
   2*--ab с зазором - оба должны влезать, иначе кнопки уходят за рамку. */
"--d:clamp(40px,min(30vmin,27vh,16.5vw),128px);"
"--ab:clamp(46px,min(31vmin,25vh,15vw),124px);--abg:clamp(6px,2vmin,16px)}"
/* Три колонки заданы явно: крестовина, середина (логотип + START/SELECT) и
   правый блок. На flex это разъезжалось - колонка сжималась ниже
   содержимого либо уводила соседей на новую строку. Низ крестовины и
   середины на одной линии, правый блок по центру. */
"#mid{flex:1 1 auto;display:grid;align-items:end;gap:6px;min-height:0;min-width:0;"
"grid-template-columns:calc(3 * var(--d)) 1fr calc(2 * var(--ab) + var(--abg))}"
"#bot{display:flex;justify-content:center;gap:10px}"
"#dp{flex:0 0 auto;display:grid;grid-template-columns:repeat(3,var(--d));"
"grid-template-rows:repeat(2,var(--d))}"
"#ab{display:flex;align-items:center;gap:var(--abg)}"
/* Правая колонка: COMBO над парой B и A. Ширина у него ровно как у пары
   вместе с зазором, высота как у START и SELECT. */
"#abw{flex:0 0 auto;align-self:center;display:flex;flex-direction:column;"
"align-items:center;gap:10px}"
".cb{width:calc(2 * var(--ab) + var(--abg));height:var(--ab);"
"background:#E8833A;border-color:#5a2d0e;"
"font-size:clamp(10px,2.5vmin,13px);letter-spacing:2px}"
"b{display:flex;align-items:center;justify-content:center;"
"background:#4a5058;border:3px solid #0b0e13;border-radius:3px;color:#fff;"
"box-shadow:inset 0 4px 0 rgba(255,255,255,.30),inset -4px 0 0 rgba(255,255,255,.18)}"
"b:active,b.on{background:#22c55e}"
".g{fill:currentColor;shape-rendering:crispEdges;pointer-events:none;display:block}"
".d{width:100%;height:100%}"
".d .g{width:18%;height:18%}"
".ab{width:var(--ab);"
"height:var(--ab);background:#c62828;border-color:#3a0d0d}"
".ab .g{width:42%;height:42%}"
".se{flex:0 0 auto;width:clamp(58px,16vmin,96px);"
"height:clamp(30px,min(10vmin,8vh),44px);"
"font-size:clamp(10px,2.6vmin,13px);letter-spacing:2px;background:#4a5058}"
".lg{fill:#21b365;shape-rendering:crispEdges;display:block}"
/* Середина - колонка: логотип, под ним START и SELECT. Ряд выровнен по
   нижней границе, поэтому низ этих кнопок ложится на одну линию с низом
   стрелок и кнопок A/B. */
/* Колонка тянется на всю высоту ряда: логотип уходит к верху, а START и
   SELECT остаются внизу, на одной линии со стрелками. */
"#lmid{min-width:0;align-self:stretch;display:flex;flex-direction:column;"
"align-items:center;justify-content:flex-end;gap:10px;padding:0 10px}"
/* Логотип по центру свободного места колонки: он в растягивающейся обёртке,
   а START и SELECT остаются прижатыми к низу, на линии стрелок. */
"#lwrap{flex:1 1 auto;min-height:0;display:flex;align-items:center;justify-content:center}"
"#lmid .lg{width:min(100%,150px);height:auto}"
/* В книжной ориентации между крестовиной и кнопками остаётся десяток
   пикселей, поэтому надпись переносится на свою строку выше - копию
   разметки для этого держать не нужно, достаточно переноса flex. */
/* Нижний ряд центрируется по всей ширине корпуса и в альбомной
   ориентации залезал под правую стрелку. Отступаем слева на крестовину,
   справа на A и B - остаток ровно колонка логотипа, и центр совпадает. */

/* Книжная: логотип уезжает своей строкой наверх, а кнопки прижимаем к низу
   корпуса - в колонке наверху они оказались бы под большим пальцем не в том
   месте. */
"@media(orientation:portrait){#pad{position:relative}"
"#mid{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between}"
"#bot{width:auto}"
"#bot{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 14px)}"
"#lmid{order:-1;flex:0 0 100%;padding:0 0 6px}"
"#lmid .lg{width:min(42%,160px)}}"
"</style><div id=pad><div id=s></div><div id=mid>"
"<div id=dp>"
"<i></i><b class=d id=U><svg class=g viewBox='0 0 15 8'><rect x='7' y='0' width='1' height='1'/><rect x='6' y='1' width='3' height='1'/><rect x='5' y='2' width='5' height='1'/><rect x='4' y='3' width='7' height='1'/><rect x='3' y='4' width='9' height='1'/><rect x='2' y='5' width='11' height='1'/><rect x='1' y='6' width='13' height='1'/><rect x='0' y='7' width='15' height='1'/></svg></b><i></i>"
"<b class=d id=L><svg class=g viewBox='0 0 8 15'><rect x='0' y='7' width='1' height='1'/><rect x='1' y='6' width='1' height='3'/><rect x='2' y='5' width='1' height='5'/><rect x='3' y='4' width='1' height='7'/><rect x='4' y='3' width='1' height='9'/><rect x='5' y='2' width='1' height='11'/><rect x='6' y='1' width='1' height='13'/><rect x='7' y='0' width='1' height='15'/></svg></b><b class=d id=D><svg class=g viewBox='0 0 15 8'><rect x='7' y='7' width='1' height='1'/><rect x='6' y='6' width='3' height='1'/><rect x='5' y='5' width='5' height='1'/><rect x='4' y='4' width='7' height='1'/><rect x='3' y='3' width='9' height='1'/><rect x='2' y='2' width='11' height='1'/><rect x='1' y='1' width='13' height='1'/><rect x='0' y='0' width='15' height='1'/></svg></b><b class=d id=R><svg class=g viewBox='0 0 8 15'><rect x='7' y='7' width='1' height='1'/><rect x='6' y='6' width='1' height='3'/><rect x='5' y='5' width='1' height='5'/><rect x='4' y='4' width='1' height='7'/><rect x='3' y='3' width='1' height='9'/><rect x='2' y='2' width='1' height='11'/><rect x='1' y='1' width='1' height='13'/><rect x='0' y='0' width='1' height='15'/></svg></b>"
"</div>"
"<div id=lmid><div id=lwrap><svg class=lg viewBox='0 0 140 41'><rect x='4' y='0' width='12' height='4'/><rect x='24' y='0' width='4' height='4'/><rect x='48' y='0' width='4' height='4'/><rect x='64' y='0' width='4' height='4'/><rect x='76' y='0' width='12' height='4'/><rect x='96' y='0' width='4' height='4'/><rect x='112' y='0' width='4' height='4'/><rect x='120' y='0' width='16' height='4'/><rect x='0' y='4' width='4' height='4'/><rect x='16' y='4' width='4' height='4'/><rect x='24' y='4' width='4' height='4'/><rect x='48' y='4' width='8' height='4'/><rect x='60' y='4' width='8' height='4'/><rect x='72' y='4' width='4' height='4'/><rect x='88' y='4' width='4' height='4'/><rect x='96' y='4' width='4' height='4'/><rect x='112' y='4' width='4' height='4'/><rect x='120' y='4' width='4' height='4'/><rect x='136' y='4' width='4' height='4'/><rect x='0' y='8' width='4' height='4'/><rect x='16' y='8' width='4' height='4'/><rect x='24' y='8' width='4' height='4'/><rect x='48' y='8' width='4' height='4'/><rect x='56' y='8' width='4' height='4'/><rect x='64' y='8' width='4' height='4'/><rect x='72' y='8' width='4' height='4'/><rect x='88' y='8' width='4' height='4'/><rect x='96' y='8' width='8' height='4'/><rect x='112' y='8' width='4' height='4'/><rect x='120' y='8' width='4' height='4'/><rect x='136' y='8' width='4' height='4'/><rect x='0' y='12' width='4' height='4'/><rect x='16' y='12' width='4' height='4'/><rect x='24' y='12' width='4' height='4'/><rect x='48' y='12' width='4' height='4'/><rect x='56' y='12' width='4' height='4'/><rect x='64' y='12' width='4' height='4'/><rect x='72' y='12' width='4' height='4'/><rect x='88' y='12' width='4' height='4'/><rect x='96' y='12' width='4' height='4'/><rect x='104' y='12' width='4' height='4'/><rect x='112' y='12' width='4' height='4'/><rect x='120' y='12' width='4' height='4'/><rect x='136' y='12' width='4' height='4'/><rect x='0' y='16' width='20' height='4'/><rect x='24' y='16' width='4' height='4'/><rect x='48' y='16' width='4' height='4'/><rect x='64' y='16' width='4' height='4'/><rect x='72' y='16' width='4' height='4'/><rect x='88' y='16' width='4' height='4'/><rect x='96' y='16' width='4' height='4'/><rect x='108' y='16' width='8' height='4'/><rect x='120' y='16' width='4' height='4'/><rect x='136' y='16' width='4' height='4'/><rect x='0' y='20' width='4' height='4'/><rect x='16' y='20' width='4' height='4'/><rect x='24' y='20' width='4' height='4'/><rect x='48' y='20' width='4' height='4'/><rect x='64' y='20' width='4' height='4'/><rect x='72' y='20' width='4' height='4'/><rect x='88' y='20' width='4' height='4'/><rect x='96' y='20' width='4' height='4'/><rect x='112' y='20' width='4' height='4'/><rect x='120' y='20' width='4' height='4'/><rect x='136' y='20' width='4' height='4'/><rect x='0' y='24' width='4' height='4'/><rect x='16' y='24' width='4' height='4'/><rect x='24' y='24' width='20' height='4'/><rect x='48' y='24' width='4' height='4'/><rect x='64' y='24' width='4' height='4'/><rect x='76' y='24' width='12' height='4'/><rect x='96' y='24' width='4' height='4'/><rect x='112' y='24' width='4' height='4'/><rect x='120' y='24' width='16' height='4'/><rect x='38' y='34' width='4' height='1'/><rect x='43' y='34' width='5' height='1'/><rect x='50' y='34' width='3' height='1'/><rect x='56' y='34' width='3' height='1'/><rect x='61' y='34' width='1' height='1'/><rect x='65' y='34' width='1' height='1'/><rect x='67' y='34' width='4' height='1'/><rect x='79' y='34' width='1' height='1'/><rect x='86' y='34' width='3' height='1'/><rect x='91' y='34' width='5' height='1'/><rect x='97' y='34' width='5' height='1'/><rect x='37' y='35' width='1' height='1'/><rect x='43' y='35' width='1' height='1'/><rect x='49' y='35' width='1' height='1'/><rect x='53' y='35' width='1' height='1'/><rect x='55' y='35' width='1' height='1'/><rect x='59' y='35' width='1' height='1'/><rect x='61' y='35' width='1' height='1'/><rect x='65' y='35' width='1' height='1'/><rect x='67' y='35' width='1' height='1'/><rect x='71' y='35' width='1' height='1'/><rect x='79' y='35' width='1' height='1'/><rect x='87' y='35' width='1' height='1'/><rect x='91' y='35' width='1' height='1'/><rect x='97' y='35' width='1' height='1'/><rect x='37' y='36' width='1' height='1'/><rect x='43' y='36' width='1' height='1'/><rect x='49' y='36' width='1' height='1'/><rect x='55' y='36' width='1' height='1'/><rect x='59' y='36' width='1' height='1'/><rect x='61' y='36' width='2' height='1'/><rect x='65' y='36' width='1' height='1'/><rect x='67' y='36' width='1' height='1'/><rect x='71' y='36' width='1' height='1'/><rect x='79' y='36' width='1' height='1'/><rect x='87' y='36' width='1' height='1'/><rect x='91' y='36' width='1' height='1'/><rect x='97' y='36' width='1' height='1'/><rect x='38' y='37' width='3' height='1'/><rect x='43' y='37' width='4' height='1'/><rect x='49' y='37' width='1' height='1'/><rect x='55' y='37' width='1' height='1'/><rect x='59' y='37' width='1' height='1'/><rect x='61' y='37' width='1' height='1'/><rect x='63' y='37' width='1' height='1'/><rect x='65' y='37' width='1' height='1'/><rect x='67' y='37' width='1' height='1'/><rect x='71' y='37' width='1' height='1'/><rect x='79' y='37' width='1' height='1'/><rect x='87' y='37' width='1' height='1'/><rect x='91' y='37' width='4' height='1'/><rect x='97' y='37' width='4' height='1'/><rect x='41' y='38' width='1' height='1'/><rect x='43' y='38' width='1' height='1'/><rect x='49' y='38' width='1' height='1'/><rect x='55' y='38' width='1' height='1'/><rect x='59' y='38' width='1' height='1'/><rect x='61' y='38' width='1' height='1'/><rect x='64' y='38' width='2' height='1'/><rect x='67' y='38' width='1' height='1'/><rect x='71' y='38' width='1' height='1'/><rect x='79' y='38' width='1' height='1'/><rect x='87' y='38' width='1' height='1'/><rect x='91' y='38' width='1' height='1'/><rect x='97' y='38' width='1' height='1'/><rect x='41' y='39' width='1' height='1'/><rect x='43' y='39' width='1' height='1'/><rect x='49' y='39' width='1' height='1'/><rect x='53' y='39' width='1' height='1'/><rect x='55' y='39' width='1' height='1'/><rect x='59' y='39' width='1' height='1'/><rect x='61' y='39' width='1' height='1'/><rect x='65' y='39' width='1' height='1'/><rect x='67' y='39' width='1' height='1'/><rect x='71' y='39' width='1' height='1'/><rect x='79' y='39' width='1' height='1'/><rect x='87' y='39' width='1' height='1'/><rect x='91' y='39' width='1' height='1'/><rect x='97' y='39' width='1' height='1'/><rect x='37' y='40' width='4' height='1'/><rect x='43' y='40' width='5' height='1'/><rect x='50' y='40' width='3' height='1'/><rect x='56' y='40' width='3' height='1'/><rect x='61' y='40' width='1' height='1'/><rect x='65' y='40' width='1' height='1'/><rect x='67' y='40' width='4' height='1'/><rect x='79' y='40' width='5' height='1'/><rect x='86' y='40' width='3' height='1'/><rect x='91' y='40' width='1' height='1'/><rect x='97' y='40' width='5' height='1'/></svg></div><div id=bot><b class=se id=SE>SELECT</b><b class=se id=ST>START</b></div></div>"
"<div id=abw><b class=cb id=CB>COMBO</b><div id=ab><b class=ab id=B><svg class=g viewBox='0 0 5 7'><rect x='0' y='0' width='1' height='1'/><rect x='0' y='1' width='1' height='1'/><rect x='0' y='2' width='1' height='1'/><rect x='0' y='3' width='1' height='1'/><rect x='0' y='4' width='1' height='1'/><rect x='0' y='5' width='1' height='1'/><rect x='0' y='6' width='1' height='1'/><rect x='1' y='0' width='1' height='1'/><rect x='1' y='3' width='1' height='1'/><rect x='1' y='6' width='1' height='1'/><rect x='2' y='0' width='1' height='1'/><rect x='2' y='3' width='1' height='1'/><rect x='2' y='6' width='1' height='1'/><rect x='3' y='0' width='1' height='1'/><rect x='3' y='3' width='1' height='1'/><rect x='3' y='6' width='1' height='1'/><rect x='4' y='1' width='1' height='1'/><rect x='4' y='2' width='1' height='1'/><rect x='4' y='4' width='1' height='1'/><rect x='4' y='5' width='1' height='1'/></svg></b>"
"<b class=ab id=A><svg class=g viewBox='0 0 5 7'><rect x='0' y='1' width='1' height='1'/><rect x='0' y='2' width='1' height='1'/><rect x='0' y='3' width='1' height='1'/><rect x='0' y='4' width='1' height='1'/><rect x='0' y='5' width='1' height='1'/><rect x='0' y='6' width='1' height='1'/><rect x='1' y='0' width='1' height='1'/><rect x='1' y='4' width='1' height='1'/><rect x='2' y='0' width='1' height='1'/><rect x='2' y='4' width='1' height='1'/><rect x='3' y='0' width='1' height='1'/><rect x='3' y='4' width='1' height='1'/><rect x='4' y='1' width='1' height='1'/><rect x='4' y='2' width='1' height='1'/><rect x='4' y='3' width='1' height='1'/><rect x='4' y='4' width='1' height='1'/><rect x='4' y='5' width='1' height='1'/><rect x='4' y='6' width='1' height='1'/></svg></b></div></div>"
"</div>"
"</div>"
"<script>"
"var M={A:1,B:2,CB:3,SE:4,ST:8,U:16,D:32,L:64,R:128},st=0,ws,s=document.getElementById('s');"
"var FT={P:[127,9,9,9,6],L:[127,64,64,64,64],A:[126,17,17,17,126],Y:[7,8,112,8,7],"
"E:[127,73,73,73,65],R:[127,9,25,41,70],C:[62,65,65,65,34],O:[62,65,65,65,62],"
"N:[127,4,8,16,127],T:[1,1,127,1,1],I:[0,65,127,65,0],G:[62,65,73,73,122],"
"D:[127,65,65,65,62],W:[63,64,56,64,63],1:[0,66,127,64,0],2:[98,81,73,73,70],"
"'.':[64,0,0,0,0],' ':[0,0,0,0,0]};"
/* Соседние пиксели строки склеиваем в один прямоугольник - разметки втрое
   меньше. Атрибуты без кавычек, зато с закрывающим тегом: самозакрывающийся
   слэш при незакавыченном значении съедается разбором HTML. */
"function pix(t){var w=t.length*6-1,o='';"
"for(var k=0;k<t.length;k++){var g=FT[t[k]]||FT[' '];"
"for(var y=0;y<7;y++){var c=0;while(c<5){if(!(g[c]&(1<<y))){c++;continue}"
"var n=1;while(c+n<5&&(g[c+n]&(1<<y)))n++;"
"o+='<rect x='+(k*6+c)+' y='+y+' width='+n+' height=1></rect>';c+=n}}}"
"return '<svg class=st viewBox=\"0 0 '+w+' 7\">'+o+'</svg>'}"
"function say(t,ok){s.innerHTML='<i class=\"dot '+(ok?'g':'r')+'\"></i>'+pix(t)}"
"function send(){if(ws&&ws.readyState==1)ws.send(new Uint8Array([st]))}"
/* Звук браузер сам не заведёт - нужен жест. Первое нажатие на кнопку и есть
   жест, поэтому запускаем оттуда. Держим запас около 120 мс: меньше - щелчки
   на любой заминке в эфире, больше - заметное опоздание к картинке. */
"var ac=null,ap=0,sw=0,hs=0;"
"function snd(){if(!ac){try{ac=new (window.AudioContext||window.webkitAudioContext)()}"
"catch(e){say('NO AUDIO',0);return}}"
"if(ac.state=='suspended')ac.resume();"
"sw=1;if(ws&&ws.readyState==1)ws.send(new Uint8Array([83,1]))}"
"function play(v){if(!ac)return;var n=v.length>>1;if(!n)return;"
"if(!hs){hs=1;say('SOUND',1)}"
"var b=ac.createBuffer(1,n,22050),c=b.getChannelData(0),i,q;"
"for(i=0;i<n;i++){q=v[i*2]|(v[i*2+1]<<8);if(q>32767)q-=65536;c[i]=q/32768}"
"var t=ac.currentTime;if(ap<t+0.04)ap=t+0.12;if(ap>t+0.4)return;"
"var o=ac.createBufferSource();o.buffer=b;o.connect(ac.destination);o.start(ap);ap+=b.duration}"
"function bind(id){var e=document.getElementById(id),m=M[id];"
"function on(ev){ev.preventDefault();snd();if(st&m)return;st|=m;e.classList.add('on');send()}"
"function off(ev){ev.preventDefault();if(!(st&m))return;st&=~m;e.classList.remove('on');send()}"
"e.addEventListener('touchstart',on,{passive:false});"
"e.addEventListener('touchend',off,{passive:false});"
"e.addEventListener('touchcancel',off,{passive:false});"
"e.addEventListener('mousedown',on);e.addEventListener('mouseup',off);"
"e.addEventListener('mouseleave',off)}"
"for(var k in M)bind(k);"
/* Палец, съехавший с кнопки, иначе оставлял её нажатой навсегда. */
"document.addEventListener('touchend',function(){if(!document.querySelector('b:active')){"
"st=0;send();var l=document.querySelectorAll('b.on');for(var i=0;i<l.length;i++)l[i].classList.remove('on')}});"
"function conn(){ws=new WebSocket('ws://'+location.host+'/ws');ws.binaryType='arraybuffer';"
"ws.onopen=function(){say('CONNECTED',1);if(sw)ws.send(new Uint8Array([83,1]))};"
"ws.onclose=function(){say('RECONNECTING...',0);setTimeout(conn,1000)};"
"ws.onmessage=function(m){var v=new Uint8Array(m.data);if(!v.length)return;"
"if(v[0]==160){play(v.subarray(1));return}"
"say(v.length>1&&!v[1]?'WAITING...':'PLAYER '+v[0],1)}}"
"say('CONNECTING...',0);conn();"
"</script>";

static void cl_close(int i)
{
    if (cl[i].fd >= 0) close(cl[i].fd);
    cl[i].fd = -1; cl[i].ws = 0; cl[i].pad = 0; cl[i].snd = 0; cl[i].len = 0;
}

/* Труба нужна ровно пока её кто-то слушает. */
static void snd_sync(void)
{
    int want = 0;
    for (int i = 0; i < MAX_CL; i++) if (cl[i].fd >= 0 && cl[i].snd) want = 1;
    if (want && snd_fd < 0) {
        mkfifo(SND_FIFO, 0666);
        snd_fd = open(SND_FIFO, O_RDONLY | O_NONBLOCK);
    } else if (!want && snd_fd >= 0) {
        close(snd_fd);
        snd_fd = -1;
    }
}

/* Кадр длиннее 125 байт требует расширенной длины - у статуса её не было. */
static void ws_send_bin(int i, const unsigned char *d, int n)
{
    unsigned char h[4];
    if (cl[i].fd < 0 || !cl[i].ws) return;
    h[0] = 0x82;
    if (n < 126) {
        h[1] = (unsigned char)n;
        if (send(cl[i].fd, h, 2, MSG_NOSIGNAL | MSG_DONTWAIT) != 2) return;
    } else {
        h[1] = 126; h[2] = (unsigned char)(n >> 8); h[3] = (unsigned char)n;
        if (send(cl[i].fd, h, 4, MSG_NOSIGNAL | MSG_DONTWAIT) != 4) return;
    }
    (void)!send(cl[i].fd, d, (size_t)n, MSG_NOSIGNAL | MSG_DONTWAIT);
}

/* Забрать готовые сэмплы и раздать. Не влезло в сокет - выбрасываем: тянуть
   очередь звука дороже, чем пропустить его кусок. */
static void snd_pump(void)
{
    static unsigned char buf[1025];
    int n;

    snd_sync();
    if (snd_fd < 0) return;
    buf[0] = SND_TAG;
    n = (int)read(snd_fd, buf + 1, sizeof buf - 1);
    if (n <= 0) return;
    for (int i = 0; i < MAX_CL; i++)
        if (cl[i].fd >= 0 && cl[i].ws && cl[i].snd) ws_send_bin(i, buf, n + 1);
}

int pad_net_init(void)
{
    struct sockaddr_in a;
    int on = 1;
    for (int i = 0; i < MAX_CL; i++) cl[i].fd = -1;
    srv_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (srv_fd < 0) return -1;
    setsockopt(srv_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(PAD_PORT);
    if (bind(srv_fd, (struct sockaddr*)&a, sizeof a) || listen(srv_fd, 4)) {
        close(srv_fd); srv_fd = -1; return -1;
    }
    fcntl(srv_fd, F_SETFL, O_NONBLOCK);
    return PAD_PORT;
}

/* Слот выдаётся по порядку подключения, но в ссылке можно попросить свой:
   .../?p=2. Это нужно ради двух разных QR-кодов в настройках - иначе номер
   игрока зависел бы от того, кто успел раньше. Занятый слот не отбираем. */
static int claim_slot(int i)
{
    char *q = strstr(cl[i].in, "?p=");
    int want;
    if (!q) return i;
    want = q[3] - '1';
    if (want < 0 || want >= MAX_CL || want == i) return i;
    if (cl[want].fd >= 0) return i;
    cl[want] = cl[i];
    cl[i].fd = -1;
    cl[i].ws = 0;
    cl[i].len = 0;
    cl[i].pad = 0;
    return want;
}

static int game_running;

/* Второй байт - идёт ли игра. Страница по нему пишет «жду игру» вместо номера:
   пульт теперь живёт и до запуска, и между играми. */
static void pad_status_send(int i)
{
    unsigned char f[4] = { 0x82, 2, (unsigned char)(i + 1),
                           (unsigned char)(game_running ? 1 : 0) };
    if (cl[i].fd >= 0 && cl[i].ws) send(cl[i].fd, f, 4, MSG_NOSIGNAL);
}

static void handshake(int i)
{
    char* k;
    i = claim_slot(i);
    k = strcasestr(cl[i].in, "Sec-WebSocket-Key:");
    char key[128], cat[200], resp[256], acc[40];
    unsigned char dg[20];
    int n = 0;
    if (!k) { cl_close(i); return; }
    k += 18;
    while (*k == ' ') k++;
    while (*k && *k != '\r' && *k != '\n' && n < (int)sizeof key - 1) key[n++] = *k++;
    key[n] = 0;
    snprintf(cat, sizeof cat, "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key);
    sha1_run(cat, strlen(cat), dg);
    b64(dg, 20, acc);
    n = snprintf(resp, sizeof resp,
                 "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                 "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc);
    send(cl[i].fd, resp, n, MSG_NOSIGNAL);
    cl[i].ws = 1;
    cl[i].len = 0;
    /* Сообщаем номер игрока и идёт ли игра - страница покажет это сверху. */
    pad_status_send(i);
}

/* Страница живёт внутри бинаря и меняется вместе с ним, а телефон держал её
   в кеше и после обновления показывал прежнюю. Раздаём как несохраняемую:
   она крохотная, а путаницы от устаревшей копии много. */
static void serve_page(int i)
{
    char hdr[192];
    int n = snprintf(hdr, sizeof hdr,
                     "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                     "Cache-Control: no-store, no-cache, must-revalidate\r\n"
                     "Pragma: no-cache\r\nExpires: 0\r\n"
                     "Content-Length: %u\r\nConnection: close\r\n\r\n",
                     (unsigned)(sizeof PAGE - 1));
    send(cl[i].fd, hdr, n, MSG_NOSIGNAL);
    send(cl[i].fd, PAGE, sizeof PAGE - 1, MSG_NOSIGNAL);
    cl_close(i);
}

/* Разбор кадров WebSocket. От клиента они всегда маскированы. */
static void ws_frames(int i)
{
    while (cl[i].len >= 2) {
        unsigned char* p = (unsigned char*)cl[i].in;
        int op = p[0] & 0x0F, masked = p[1] & 0x80;
        unsigned long long plen = p[1] & 0x7F;
        int hdr = 2;
        if (plen == 126) { if (cl[i].len < 4) return; plen = (p[2] << 8) | p[3]; hdr = 4; }
        else if (plen == 127) { cl_close(i); return; }   /* таких кадров не ждём */
        if (masked) hdr += 4;
        if (cl[i].len < hdr + (int)plen) return;
        if (op == 0x8) { cl_close(i); return; }          /* close */
        if (op == 0x1 || op == 0x2) {
            unsigned char* d = p + hdr;
            if (masked) {
                unsigned char* m = p + hdr - 4;
                for (unsigned long long j = 0; j < plen; j++) d[j] ^= m[j & 3];
            }
            /* Один байт - состояние кнопок. Два, начиная с 'S', - просьба
               включить или выключить звук. */
            if (plen == 1) cl[i].pad = d[0];
            else if (plen >= 2 && d[0] == 'S') cl[i].snd = d[1] ? 1 : 0;
        }
        memmove(cl[i].in, p + hdr + plen, cl[i].len - hdr - plen);
        cl[i].len -= hdr + plen;
    }
}

void pad_net_poll(void)
{
    if (srv_fd < 0) return;

    int fd = accept(srv_fd, NULL, NULL);
    if (fd >= 0) {
        int slot = -1, on = 1;
        for (int i = 0; i < MAX_CL; i++) if (cl[i].fd < 0) { slot = i; break; }
        if (slot < 0) close(fd);
        else {
            fcntl(fd, F_SETFL, O_NONBLOCK);
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
            cl[slot].fd = fd; cl[slot].ws = 0; cl[slot].len = 0; cl[slot].pad = 0;
        }
    }

    for (int i = 0; i < MAX_CL; i++) {
        if (cl[i].fd < 0) continue;
        int space = (int)sizeof cl[i].in - cl[i].len - 1;
        if (space <= 0) { cl_close(i); continue; }
        int n = recv(cl[i].fd, cl[i].in + cl[i].len, space, 0);
        if (n == 0) { cl_close(i); continue; }
        if (n < 0) { if (errno != EAGAIN && errno != EWOULDBLOCK) cl_close(i); continue; }
        cl[i].len += n;
        cl[i].in[cl[i].len] = 0;
        if (!cl[i].ws) {
            if (!strstr(cl[i].in, "\r\n\r\n")) continue;   /* заголовки не целиком */
            if (strcasestr(cl[i].in, "Upgrade: websocket")) handshake(i);
            else serve_page(i);
        } else {
            ws_frames(i);
        }
    }
}

/* Состояние кнопок игрока: 0 - первый, 1 - второй. */
int pad_net_state(int player)
{
    if (player < 0 || player >= MAX_CL) return 0;
    return (cl[player].fd >= 0 && cl[player].ws) ? cl[player].pad : 0;
}

void pad_net_stop(void)
{
    for (int i = 0; i < MAX_CL; i++) cl_close(i);
    if (srv_fd >= 0) close(srv_fd);
    srv_fd = -1;
}

/* ---- служба ----
   Живёт отдельно от эмулятора: оболочка поднимает её при входе в список игр и
   гасит при выходе в меню. Раньше сервер был внутри эмулятора и умирал вместе
   с игрой - код на экране настроек показать было можно, а подключиться по нему
   уже нельзя: сервера в этот момент не существовало. */
int main(void)
{
    int fd, last_run = -1;

    signal(SIGPIPE, SIG_IGN);
    if (pad_net_init() <= 0) {
        fprintf(stderr, "almond3s-pad: порт %d занят\n", PAD_PORT);
        return 1;
    }
    fd = open(PAD_STATE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror(PAD_STATE); return 1; }

    for (;;) {
        unsigned char b[2];

        pad_net_poll();

        b[0] = (unsigned char)pad_net_state(0);
        b[1] = (unsigned char)pad_net_state(1);
        (void)!pwrite(fd, b, sizeof b, 0);

        snd_pump();

        game_running = (access(PAD_RUN, F_OK) == 0);
        if (game_running != last_run) {
            last_run = game_running;
            for (int i = 0; i < MAX_CL; i++) pad_status_send(i);
        }

        usleep(4000);   /* 250 Гц: пульту с запасом, процессору незаметно */
    }
}
