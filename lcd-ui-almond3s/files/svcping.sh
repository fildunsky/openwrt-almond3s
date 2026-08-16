#!/bin/sh
#
# svcping.sh [хост] - проверка доступности сервисов для карточек на LCD.
#
# Без аргумента проверяет весь список из uci, с аргументом - только один хост
# (тап по карточке на экране).
#
# Проверку не изобретаем: в 5gmodem уже есть netpri.sh ping, который резолвит
# имя, идёт по TLS/HTTP и умеет отдельно разбираться с Telegram (ICMP до него
# не ходит, а домен в РФ подменяют на операторском резолвере). ICMP здесь
# бесполезен: на мобильном интернете с белыми списками пинг до 8.8.8.8 молчит,
# хотя Яндекс и Ozon открываются.
#
# Результат каждой пробы лежит СВОИМ файлом в $DIR, а общий список собирается
# из них заново. Так проверка одного хоста не трогает результаты остальных, и
# одновременный запуск (крон плюс кнопка) ничего не портит.

OUT=/tmp/lcd_services.json
DIR=/tmp/lcd_svc
NETPRI=/usr/share/5gmodem/netpri.sh

mkdir -p "$DIR" 2>/dev/null

# Конфиг давно переехал lcd -> almond3s; читаем новое имя, старое оставляем
# вторым шансом для непереехавших систем (иначе список выходил пустым и
# фолбэк ниже терял ozon.ru/max.ru - пойман 16.08).
hosts=$(uci -q get almond3s.services.host)
[ -n "$hosts" ] || hosts=$(uci -q get lcd.services.host)
[ -n "$hosts" ] || hosts="ya.ru api.telegram.org youtube.com github.com"

# Имя файла из хоста: точки и прочее в имени файла ни к чему.
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# Без 5gmodem проверяем сами: код ответа не важен, важен сам факт ответа.
fallback() {
	_s=$(date +%s)
	if curl --http1.1 -k -s -m 6 -o /dev/null "https://$1/" 2>/dev/null; then
		_e=$(date +%s)
		printf '{"ok":1,"ms":%d,"via":"http"}' $(( (_e - _s) * 1000 ))
	else
		printf '{"ok":0,"via":"http"}'
	fi
}

probe() {
	if [ -x "$NETPRI" ]; then
		_r=$("$NETPRI" ping "$1" 2>/dev/null)
	else
		_r=""
	fi
	case "$_r" in
		'{'*) ;;
		*) _r=$(fallback "$1") ;;
	esac
	printf '%s' "$_r" > "$DIR/$(safe "$1").json"
}

if [ -n "$1" ]; then
	probe "$1"
else
	for h in $hosts; do probe "$h"; done
fi

# Общий список собираем в порядке uci и только из готовых проб: хост без файла
# в список не попадает, и экран покажет его серым - «ещё не проверяли».
TMP="$OUT.$$"
trap 'rm -f "$TMP"' EXIT INT TERM

printf '[' > "$TMP"
first=1
for h in $hosts; do
	f="$DIR/$(safe "$h").json"
	[ -s "$f" ] || continue
	[ "$first" = 1 ] || printf ',' >> "$TMP"
	first=0
	printf '{"host":"%s","r":%s}' "$h" "$(cat "$f")" >> "$TMP"
done
printf ']\n' >> "$TMP"

# Перед подменой убеждаемся, что JSON целый: лучше оставить прошлый результат,
# чем подсунуть экрану огрызок.
if [ -s "$TMP" ] && [ "$(tail -c 2 "$TMP" | head -c 1)" = "]" ]; then
	mv "$TMP" "$OUT"
fi
