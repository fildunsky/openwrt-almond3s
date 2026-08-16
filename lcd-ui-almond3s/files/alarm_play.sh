#!/bin/sh
# alarm_play.sh — запускается кроном РОВНО в заданное время (запись ставит
# alarm_set.sh). Играет выбранную мелодию; при repeat>0 доигрывает каждые N
# минут в фоне (снуз) в пределах окна; режим once сам убирает cron-запись, чтобы
# завтра не звонить. Остановить звон: alarm_stop.sh (его зовёт UI при ВЫКЛ).
CFG=almond3s
WINDOW=60                       # предел снуз-повтора, минут
SNOOZE_PID=/tmp/.alarm_snooze.pid
DISMISS=/tmp/.alarm_dismiss

[ "$(uci -q get $CFG.alarm.enabled)" = "1" ] || exit 0

snd=$(uci -q get $CFG.alarm.sound);   args=$(uci -q get $CFG.alarm.sound_args)
vol=$(uci -q get $CFG.alarm.volume);  [ -n "$vol" ] || vol=2
rep=$(uci -q get $CFG.alarm.repeat);  [ -n "$rep" ] || rep=0
mode=$(uci -q get $CFG.alarm.mode)

play() {
    k=$(cat /tmp/.lcd_tone.pid 2>/dev/null); [ -n "$k" ] && kill "$k" 2>/dev/null
    almond3s-lcd stop >/dev/null 2>&1
    # shellcheck disable=SC2086
    almond3s-lcd "$snd" -v "$vol" $args >/dev/null 2>&1 &
}

rm -f "$DISMISS"
play

# Разово: снимаем свою cron-запись и гасим флаг enabled (сегодня отзвонит, а
# завтра уже нет). Снуз-цикл ниже это не трогает - он идёт по флагу DISMISS.
if [ "$mode" = "once" ]; then
    uci -q set $CFG.alarm.enabled='0'; uci -q commit $CFG
    /etc/almond3s/scripts/alarm_set.sh >/dev/null 2>&1
fi

# Снуз: повтор каждые rep минут, пока не сброшено (alarm_stop.sh) или окно не вышло.
if [ "$rep" != "0" ]; then
    (
        i=0; max=$((WINDOW / rep))
        while [ "$i" -lt "$max" ]; do
            sleep $((rep * 60))
            [ -f "$DISMISS" ] && break
            play
            i=$((i + 1))
        done
        rm -f "$SNOOZE_PID"
    ) &
    echo $! > "$SNOOZE_PID"
fi
exit 0
