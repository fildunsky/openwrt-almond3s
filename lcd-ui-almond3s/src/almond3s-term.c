/*
 * almond3s-term — headless-мозг LCD-терминала.
 *
 * forkpty() запускает шелл (ash) на настоящем PTY, так что программы видят
 * терминал (`ls` даёт колонки, работает редактирование строки, top/vi и т.д.).
 * Поток вывода PTY разбирает libvterm (эталонный VT220/xterm-эмулятор), а мы
 * лишь снимаем его сетку ячеек в текстовый файл /tmp/.almond3s_term_grid.
 * Рисует сетку сам ui.uc (переиспользует наш рендер, шапку и экранную
 * клавиатуру) — демон на LCD ничего не пишет.
 * Ввод и управление — строками через fifo /tmp/.almond3s_term_in:
 *   обычные байты  -> пишутся в PTY (нажатия клавиш);
 *   "\x01r<cols>x<rows>\n" -> изменить размер окна (клава скрыта/показана);
 *   "\x01q\n"              -> выход.
 *
 * Зависимости: libc (forkpty из libutil/musl) и вкомпилированная libvterm.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <pty.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include "vterm.h"

#define MAXCOLS 53
#define MAXROWS 24
#define SB_MAX     400   /* строк истории (scrollback) */
#define EXPORT_MAX 200   /* сколько строк (история+экран) отдаём в grid */

static const char *GRID = "/tmp/.almond3s_term_grid";
static const char *FIFO = "/tmp/.almond3s_term_in";
static const char *PIDF = "/tmp/.almond3s_term.pid";

/* Кольцо истории: строки, ушедшие вверх за верх экрана (sb_pushline). ui.uc
 * листает их, когда клава скрыта. Каждая строка - ASCII, дополнена пробелами. */
static char sb[SB_MAX][MAXCOLS];
static int  sb_head = 0, sb_n = 0;

static int  cols = MAXCOLS, rows = 8; /* стартуем с клавой на экране (8 строк) */
static int  master = -1;

static VTerm      *vt;
static VTermScreen *vts;
static VTermState  *vtstate;

/* libvterm просит записать байты обратно в терминал (ответы на запросы курсора,
 * device attributes и т.п.) — отправляем их шеллу в master. */
static void out_cb(const char *s, size_t len, void *user)
{
    (void)user;
    if (master >= 0) (void)!write(master, s, len);
}

/* ячейки libvterm -> строка ASCII (не-ASCII '?'), добита пробелами до MAXCOLS */
static void cells_to_line(int ncols, const VTermScreenCell *cells, char *out)
{
    int w = ncols < MAXCOLS ? ncols : MAXCOLS;
    for (int x = 0; x < w; x++) {
        uint32_t c = cells[x].chars[0];
        out[x] = (cells[x].width > 0 && c >= 32 && c < 127) ? (char)c
               : (cells[x].width > 0 && c != 0 ? '?' : ' ');
    }
    for (int x = w; x < MAXCOLS; x++) out[x] = ' ';
}

/* строка ушла вверх за верх экрана -> в кольцо истории */
static int sb_pushline_cb(int ncols, const VTermScreenCell *cells, void *user)
{
    (void)user;
    int idx = (sb_head + sb_n) % SB_MAX;
    cells_to_line(ncols, cells, sb[idx]);
    if (sb_n < SB_MAX) sb_n++;
    else sb_head = (sb_head + 1) % SB_MAX;
    return 1;
}

/* Окно выросло (скрыли клаву) - libvterm просит вернуть строку истории в низ
 * экрана. Без этого рост окна давал пустоту снизу, а вывод оставался вверху.
 * Цвета не восстанавливаем - наш экспорт всё равно берёт только символ. */
