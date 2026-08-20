#!/bin/sh
# Вступление в сеть: сперва ищем её в эфире, чтобы не заставлять человека
# вручную совпадать по PAN и каналу. Аргументы: ключ [PAN] [канал].
Z=/usr/libexec/almond3s/almond3s-zig
KEY="$1"
PAN="${2:-0}"
CH="${3:-0}"
OUT=/tmp/lcd_zig_join.json

SCAN=$($Z ascan 5 2>/dev/null | tail -1)
FPAN=$(echo "$SCAN" | jsonfilter -e '@.networks[0].pan' 2>/dev/null)
FCH=$(echo "$SCAN" | jsonfilter -e '@.networks[0].ch' 2>/dev/null)

if [ -n "$FPAN" ] && [ "$FPAN" != "0" ]; then
	PAN="$FPAN"
	CH="$FCH"
	uci set almond3s.zigbee.pan="$PAN"
	uci set almond3s.zigbee.channel="$CH"
	uci commit almond3s
fi

$Z join "$PAN" "$CH" "$KEY" > "$OUT" 2>/dev/null
$Z state > /tmp/lcd_zig_state.json 2>/dev/null
