/*
 * pad_file.cpp - сторона эмулятора для пульта в браузере.
 *
 * Сам сервер вынесен в отдельную службу almond3s-pad: он живёт дольше игры,
 * поэтому подключиться с телефона можно ещё в списке игр, а соединение не
 * рвётся при выходе из игры и запуске следующей. Здесь остаётся только чтение
 * состояния кнопок - один pread на кадр, как у тачскрина.
 */

#include <fcntl.h>
#include <unistd.h>

#define PAD_STATE "/tmp/.nes_pad"
#define PAD_RUN   "/tmp/.nes_run"

static int pad_fd = -1;
static int run_fd = -1;
static unsigned char pad_val[2];

int pad_net_init(void)
{
    /* Флаг «игра идёт» - по нему служба говорит телефону, ждать ему или
       играть. Создаём пустым, снимаем при выходе. */
    run_fd = open(PAD_RUN, O_WRONLY | O_CREAT | O_TRUNC, 0644);

    pad_fd = open(PAD_STATE, O_RDONLY);
    return pad_fd >= 0 ? 1 : 0;   /* службы может и не быть - это не беда */
}

void pad_net_poll(void)
{
    unsigned char b[2];

    /* Служба могла подняться позже нас - пробуем открыть, пока не выйдет. */
    if (pad_fd < 0) {
        pad_fd = open(PAD_STATE, O_RDONLY);
        if (pad_fd < 0) return;
    }
    if (pread(pad_fd, b, sizeof b, 0) == (long)sizeof b) {
        pad_val[0] = b[0];
        pad_val[1] = b[1];
    }
}

int pad_net_state(int player)
{
    if (player < 0 || player > 1) return 0;
    return pad_val[player];
}

void pad_net_stop(void)
{
    if (pad_fd >= 0) { close(pad_fd); pad_fd = -1; }
    if (run_fd >= 0) { close(run_fd); run_fd = -1; }
    unlink(PAD_RUN);
}
