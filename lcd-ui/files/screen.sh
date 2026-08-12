#!/bin/sh
#
# screen.sh on|off|toggle - погасить или зажечь экран.
#
# Сами по себе ioctl'ы дёргать нельзя: lcd_ui продолжит рисовать в погашенный
# экран, будет впустую гонять шину и не проснётся по тапу. Поэтому пишем
# запрос файлом, а состоянием владеет lcd_ui - он подхватывает запрос за 100 мс.
#
# Вешается на любую кнопку, у которой есть события:
#   /etc/rc.button/tamper
#   [ "$ACTION" = released ] && [ "$SEEN" -lt 2 ] && /etc/lcd/scripts/screen.sh toggle

REQ=/tmp/lcd_screen_req

case "$1" in
	on|off|toggle)
		printf '%s' "$1" > "$REQ"
		;;
	*)
		echo "usage: screen.sh on|off|toggle" >&2
		exit 1
		;;
esac
