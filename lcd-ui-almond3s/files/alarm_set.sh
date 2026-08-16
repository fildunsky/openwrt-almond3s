#!/bin/sh
# alarm_set.sh — приводит cron-запись будильника в соответствие с конфигом.
# Вызывается из UI при сохранении/переключении и из postinst. enabled=1 ставит
# запись «<мин> <час> * * * alarm_play.sh» (крон сам разбудит скрипт ровно в
# заданное время - никакого поминутного опроса), enabled=0 её убирает.
CFG=almond3s
CRON=/etc/crontabs/root
MARK='# almond3s-alarm'

[ -f "$CRON" ] || { mkdir -p /etc/crontabs; : > "$CRON"; }
# Снять прежнюю запись будильника (ищем по маркеру).
sed -i "\|$MARK|d" "$CRON" 2>/dev/null

if [ "$(uci -q get $CFG.alarm.enabled)" = "1" ]; then
    h=$(uci -q get $CFG.alarm.hour);   m=$(uci -q get $CFG.alarm.minute)
    [ -n "$h" ] || h=7; [ -n "$m" ] || m=0
    echo "$m $h * * * /etc/almond3s/scripts/alarm_play.sh $MARK" >> "$CRON"
fi
/etc/init.d/cron reload >/dev/null 2>&1
exit 0
