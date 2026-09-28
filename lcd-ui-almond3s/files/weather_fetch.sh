#!/bin/sh
# weather_fetch.sh — caches current weather for lcd_ui dashboard
#
# Провайдер выбирается в UCI:
#   almond3s.weather.provider = openmeteo | wttr | metno | gismeteo
# или на экране выбора города в интерфейсе погоды
# Open-Meteo (по умолчанию): бесплатный, без ключа, надёжный, но сидит на Hezner, поэтому у некоторых может блокироваться.
# wttr.in: оставлен опцией, НО его апстрим WWO периодически застревает и отдаёт
# битый снимок на весь мир (ловили зиму в августе 17.08.2026) - поэтому не дефолт.
# Дополнительно добавлены бесплатные провайдеры met.no и gismeteo (должен быть доступен через БС)
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
GEO="/tmp/lcd_weather.geo"
DISPLAY_CITY=$(printf '%s' "$CITY" | tr -d '\r\n|')

. /etc/almond3s/scripts/netfetch.sh

fetch() {
    nf_fetch "$1" 8
}

if [ "$PROVIDER" = wttr ]; then
    CU=$(printf '%s' "$CITY" | tr ' ' '+')
    R=$(fetch "https://wttr.in/${CU}?format=%C|%t|%f|%h|%w&m")
    [ -n "$R" ] || exit 0
    printf '%s|%s\n' "$R" "$DISPLAY_CITY" > "$TMP"

