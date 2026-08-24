#!/bin/sh
[ -x /tmp/almond3s-emu/rsh ] || exit 0
exec /tmp/almond3s-emu/rsh "/etc/almond3s/scripts/lte_reset.sh >/dev/null 2>&1 &"
