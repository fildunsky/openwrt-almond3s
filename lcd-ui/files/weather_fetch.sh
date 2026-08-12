#!/bin/sh
# weather_fetch.sh — caches current weather for lcd_ui dashboard
#
# Install:
#   scp weather_fetch.sh root@192.168.11.1:/etc/lcd/scripts/weather_fetch.sh
#   ssh root@192.168.11.1 chmod +x /etc/lcd/scripts/weather_fetch.sh
#
# Schedule (every 15 min) — add to /etc/crontabs/root:
#   */15 * * * * /etc/lcd/scripts/weather_fetch.sh
# then: /etc/init.d/cron restart
#
# Run once manually after install so the dashboard has data immediately:
#   /etc/lcd/scripts/weather_fetch.sh

# Город берётся из UCI, чтобы менять его не правкой скрипта:
#   uci set lcd.weather.city='Saint Petersburg'; uci commit lcd
# Значение из конфига перекрывается переменной окружения CITY (для проверок).
CITY="${CITY:-$(uci -q get lcd.weather.city)}"
[ -n "$CITY" ] || CITY="Moscow"
OUT="/tmp/lcd_weather.txt"
TMP="/tmp/lcd_weather.txt.tmp"

# Custom one-line format instead of the huge format=j1 JSON (which can be
# 15-30KB and time out on a slow/LTE link). Fields, pipe-separated:
#   condition | temp | feels-like | humidity | wind
# &m forces metric units.
# Пробел в имени города («Saint Petersburg», «Nizhny Novgorod») уходил в URL
# как есть: curl отвечает 3 (кривой URL), wget - ошибкой разбора, и виджет
# молча оставался со старым городом. Заменяем пробелы на +.
CITY_URL=$(printf '%s' "$CITY" | tr ' ' '+')
# lang=ru: в lcd_render добавлена кириллическая страница шрифта, поэтому
# описание погоды можно брать по-русски («Небольшой дождь» вместо
# «Light rain shower»).
# Язык описания берём тот же, что у интерфейса на экране.
LANG_UI=$(uci -q get lcd.display.lang)
[ "$LANG_UI" = en ] && WLANG="" || WLANG="&lang=ru"
URL="https://wttr.in/${CITY_URL}?format=%C|%t|%f|%h|%w&m${WLANG}"

# City name shown on the LCD is NOT taken from the API response — wttr.in
# doesn't return it in this format string anyway, and for some cities it
# only has the name transliterated/in the local language. We just reuse
# the CITY variable typed above, so lcd_ui.uc always shows exactly what
# was configured here, and there is only ONE place to edit the city name.
# Also ASCII-sanitized in case someone types it with non-Latin letters —
# same reason the weather fields get stripped below.
DISPLAY_CITY=$(printf '%s' "$CITY" | tr -cd '\11\12\15\40-\176')

rc=1
if command -v curl >/dev/null 2>&1; then
    # -k: router's CA bundle is missing/incomplete, skip cert verification
    # -f: treat HTTP errors as failure instead of saving an error page
    # --http1.1 ОБЯЗАТЕЛЕН: curl этой сборки (mbedTLS + nghttp2) на wttr.in
    # висит по HTTP/2 ровно до таймаута и возвращает 28, даже с -4.
    curl --http1.1 -k -s -f --max-time 15 "$URL" -o "$TMP"
    rc=$?
    # Падение curl - не приговор: wget на том же адресе отвечает всегда.
    [ "$rc" -ne 0 ] && { wget --no-check-certificate -q -T 15 -O "$TMP" "$URL"; rc=$?; }
else
    wget --no-check-certificate -q -T 15 -O "$TMP" "$URL"
    rc=$?
fi

if [ "$rc" -eq 0 ] && [ -s "$TMP" ]; then
    # Кириллицу теперь оставляем - её есть чем рисовать. Убираем только то,
    # чего в шрифте нет: знак градуса и стрелки направления ветра.
    sed -e 's/°//g' \
        -e 's/↑//g' -e 's/↓//g' -e 's/←//g' -e 's/→//g' \
        -e 's/↖//g' -e 's/↗//g' -e 's/↘//g' -e 's/↙//g' \
        < "$TMP" > "$TMP.clean" && mv "$TMP.clean" "$TMP"

    # Append the city name as field 6 (see DISPLAY_CITY above). Strip any
    # trailing newline from wttr.in's output first so we get one clean line.
    printf '%s' "$(cat "$TMP")" > "$TMP"
    printf '|%s\n' "$DISPLAY_CITY" >> "$TMP"

    # Sanity check: must have all 6 pipe-separated fields
    fields=$(awk -F'|' '{print NF}' "$TMP" 2>/dev/null)
    if [ -n "$fields" ] && [ "$fields" -ge 6 ]; then
        mv "$TMP" "$OUT"
    else
        rm -f "$TMP" "$TMP.ascii"
    fi
else
    rm -f "$TMP" "$TMP.ascii"
fi