elif [ "$PROVIDER" = metno ]; then
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
            G=$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=1&language=ru&format=json")
            LAT=$(printf '%s' "$G" | jsonfilter -e '@.results[0].latitude' 2>/dev/null)
            LON=$(printf '%s' "$G" | jsonfilter -e '@.results[0].longitude' 2>/dev/null)
            NM=$(printf  '%s' "$G" | jsonfilter -e '@.results[0].name' 2>/dev/null | tr -d '|')
            [ -n "$LAT" ] && [ -n "$LON" ] && printf '%s\t%s\t%s\t%s\n' "$CITY" "$LAT" "$LON" "$NM" > "$GEO"
        fi
    fi
    [ -n "$LAT" ] && [ -n "$LON" ] || exit 0
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')

    UA="almond3s-lcd-ui/1.0 (+https://github.com/almond3s)"
    NF_UA="$UA"
    W=$(fetch "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=${LAT}&lon=${LON}")
    NF_UA=""
    [ -n "$W" ] || exit 0

    T=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.air_temperature' 2>/dev/null)
    F=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.apparent_temperature' 2>/dev/null)
    H=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.relative_humidity' 2>/dev/null)
    WS=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.wind_speed' 2>/dev/null)
    WD=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.instant.details.wind_from_direction' 2>/dev/null)
    SYM=$(printf '%s' "$W" | jsonfilter -e '@.properties.timeseries[0].data.next_1_hours.summary.symbol_code' 2>/dev/null)
    [ -n "$T" ] || exit 0
    [ -n "$F" ] || F="$T"

    case "$SYM" in
        lightrainthunder*|rainthunder*|heavyrainthunder*) COND="Moderate or heavy rain with thunder" ;;
        lightsleetthunder*|sleetthunder*|heavysleetthunder*) COND="Moderate or heavy rain with thunder" ;;
        lightssnowthunder*|snowthunder*|heavysnowthunder*) COND="Moderate or heavy rain with thunder" ;;
        clearsky*)                    COND="Sunny" ;;
        fair*)                        COND="Partly cloudy" ;;
        partlycloudy*)                COND="Partly cloudy" ;;
        cloudy*)                      COND="Overcast" ;;
        fog*)                         COND="Fog" ;;
        lightrain*)                   COND="Light rain" ;;
        rain*)                        COND="Moderate rain" ;;
        heavyrain*)                   COND="Heavy rain" ;;
        lightsleet*|lightsleetshowers*) COND="Light rain" ;;
        sleet*|sleetshowers*)         COND="Moderate rain" ;;
        heavysleet*|heavysleetshowers*) COND="Heavy rain" ;;
        lightssnow*|lightssnowshowers*) COND="Light snow" ;;
        snow*|snowshowers*)           COND="Moderate snow" ;;
        heavysnow*|heavysnowshowers*) COND="Heavy snow" ;;
        *)                            COND="Cloudy" ;;
    esac

    TEMP=$(awk  -v v="$T"  'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$F"  'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$H"  'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$WS" 'BEGIN{printf "%.0f", v*3.6}')   # m/s -> km/h
    ARROW=$(awk -v d="$WD" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        to=(d+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$COND" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"

elif [ "$PROVIDER" = gismeteo ]; then
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
            G=$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=${CU}&count=1&language=ru&format=json")
            LAT=$(printf '%s' "$G" | jsonfilter -e '@.results[0].latitude' 2>/dev/null)
            LON=$(printf '%s' "$G" | jsonfilter -e '@.results[0].longitude' 2>/dev/null)
            NM=$(printf  '%s' "$G" | jsonfilter -e '@.results[0].name' 2>/dev/null | tr -d '|')
            [ -n "$LAT" ] && [ -n "$LON" ] && printf '%s\t%s\t%s\t%s\n' "$CITY" "$LAT" "$LON" "$NM" > "$GEO"
        fi
    fi
    [ -n "$LAT" ] && [ -n "$LON" ] || exit 0
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')

    GIS_API="https://services.gismeteo.ru/inform-service/inf_chrome"
    CITIES_XML=$(fetch "${GIS_API}/cities/?lat=${LAT}&lng=${LON}&count=10&lang=en")
    [ -n "$CITIES_XML" ] || exit 0

    # Жадный .* хватал ПОСЛЕДНИЙ id=" в строке, т.е. district_id - и город
    # подставлялся областной (Иваново -> id 265 district_id, +8°C и чужие
    # восход/закат). Привязываемся к первому атрибуту: "item id="...".
    CITY_ID=$(printf '%s' "$CITIES_XML" | tr '<' '\n' | sed -n 's/^item id="\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$CITY_ID" ] || exit 0

    FC_XML=$(fetch "${GIS_API}/forecast/?city=${CITY_ID}&lang=en")
    [ -n "$FC_XML" ] || exit 0

    VALUES_TAG=$(printf '%s' "$FC_XML" | tr '<' '\n' | grep '^values ' | head -n1)
    [ -n "$VALUES_TAG" ] || exit 0

    attr() { printf '%s' "$1" | sed -n "s/.* $2=\"\([^\"]*\)\".*/\1/p"; }

    T=$(attr "$VALUES_TAG" "t")
    F=$(attr "$VALUES_TAG" "tflt")
    H=$(attr "$VALUES_TAG" "hum")
    WS=$(attr "$VALUES_TAG" "ws")
    WD=$(attr "$VALUES_TAG" "wd")
    DESC=$(attr "$VALUES_TAG" "descr")

    [ -n "$T" ] || exit 0
    [ -n "$F" ] || F="$T"

    case "$DESC" in
        *thunder*|*гроза*)              COND="Moderate or heavy rain with thunder" ;;
        *heavy*rain*|*сильный*дожд*)    COND="Heavy rain" ;;
        *light*rain*|*небольшой*дожд*)  COND="Light rain" ;;
        *rain*|*дожд*)                  COND="Moderate rain" ;;
        *sleet*|*мокрый*снег*|*гроза*снег*) COND="Moderate rain" ;;
        *heavy*snow*|*сильный*снег*)    COND="Heavy snow" ;;
        *light*snow*|*небольшой*снег*)  COND="Light snow" ;;
        *snow*|*снег*)                  COND="Moderate snow" ;;
        *clear*|*ясно*)                 COND="Sunny" ;;
        *partly*cloud*|*переменн*|*малооблачн*) COND="Partly cloudy" ;;
        *cloud*|*облачн*|*пасмурн*)     COND="Overcast" ;;
        *fog*|*туман*)                  COND="Fog" ;;
        *drizzle*|*морось*)             COND="Light drizzle" ;;
        *)                              COND="Cloudy" ;;
    esac

    TEMP=$(awk  -v v="$T"  'BEGIN{printf "%+.0f", v}')"°C"
    FEELS=$(awk -v v="$F"  'BEGIN{printf "%+.0f", v}')"°C"
    HUM=$(awk   -v v="$H"  'BEGIN{printf "%.0f", v}')"%"
    KMH=$(awk   -v v="$WS" 'BEGIN{printf "%.0f", v*3.6}')   # m/s -> km/h
    ARROW=$(awk -v d="$WD" 'BEGIN{
        if (d=="") { print "→"; exit }
        split("↑ ↗ → ↘ ↓ ↙ ← ↖", a, " ");
        # Gismeteo wd can be 0-7 or 1-8, modulo 8 handles both safely
        deg=(d%8)*45;
        to=(deg+180)%360; s=int((to+22.5)/45)%8;
        print a[s+1];
    }')
    printf '%s|%s|%s|%s|%s%s|%s\n' "$COND" "$TEMP" "$FEELS" "$HUM" "$ARROW" "${KMH}km/h" "$DISPLAY_CITY" > "$TMP"

else
    # Open-Meteo (default)
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
    [ -n "$NM" ] && DISPLAY_CITY=$(printf '%s' "$NM" | tr -d '\r\n|')

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