static int sb_popline_cb(int ncols, VTermScreenCell *cells, void *user)
{
    (void)user;
    if (sb_n == 0) return 0;
    int idx = (sb_head + sb_n - 1) % SB_MAX;
    sb_n--;
    for (int x = 0; x < ncols; x++) {
        cells[x] = (VTermScreenCell){ 0 };
        cells[x].width = 1;
        cells[x].chars[0] = (x < MAXCOLS) ? (uint32_t)(unsigned char)sb[idx][x] : ' ';
    }
    return 1;
}

static void write_trimmed(int fd, const char *line)
{
    int end = MAXCOLS;
    while (end > 0 && line[end - 1] == ' ') end--;
    (void)!write(fd, line, end);
    (void)!write(fd, "\n", 1);
}

/* --- экспорт для ui.uc: заголовок "nlines cols cur_x cur_line", затем
 * последние строки истории и текущий экран. ui.uc рисует окно нужной высоты с
 * прокруткой; cur_line - строка курсора в общем буфере. --- */
static void export_grid(void)
{
    char tmp[80];
    snprintf(tmp, sizeof(tmp), "%s.tmp", GRID);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;

    VTermPos cpos;
    vterm_state_get_cursorpos(vtstate, &cpos);

    int sb_inc = sb_n;
    if (sb_inc > EXPORT_MAX - rows) sb_inc = EXPORT_MAX - rows;
    if (sb_inc < 0) sb_inc = 0;
    int nlines = sb_inc + rows;
    int cur_line = sb_inc + cpos.row;

    char hdr[48];
    int n = snprintf(hdr, sizeof(hdr), "%d %d %d %d\n", nlines, cols, cpos.col, cur_line);
    (void)!write(fd, hdr, n);

    for (int i = sb_n - sb_inc; i < sb_n; i++)
        write_trimmed(fd, sb[(sb_head + i) % SB_MAX]);

    char line[MAXCOLS];
    for (int y = 0; y < rows; y++) {
        for (int x = 0; x < MAXCOLS; x++) {
            char ch = ' ';
            if (x < cols) {
                VTermScreenCell cell;
                VTermPos p = { .row = y, .col = x };
                if (vterm_screen_get_cell(vts, p, &cell) && cell.width > 0) {
                    uint32_t c = cell.chars[0];
                    ch = (c >= 32 && c < 127) ? (char)c : (c == 0 ? ' ' : '?');
                }
            }
            line[x] = ch;
        }
        write_trimmed(fd, line);
    }
    close(fd);
    rename(tmp, GRID);
}

/* --- изменение размера окна --- */
static void set_size(int c, int r)
{
    if (c < 8) c = 8; if (c > MAXCOLS) c = MAXCOLS;
    if (r < 2) r = 2; if (r > MAXROWS) r = MAXROWS;
    cols = c; rows = r;
    vterm_set_size(vt, rows, cols);
    struct winsize ws = { .ws_row = (unsigned short)r, .ws_col = (unsigned short)c };
    if (master >= 0) ioctl(master, TIOCSWINSZ, &ws);
}

// killall (SIGTERM) от ui.uc/term_stop: чистим pidfile и fifo, чтобы не остался
// осиротевший fifo (в него бы завис писатель) и стухший pidfile.
static void on_term(int s)
{
    (void)s;
    unlink(FIFO);
    unlink(PIDF);
    _exit(0);
}

