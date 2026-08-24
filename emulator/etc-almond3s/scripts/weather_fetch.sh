#!/bin/sh
# weather_fetch.sh — caches current weather for lcd_ui dashboard
#
# Провайдер выбирается в UCI (переключатель на экране выбора города):
#   almond3s.weather.provider = openmeteo (по умолчанию) | wttr
#
# Open-Meteo (по умолчанию): бесплатный, без ключа, надёжный, current + WMO code.
# wttr.in: оставлен опцией, НО его апстрим WWO периодически застревает и отдаёт
# битый снимок на весь мир (ловили зиму в августе 17.08.2026) - поэтому не дефолт.
# Условие в ОБОИХ случаях берём по-английски и переводим таблицей WCOND_RU в
# ui.uc (иконку ловит weather_icon_key). См. память almond3s-weather-wttr-lang-cache.
#
# Schedule (every 15 min) — /etc/crontabs/root:
#   */15 * * * * /etc/almond3s/scripts/weather_fetch.sh

# WCITY/WLAT/WLON/WNAME из env: ui.uc передаёт их напрямую при смене города, т.к.
# ucur.commit не сразу виден фоновому процессу (фетч успевал прочитать СТАРЫЙ
# город - баг «открылся Воронеж»). Cron зовёт без env - берёт из uci.
CITY="${WCITY:-${CITY:-$(uci -q get almond3s.weather.city)}}"
[ -n "$CITY" ] || CITY="$(uci -q get lcd.weather.city)"
[ -n "$CITY" ] || CITY="Moscow"
PROVIDER=$(uci -q get almond3s.weather.provider)
[ -n "$PROVIDER" ] || PROVIDER="openmeteo"

OUT="/tmp/lcd_weather.txt"
TMP="/tmp/lcd_weather.txt.tmp"
GEO="/tmp/lcd_weather.geo"   # кэш координат Open-Meteo: "city<TAB>lat<TAB>lon"

# Имя на экране берём из CITY (ASCII), не из ответа API.
DISPLAY_CITY=$(printf '%s' "$CITY" | tr -cd '\11\12\15\40-\176')

# curl (http1.1 обязателен: сборка виснет по HTTP/2), фолбэк на wget. -k/-f.
. /etc/almond3s/scripts/netfetch.sh

fetch() {
	nf_fetch "$1" 8
}

if [ "$PROVIDER" = wttr ]; then
    # --- wttr.in: без &lang (единый кэш-ключ), условие по-английски ---
    CU=$(printf '%s' "$CITY" | tr ' ' '+')
    R=$(fetch "https://wttr.in/${CU}?format=%C|%t|%f|%h|%w&m")
    [ -n "$R" ] || exit 0
    # R уже "cond|temp|feels|hum|wind"; дописываем город шестым полем.
    printf '%s|%s\n' "$R" "$DISPLAY_CITY" > "$TMP"
