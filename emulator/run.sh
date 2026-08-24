#!/bin/sh
# Запуск эмулятора Almond 3S на ПК: настоящие ui.uc и render, железо подменено.
#  - render пишет кадры в файл (ALMOND_LCD_DEV) вместо /dev/lcd;
#  - ui.uc исполняет хостовый ucode (prefix/), uci и ubus - стабы modules/;
#  - абсолютные пути железа (/etc/almond3s, /usr/bin/almond3s-lcd) подменяет
#    bwrap, ничего в систему не ставится;
#  - server.py отдаёт картинку в браузер и принимает тапы.
# После запуска: http://127.0.0.1:8380
set -e
EMU="$(cd "$(dirname "$0")" && pwd)"
SRC="$EMU/../lcd-ui-almond3s/src"
ST=/tmp/almond3s-emu

command -v bwrap >/dev/null || { echo "нужен bubblewrap (bwrap)"; exit 1; }
[ -x "$EMU/prefix/bin/ucode" ] || { echo "нет prefix/bin/ucode - собери ucode (см. README)"; exit 1; }
[ -x "$EMU/bin/render-emu" ] || { echo "нет bin/render-emu - gcc -O2 -o bin/render-emu ../lcd-ui-almond3s/src/render.c"; exit 1; }

mkdir -p "$ST/ubus" "$ST/leds/white:status" "$ST/hostusr" "$ST/hostetc"
cp -f "$EMU/forward/ash" "$ST/forward-ash" 2>/dev/null && chmod +x "$ST/forward-ash"
[ -f "$ST/leds/white:status/brightness" ] || {
    echo 0 > "$ST/leds/white:status/brightness"
    echo none > "$ST/leds/white:status/trigger"
    echo 250 > "$ST/leds/white:status/delay_on"
    echo 250 > "$ST/leds/white:status/delay_off"
}
[ -f "$ST/uci.json" ] || cp "$EMU/seed/uci.json" "$ST/uci.json"
for f in lcd_data.json lcd_zig_peers.json lcd_weather.txt; do
    [ -f "/tmp/$f" ] || cp "$EMU/seed/$f" "/tmp/$f"
done
cp -n "$EMU"/seed/ubus/*.json "$ST/ubus/" 2>/dev/null || true

pkill -f "$EMU/bin/render-emu" 2>/dev/null || true
pkill -f "ucode.*ui.uc" 2>/dev/null || true
pkill -f "$EMU/server.py" 2>/dev/null || true
sleep 0.3

ALMOND_LCD_DEV="$ST/lcd.fb" "$EMU/bin/render-emu" >/dev/null 2>&1 &
echo "render-emu: $!"
sleep 0.3

# /etc и /usr/bin на хосте не наши - накрываем их tmpfs и наполняем
# симлинками на настоящие бинарники уже ИЗНУТРИ песочницы (первым процессом
# идёт хостовый dash по прямому пути, пока /usr/bin ещё пуст).
bwrap --dev-bind / / \
    --ro-bind /usr /tmp/almond3s-emu/hostusr \
    --ro-bind /etc /tmp/almond3s-emu/hostetc \
    --tmpfs /usr/bin \
    --tmpfs /etc \
    --bind "$EMU/etc-almond3s" /etc/almond3s \
    --bind /tmp/almond3s-emu/leds /sys/class/leds \
    --tmpfs /etc/zoneinfo-host \
    --ro-bind /usr/share/zoneinfo /etc/zoneinfo-host \
    --tmpfs /usr/share \
    --ro-bind "$EMU/share-5gmodem" /usr/share/5gmodem \
    --ro-bind "$EMU/bin/term-emu" /tmp/almond3s-emu/term-emu \
    --tmpfs /usr/libexec \
    --ro-bind "$EMU/bin/almond3s-lcd" /usr/bin/almond3s-lcd \
    --ro-bind "$EMU/bin/uci" /usr/bin/uci.emu \
    --ro-bind "$EMU/bin/jsonfilter" /usr/bin/jsonfilter.emu \
    --setenv LD_LIBRARY_PATH "$EMU/prefix/lib" \
    -- /tmp/almond3s-emu/hostusr/bin/dash -c '
        HB=/tmp/almond3s-emu/hostusr/bin
        $HB/cp -s $HB/* /usr/bin/ 2>/dev/null
        $HB/ln -sf /usr/bin/uci.emu /usr/bin/uci
        $HB/ln -sf /usr/bin/jsonfilter.emu /usr/bin/jsonfilter
        # awk на хосте ходит через /etc/alternatives - подвязываем gawk напрямую
        $HB/ln -sf $HB/gawk /usr/bin/awk
        $HB/ln -sf /tmp/almond3s-emu/forward-ash /usr/bin/ash
        $HB/mkdir -p /usr/libexec/almond3s 2>/dev/null
        $HB/cp /tmp/almond3s-emu/term-emu /usr/libexec/almond3s/almond3s-term 2>/dev/null
        for f in passwd group hosts ssl alternatives; do
            $HB/cp -rL /tmp/almond3s-emu/hostetc/$f /etc/$f 2>/dev/null
        done
        # resolv.conf хоста указывает на заглушку systemd-resolved (127.0.0.53
        # + nss-модуль resolve) - в песочнице она не работает; публичный DNS.
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "hosts: files dns" > /etc/nsswitch.conf
        # Таймзона: имя зоны из симлинка хоста (обычный readlink - относительный
        # путь -f не резолвит под бинд-маунтом), либо зона роутера из tz-файла.
        # Копируем настоящий zoneinfo и ставим TZ - ucode читает при старте.
        TZN="$(cat /tmp/almond3s-emu/tz 2>/dev/null)"
        [ -z "$TZN" ] && TZN="$($HB/readlink /tmp/almond3s-emu/hostetc/localtime | $HB/sed "s#.*/zoneinfo/##")"
        # ТОЛЬКО /etc/localtime, без export TZ: /usr/share/zoneinfo под tmpfs
        # недоступен, и TZ=<зона> не нашёл бы файл (откат к UTC). glibc при
        # пустом TZ читает /etc/localtime - его и ставим настоящим zoneinfo.
        [ -n "$TZN" ] && [ -f "/etc/zoneinfo-host/$TZN" ] && \
            $HB/cp "/etc/zoneinfo-host/$TZN" /etc/localtime
        /etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1 &
        exec "$0" -L "$1" -L "$2" "$3"
    ' "$EMU/prefix/bin/ucode" \
        "$EMU/prefix/lib/ucode/*.so" "$EMU/modules/*.uc" \
        "$SRC/ui.uc" >"$ST/ui.log" 2>&1 &
echo "ui.uc: $! (лог $ST/ui.log)"

exec python3 "$EMU/server.py"
