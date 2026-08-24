#!/bin/sh
[ -x /tmp/almond3s-emu/rsh ] || exit 1
exec /tmp/almond3s-emu/rsh "sh -s -- $*" < /etc/almond3s/scripts/vpn_clash.real.sh
