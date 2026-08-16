#!/bin/sh
# alarm_stop.sh — гасит звонящий будильник: обрывает снуз-цикл и текущий тон.
# Зовётся из UI при выключении будильника.
touch /tmp/.alarm_dismiss
p=$(cat /tmp/.alarm_snooze.pid 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
rm -f /tmp/.alarm_snooze.pid
k=$(cat /tmp/.lcd_tone.pid 2>/dev/null); [ -n "$k" ] && kill "$k" 2>/dev/null
almond3s-lcd stop >/dev/null 2>&1
exit 0
