#!/bin/sh
# weather_geo.sh "<city>" — поиск города в геокодере Open-Meteo. Кладёт сырой JSON
# совпадений в /tmp/lcd_geo.json для пикера выбора в ui.uc (при неоднозначности -
# «две Москвы»). Зовётся из ui.uc в фоне; ui.uc парсит JSON сам (json()).
NAME="$1"
OUT="/tmp/lcd_geo.json"; TMP="$OUT.tmp"
[ -n "$NAME" ] || { echo '{"results":[]}' > "$OUT"; exit 0; }
CU=$(printf '%s' "$NAME" | tr ' ' '+')
URL="https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=6&language=ru&format=json"

R=""
if command -v curl >/dev/null 2>&1; then
    R=$(curl --http1.1 -k -s -f --max-time 15 "$URL")
fi
[ -n "$R" ] || R=$(wget --no-check-certificate -q -T 15 -O - "$URL")
[ -n "$R" ] || R='{"results":[]}'
printf '%s' "$R" > "$TMP" && mv "$TMP" "$OUT"
