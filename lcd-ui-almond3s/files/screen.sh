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

# Без работающего lcd_ui запрос никто не подхватит - тогда дёргаем светодиод
# подсветки напрямую, иначе команда молча ничего не сделает.
# Имя светодиода зависит от DTS (без цвета «:power», с белым «white:power»),
# поэтому ищем маской, а не по списку.
LED=""
for l in /sys/class/leds/*power/brightness /sys/class/leds/*power*/brightness; do
	[ -e "$l" ] && { LED="$l"; break; }
done

direct() {
	[ -n "$LED" ] || return 1
	case "$1" in
		on)  echo 1 > "$LED" ;;
		off) echo 0 > "$LED" ;;
		toggle)
			[ "$(cat "$LED")" = "0" ] && echo 1 > "$LED" || echo 0 > "$LED"
			;;
	esac
}

case "$1" in
	on|off|toggle)
		if pgrep -f lcd_ui.uc >/dev/null 2>&1; then
			printf '%s' "$1" > "$REQ"
		else
			direct "$1"
		fi
		;;
	*)
		echo "usage: screen.sh on|off|toggle" >&2
		exit 1
		;;
esac