int main(void)
{
    signal(SIGCHLD, SIG_DFL);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_term);
    signal(SIGHUP,  on_term);

    vt = vterm_new(rows, cols);
    vterm_set_utf8(vt, 1);
    vterm_output_set_callback(vt, out_cb, NULL);
    vts = vterm_obtain_screen(vt);
    vtstate = vterm_obtain_state(vt);
    static VTermScreenCallbacks screen_cbs;   /* переживает вызов - libvterm хранит указатель */
    screen_cbs.sb_pushline = sb_pushline_cb;
    screen_cbs.sb_popline  = sb_popline_cb;
    vterm_screen_set_callbacks(vts, &screen_cbs, NULL);
    vterm_screen_enable_altscreen(vts, 1);
    vterm_screen_reset(vts, 1);

    struct winsize ws = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols };
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) { perror("forkpty"); return 1; }
    if (pid == 0) {
        setenv("TERM", "xterm", 1);
        setenv("HOME", "/root", 1);
        chdir("/root");
        execl("/bin/ash", "ash", (char *)NULL);
        execl("/bin/sh", "sh", (char *)NULL);
        _exit(127);
    }

    // pidfile: по нему ui.uc проверяет живость демона через /proc, чтобы не
    // писать в fifo мёртвого (открытие на запись без читателя вешает писателя).
    {
        char pb[16];
        int n = snprintf(pb, sizeof(pb), "%d\n", (int)getpid());
        int pf = open(PIDF, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (pf >= 0) { (void)!write(pf, pb, n); close(pf); }
    }

    // Enter шлём как настоящий CR (\r). Чтобы шелл в каноническом режиме
    // сабмитил строку по CR, включаем ICRNL (CR->NL) на слейве. Приложения в
    // raw-режиме (nano, vi) при этом видят именно \r - как в настоящем
    // терминале (без этого «OK» в диалогах nano не срабатывал).
    {
        struct termios tio;
        if (tcgetattr(master, &tio) == 0) {
            tio.c_iflag |= ICRNL;
            tcsetattr(master, TCSANOW, &tio);
        }
    }

    fcntl(master, F_SETFL, O_NONBLOCK);
    unlink(FIFO);
    mkfifo(FIFO, 0600);
    /* r+ чтобы open не блокировался и fifo не давал EOF при отвале писателя */
    int fifo = open(FIFO, O_RDWR | O_NONBLOCK);
    if (fifo < 0) { perror("fifo"); }

    export_grid();

    struct pollfd pfd[2];
    pfd[0].fd = master; pfd[0].events = POLLIN;
    pfd[1].fd = fifo;   pfd[1].events = POLLIN;

    char ibuf[512];
    int dirty = 0;

    for (;;) {
        int status;
        if (waitpid(pid, &status, WNOHANG) == pid) break;   /* шелл вышел */

        int pr = poll(pfd, fifo >= 0 ? 2 : 1, 50);
        if (pr < 0 && errno != EINTR) break;

        if (pfd[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            int n = read(master, ibuf, sizeof(ibuf));
            if (n > 0) {
                vterm_input_write(vt, ibuf, n);
                dirty = 1;
            } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                break;   /* шелл вышел / ошибка - не крутим цикл вхолостую */
            }
        }
        if (fifo >= 0 && (pfd[1].revents & POLLIN)) {
            int n = read(fifo, ibuf, sizeof(ibuf));
            for (int i = 0; i < n; i++) {
                if ((unsigned char)ibuf[i] == 0x01) {
                    /* управляющая строка до \n */
                    char cmd[40]; int cl = 0;
                    i++;
                    while (i < n && ibuf[i] != '\n' && cl < (int)sizeof(cmd) - 1)
                        cmd[cl++] = ibuf[i++];
                    cmd[cl] = 0;
                    if (cmd[0] == 'q') { kill(pid, SIGHUP); goto done; }
                    if (cmd[0] == 'r') {
                        int c = 0, r = 0; sscanf(cmd + 1, "%dx%d", &c, &r);
                        set_size(c, r); dirty = 1;
                    }
                } else {
                    /* Пишем байт как есть, включая CR: ICRNL на слейве сам
                     * переведёт CR->NL для шелла, а raw-приложения увидят \r. */
                    (void)!write(master, &ibuf[i], 1);   /* нажатие в PTY */
                }
            }
        }
        if (dirty) { export_grid(); dirty = 0; }
    }
done:
    export_grid();
    unlink(FIFO);
    unlink(PIDF);
    vterm_free(vt);
    return 0;
}
