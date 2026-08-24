#!/bin/sh
# Пробросчик эмулятора: netpri.sh исполняется на живом роутере (5gmodem).
[ -x /tmp/almond3s-emu/rsh ] || exit 1
exec /tmp/almond3s-emu/rsh "/usr/share/5gmodem/netpri.sh $*"
