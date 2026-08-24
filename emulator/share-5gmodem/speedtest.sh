#!/bin/sh
# Мост эмулятора: start/stop пересылаются серверу, тот выполняет настоящий
# /usr/share/5gmodem/speedtest.sh на выбранном живом роутере по ssh.
curl -s -m 3 -X POST --data "$1" http://127.0.0.1:8380/spd >/dev/null 2>&1 &
exit 0
