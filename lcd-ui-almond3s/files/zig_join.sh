#!/bin/sh
# Вступление в сеть. Аргументы: ключ [PAN] [канал].
#
# Порядок: сначала выходим из старой сети (иначе чип отвечает на join ошибкой
# «недопустимый вызов» и молча остаётся где был), потом ищем в эфире нужную.
# Если PAN задан - вступаем ИМЕННО в него: раньше скрипт брал первую попавшуюся
# сеть из скана и затирал ею конфиг, из-за чего набранный вручную PAN пропадал.
# Ключ больше не обязателен: сетевой ключ выдаёт координатор, у нас на руках
# только общеизвестный link-ключ стандарта.
Z=/usr/libexec/almond3s/almond3s-zig
KEY="$1"
PAN="${2:-0}"
CH="${3:-0}"
OUT=/tmp/lcd_zig_join.json

$Z leave >/dev/null 2>&1

SCAN=$($Z ascan 5 2>/dev/null | tail -1)

if [ "$PAN" != "0" ]; then
	# ищем среди найденных сеть с нужным PAN
	FCH=""
	i=0
	while [ $i -lt 8 ]; do
		P=$(echo "$SCAN" | jsonfilter -e "@.networks[$i].pan" 2>/dev/null)
		[ -z "$P" ] && break
		if [ "$P" = "$PAN" ]; then
			FCH=$(echo "$SCAN" | jsonfilter -e "@.networks[$i].ch" 2>/dev/null)
			break
		fi
		i=$((i+1))
	done
	if [ -n "$FCH" ]; then
		CH="$FCH"
	else
		# сети с таким PAN в эфире нет - вступать некуда
		echo '{"ok":0,"stack":171,"pan":'"$PAN"'}' > "$OUT"
		$Z state > /tmp/lcd_zig_state.json 2>/dev/null
		exit 0
	fi
else
	FPAN=$(echo "$SCAN" | jsonfilter -e '@.networks[0].pan' 2>/dev/null)
	FCH=$(echo "$SCAN" | jsonfilter -e '@.networks[0].ch' 2>/dev/null)
	if [ -n "$FPAN" ] && [ "$FPAN" != "0" ]; then
		PAN="$FPAN"
		CH="$FCH"
	fi
fi

$Z join "$PAN" "$CH" "$KEY" > "$OUT" 2>/dev/null
$Z state > /tmp/lcd_zig_state.json 2>/dev/null