else
    # --- Open-Meteo: координаты + current-погода ---
    LAT=""; LON=""; NM=""
    # Закреплённый выбор из пикера (при неоднозначности): координаты в uci -
    # используем их напрямую, без геокода. Переживает ребут (в отличие от /tmp).
    ULAT="${WLAT-$(uci -q get almond3s.weather.lat)}"
    ULON="${WLON-$(uci -q get almond3s.weather.lon)}"
    if [ -n "$ULAT" ] && [ -n "$ULON" ]; then
        LAT="$ULAT"; LON="$ULON"
        NM="${WNAME-$(uci -q get almond3s.weather.name)}"
    else
        # Пресет/без выбора: геокодим имя (топ-совпадение), кэшируем координаты.
        if [ -f "$GEO" ] && [ "$(cut -f1 "$GEO")" = "$CITY" ]; then
            LAT=$(cut -f2 "$GEO"); LON=$(cut -f3 "$GEO"); NM=$(cut -f4 "$GEO")
        fi
        if [ -z "$LAT" ] || [ -z "$LON" ]; then
            CU=$(printf '%s' "$CITY" | tr ' ' '+')
            # language=ru -> локализованное имя («Ишим», «Москва») для показа.
            G=$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=1&language=ru&format=json")
            LAT=$(printf '%s' "$G" | jsonfilter -e '@.results[0].latitude' 2>/dev/null)
            LON=$(printf '%s' "$G" | jsonfilter -e '@.results[0].longitude' 2>/dev/null)
            NM=$(printf  '%s' "$G" | jsonfilter -e '@.results[0].name' 2>/dev/null | tr -d '|')
            [ -n "$LAT" ] && [ -n "$LON" ] && printf '%s\t%s\t%s\t%s\n' "$CITY" "$LAT" "$LON" "$NM" > "$GEO"
        fi
    fi
    [ -n "$LAT" ] && [ -n "$LON" ] || exit 0
    # Показываем локализованное имя; если его нет - введённую строку.
    [ -n "$NM" ] && DISPLAY_CITY="$NM"

    W=$(fetch "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,weather_code")
    [ -n "$W" ] || exit 0

    T=$(printf  '%s' "$W" | jsonfilter -e '@.current.temperature_2m' 2>/dev/null)
    F=$(printf  '%s' "$W" | jsonfilter -e '@.current.apparent_temperature' 2>/dev/null)
    H=$(printf  '%s' "$W" | jsonfilter -e '@.current.relative_humidity_2m' 2>/dev/null)
    WS=$(printf '%s' "$W" | jsonfilter -e '@.current.wind_speed_10m' 2>/dev/null)
    WD=$(printf '%s' "$W" | jsonfilter -e '@.current.wind_direction_10m' 2>/dev/null)
    WC=$(printf '%s' "$W" | jsonfilter -e '@.current.weather_code' 2>/dev/null)
    [ -n "$T" ] || exit 0
    [ -n "$F" ] || F="$T"

    # WMO weather_code -> английский статус словаря WCOND_RU/weather_icon_key.
    case "$WC" in
        0|1)   COND="Sunny" ;;
        2)     COND="Partly cloudy" ;;
        3)     COND="Overcast" ;;
        45)    COND="Fog" ;;
        48)    COND="Freezing fog" ;;
        51|53) COND="Light drizzle" ;;
        55)    COND="Heavy freezing drizzle" ;;
        56)    COND="Freezing drizzle" ;;
        57)    COND="Heavy freezing drizzle" ;;
        61)    COND="Light rain" ;;
        63)    COND="Moderate rain" ;;
        65)    COND="Heavy rain" ;;
        66)    COND="Light freezing rain" ;;
        67)    COND="Moderate or heavy freezing rain" ;;
        71|77) COND="Light snow" ;;
        73)    COND="Moderate snow" ;;
        75)    COND="Heavy snow" ;;
        80)    COND="Light rain shower" ;;
        81)    COND="Moderate or heavy rain shower" ;;
        82)    COND="Torrential rain shower" ;;
        85)    COND="Light snow showers" ;;
        86)    COND="Moderate or heavy snow showers" ;;
        95)    COND="Thundery outbreaks possible" ;;
        96|99) COND="Moderate or heavy rain with thunder" ;;
        *)     COND="Cloudy" ;;
    esac

    # Числа -> те же строки, что даёт wttr.in (UI рисует их как есть).
    TEMP=$(awk  -v v="$T"  'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$F"  'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$H"  'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$WS" 'BEGIN{printf "%.0f", v}')
    ARROW=$(awk -v d="$WD" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        to=(d+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$COND" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"
fi

# Sanity: ровно 6 полей — иначе не подменяем рабочий кэш.
fields=$(awk -F'|' '{print NF}' "$TMP" 2>/dev/null)
if [ -n "$fields" ] && [ "$fields" -ge 6 ]; then
    mv "$TMP" "$OUT"
else
    rm -f "$TMP"
fi
