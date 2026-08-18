#!/bin/sh
# Ночное выключение Wi-Fi.
#
# Гасим ТОЛЬКО точки доступа. Клиентское подключение (mode=sta) не трогаем:
# роутер может сам сидеть в чужой сети по Wi-Fi - на этом стенде так и есть, -
# и «wifi down» оставил бы его на ночь вообще без сети, без времени по NTP и
# без туннелей.
#
# Запоминаем ИМЕННО те интерфейсы, которые погасили мы. Иначе утром мы включили
# бы и те, что хозяин выключил сам.

STATE=/etc/almond3s/night_wifi_off

case "$1" in
off)
	[ -s "$STATE" ] && exit 0          # уже погашено, второй раз не трогаем
	list=""
	for s in $(uci show wireless 2>/dev/null | \
	           sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
		[ "$(uci -q get wireless.$s.mode)" = "ap" ] || continue
		[ "$(uci -q get wireless.$s.disabled)" = "1" ] && continue
		uci set wireless.$s.disabled=1
		list="$list $s"
	done
	[ -z "$list" ] && exit 0
	echo "$list" > "$STATE"
	uci commit wireless
	wifi reload
	;;
on)
	[ -s "$STATE" ] || exit 0
	for s in $(cat "$STATE"); do
		uci -q set wireless.$s.disabled=0
	done
	rm -f "$STATE"
	uci commit wireless
	wifi reload
	;;
*)
	echo "использование: night_wifi.sh off|on" >&2
	exit 1
	;;
esac
