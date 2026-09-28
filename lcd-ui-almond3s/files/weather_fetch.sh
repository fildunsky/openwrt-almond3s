#!/bin/sh
# weather_fetch.sh — caches current weather for lcd_ui dashboard
#
# Провайдер выбирается в UCI (переключатель на экране выбора города):
#   almond3s.weather.provider = openmeteo (по умолчанию) | wttr | metno
#
# Open-Meteo (по умолчанию): бесплатный, без ключа, надёжный, current + WMO code.
# Его серверы стоят у Hetzner, у части провайдеров этот хостинг недоступен.
# met.no (Норвежский метеоинститут): тоже без ключа, запасной вариант на этот
# случай. Координаты берёт тем же геокодом Open-Meteo, а тот живёт на другом
# хостинге и режется реже.
# wttr.in: оставлен опцией, НО его апстрим WWO периодически застревает и отдаёт
# битый снимок на весь мир (ловили зиму в августе 17.08.2026) - поэтому не дефолт.
# Условие во ВСЕХ случаях берём по-английски и переводим таблицей WCOND_RU в
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
GEO="/tmp/lcd_weather.geo"   # кэш геокода: "city<TAB>lat<TAB>lon<TAB>name"

# Имя на экране - из CITY, пока геокод не даст локализованное. Рендерер рисует
# кириллицу, срезаем только перевод строки и разделитель полей кэша.
DISPLAY_CITY=$(printf '%s' "$CITY" | tr -d '\r\n|')

# curl (http1.1 обязателен: сборка виснет по HTTP/2), фолбэк на wget. -k/-f.
. /etc/almond3s/scripts/netfetch.sh

fetch() {
	nf_fetch "$1" 8
}

# Координаты города в LAT/LON/NM, общие для Open-Meteo и met.no.
# Закреплённый выбор из пикера (при неоднозначности): координаты в uci -
# используем их напрямую, без геокода. Переживает ребут (в отличие от /tmp).
# Пресет/без выбора: геокодим имя (топ-совпадение), кэшируем координаты.
geo_coords() {
    LAT=""; LON=""; NM=""
    ULAT="${WLAT-$(uci -q get almond3s.weather.lat)}"
    ULON="${WLON-$(uci -q get almond3s.weather.lon)}"
    if [ -n "$ULAT" ] && [ -n "$ULON" ]; then
        LAT="$ULAT"; LON="$ULON"
        NM="${WNAME-$(uci -q get almond3s.weather.name)}"
    else
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
    [ -n "$LAT" ] && [ -n "$LON" ] || return 1
    # Показываем локализованное имя; если его нет - введённую строку.
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')
    return 0
}

# Числа -> те же строки, что даёт wttr.in (UI рисует их как есть).
# emit <cond> <temp> <feels> <hum> <ветер км/ч> <откуда дует, градусы>
emit() {
    TEMP=$(awk  -v v="$2" 'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$3" 'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$4" 'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$5" 'BEGIN{printf "%.0f", v}')
    ARROW=$(awk -v d="$6" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        to=(d+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$1" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"
}

if [ "$PROVIDER" = wttr ]; then
    # --- wttr.in: без &lang (единый кэш-ключ), условие по-английски ---
    CU=$(printf '%s' "$CITY" | tr ' ' '+')
    R=$(fetch "https://wttr.in/${CU}?format=%C|%t|%f|%h|%w&m")
    [ -n "$R" ] || exit 0
    # R уже "cond|temp|feels|hum|wind"; дописываем город шестым полем.
    printf '%s|%s\n' "$R" "$DISPLAY_CITY" > "$TMP"
elif [ "$PROVIDER" = metno ]; then
    # --- met.no: locationforecast compact, первый (текущий) шаг ряда ---
    geo_coords || exit 0
    # Условия met.no: запрос без осмысленного User-Agent с контактом получает 403.
    NF_UA="almond3s-lcd-ui https://github.com/fildunsky/openwrt-almond3s"
    W=$(fetch "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=${LAT}&lon=${LON}")
    NF_UA=""
    [ -n "$W" ] || exit 0

    D='@.properties.timeseries[0].data'
    T=$(printf  '%s' "$W" | jsonfilter -e "$D.instant.details.air_temperature" 2>/dev/null)
    H=$(printf  '%s' "$W" | jsonfilter -e "$D.instant.details.relative_humidity" 2>/dev/null)
    WS=$(printf '%s' "$W" | jsonfilter -e "$D.instant.details.wind_speed" 2>/dev/null)
    WD=$(printf '%s' "$W" | jsonfilter -e "$D.instant.details.wind_from_direction" 2>/dev/null)
    SYM=$(printf '%s' "$W" | jsonfilter -e "$D.next_1_hours.summary.symbol_code" 2>/dev/null)
    [ -n "$T" ] || exit 0

    # symbol_code -> английский статус словаря. Суффикс _day/_night/_polartwilight
    # срезаем. Гроза у met.no - «...andthunder», а в названиях с ливнями у них
    # опечатка «lightssleet...»/«lightssnow...» - ловим обе формы. Порядок важен:
    # гроза и «light/heavy» раньше общих «rain»/«snow».
    SYM=${SYM%%_*}
    case "$SYM" in
        *andthunder)                   COND="Moderate or heavy rain with thunder" ;;
        clearsky)                      COND="Sunny" ;;
        fair|partlycloudy)             COND="Partly cloudy" ;;
        cloudy)                        COND="Overcast" ;;
        fog)                           COND="Fog" ;;
        lightrainshowers)              COND="Light rain shower" ;;
        heavyrainshowers)              COND="Torrential rain shower" ;;
        rainshowers)                   COND="Moderate or heavy rain shower" ;;
        lightrain|lightsleet*|lightssleet*) COND="Light rain" ;;
        heavyrain|heavysleet*)         COND="Heavy rain" ;;
        rain|sleet*)                   COND="Moderate rain" ;;
        lightsnowshowers|lightssnowshowers) COND="Light snow showers" ;;
        snowshowers|heavysnowshowers)  COND="Moderate or heavy snow showers" ;;
        lightsnow)                     COND="Light snow" ;;
        heavysnow)                     COND="Heavy snow" ;;
        snow)                          COND="Moderate snow" ;;
        *)                             COND="Cloudy" ;;
    esac
    # compact не отдаёт ощущаемую температуру - показываем фактическую.
    # Ветер у met.no в м/с, строка кэша - в км/ч.
    emit "$COND" "$T" "$T" "$H" "$(awk -v v="$WS" 'BEGIN{printf "%.1f", v*3.6}')" "$WD"
else
    # --- Open-Meteo: координаты + current-погода ---
    geo_coords || exit 0

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

    emit "$COND" "$T" "$F" "$H" "$WS" "$WD"
fi

# Sanity: ровно 6 полей — иначе не подменяем рабочий кэш.
fields=$(awk -F'|' '{print NF}' "$TMP" 2>/dev/null)
if [ -n "$fields" ] && [ "$fields" -ge 6 ]; then
    mv "$TMP" "$OUT"
else
    rm -f "$TMP"
fi
