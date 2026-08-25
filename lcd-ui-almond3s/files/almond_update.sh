#!/bin/sh
# Обновление наших пакетов (kmod ядра, lcd-интерфейс, nes) и модема 5G прямо с
# экрана. Идейно повторяет /usr/share/5gmodem/update.sh: пишем единый статус-
# JSON на пакет, а ui.uc его опрашивает по mtime. Команды UI запускает в фоне
# через setsid, чтобы скрипт пережил перезапуск службы при самообновлении lcd.
#
# Три наши пакета проверяются одним запросом к GitHub (check almond) - незачем
# дёргать API трижды. Установка - по одному пакету. Модуль ядра после установки
# перезагружает роутер (его нельзя догрузить на лету).

. /etc/almond3s/scripts/netfetch.sh

REPO="fildunsky/openwrt-almond3s"
BRANCH="master"
API_BASE="https://api.github.com/repos/$REPO/contents/prebuilt"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH/prebuilt"

# Папка в prebuilt = версия OpenWrt; имя kmod-файла содержит версию ядра.
board_rel()  { ubus call system board 2>/dev/null | jsonfilter -e '@.release.version'; }
board_kern() { ubus call system board 2>/dev/null | jsonfilter -e '@.kernel'; }

out_file() { echo "/tmp/almond_upd_$1.json"; }

# Числовое сравнение через точку: печатает 1, если a > b, иначе 0.
version_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN{
		n=split(a,x,"."); m=split(b,y,"."); k=(n>m)?n:m;
		for(i=1;i<=k;i++){ai=(i<=n)?x[i]+0:0; bi=(i<=m)?y[i]+0:0;
			if(ai>bi){print 1; exit} if(ai<bi){print 0; exit}}
		print 0 }'
}

# Установленная версия пакета. У kmod это r-номер (имя ...-6.12.94-r133).
cur_ver() {
	case "$1" in
		kmod) apk info -v 2>/dev/null | sed -n 's/^kmod-lcd-almond3s-.*-r\([0-9]*\)$/\1/p' | head -n1 ;;
		lcd)  apk info -v 2>/dev/null | sed -n 's/^lcd-ui-almond3s-\([0-9][0-9.]*\)$/\1/p' | head -n1 ;;
		nes)  apk info -v 2>/dev/null | sed -n 's/^nes-almond3s-\([0-9][0-9.]*\)$/\1/p' | head -n1 ;;
	esac
}

# Самый свежий apk пакета в списке имён. Для kmod фильтруем по версии ядра.
latest_file() {
	KEY="$1"; NM="$2"; KE="$3"
	case "$KEY" in
		kmod) echo "$NM" | grep -E "^kmod-lcd-almond3s-$KE-r[0-9]+\.apk\$" | \
			awk -F'-r' '{v=$2; sub(/\.apk/,"",v); print v"\t"$0}' | sort -n | tail -n1 | cut -f2 ;;
		lcd)  echo "$NM" | grep -E "^lcd-ui-almond3s-[0-9]+\.apk\$" | sort -t- -k4 -n | tail -n1 ;;
		nes)  echo "$NM" | grep -E "^nes-almond3s-[0-9]+\.apk\$" | sort -t- -k3 -n | tail -n1 ;;
	esac
}

file_ver() {
	case "$1" in
		kmod) echo "$2" | sed -n 's/^kmod-lcd-almond3s-.*-r\([0-9]*\)\.apk$/\1/p' ;;
		lcd)  echo "$2" | sed -n 's/^lcd-ui-almond3s-\([0-9][0-9.]*\)\.apk$/\1/p' ;;
		nes)  echo "$2" | sed -n 's/^nes-almond3s-\([0-9][0-9.]*\)\.apk$/\1/p' ;;
	esac
}

json_ok()  { printf '{"running":false,"success":true,"current":"%s","latest":"%s","update_available":%s}\n' "$2" "$3" "$4" > "$1"; }
json_err() { printf '{"running":false,"success":false,"error":"%s","current":"%s"}\n' "$2" "$3" > "$1"; }

check_almond() {
	REL=$(board_rel); KE=$(board_kern)
	NM=""
	[ -n "$REL" ] && NM=$(nf_fetch "$API_BASE/$REL" 15 | jsonfilter -e '@[*].name' 2>/dev/null)
	for K in kmod lcd nes; do
		F=$(out_file "$K"); CUR=$(cur_ver "$K")
		[ -n "$REL" ] || { json_err "$F" network "$CUR"; continue; }
		[ -n "$NM" ]  || { json_err "$F" no_build "$CUR"; continue; }
		LATF=$(latest_file "$K" "$NM" "$KE")
		LAT=$(file_ver "$K" "$LATF")
		[ -n "$LAT" ] || { json_err "$F" no_build "$CUR"; continue; }
		json_ok "$F" "$CUR" "$LAT" "$(version_gt "$LAT" "$CUR")"
	done
}

install_pkg() {
	K="$1"; F=$(out_file "$K")
	REL=$(board_rel); KE=$(board_kern); PREV=$(cur_ver "$K")
	[ -n "$REL" ] || { json_err "$F" network "$PREV"; return; }
	NM=$(nf_fetch "$API_BASE/$REL" 15 | jsonfilter -e '@[*].name' 2>/dev/null)
	LATF=$(latest_file "$K" "$NM" "$KE")
	[ -n "$LATF" ] || { json_err "$F" no_build "$PREV"; return; }
	FP="/tmp/$LATF"
	nf_fetch "$RAW_BASE/$REL/$LATF" 120 > "$FP"
	[ -s "$FP" ] || { json_err "$F" download "$PREV"; rm -f "$FP"; return; }
	apk add --allow-untrusted --force-overwrite "$FP" >/dev/null 2>&1
	rm -f "$FP"
	CUR=$(cur_ver "$K")
	[ "$CUR" = "$PREV" ] && { json_err "$F" unchanged "$CUR"; return; }
	json_ok "$F" "$CUR" "$CUR" 0
	# Модуль ядра догрузить на лету нельзя - перезагружаемся. Только после
	# успешной установки (при ошибке до сюда не дойдём).
	[ "$K" = "kmod" ] && { sleep 2; reboot; }
}

# Обновить всё доступное. Доступность вычисляем заново (статус-файлы UI мог уже
# пометить «в работе»). Модуль ядра - последним: за его установкой ребут.
install_all() {
	REL=$(board_rel); KE=$(board_kern)
	NM=$(nf_fetch "$API_BASE/$REL" 15 | jsonfilter -e '@[*].name' 2>/dev/null)
	for K in lcd nes; do
		CUR=$(cur_ver "$K"); LAT=$(file_ver "$K" "$(latest_file "$K" "$NM" "$KE")")
		[ -n "$LAT" ] && [ "$(version_gt "$LAT" "$CUR")" = "1" ] && install_pkg "$K"
	done
	if [ -f /usr/share/5gmodem/update.sh ]; then
		UA=$(/usr/share/5gmodem/update.sh check 2>/dev/null | grep -o '"update_available":[01]' | cut -d: -f2)
		[ "$UA" = "1" ] && install_5g
	fi
	CUR=$(cur_ver kmod); LAT=$(file_ver kmod "$(latest_file kmod "$NM" "$KE")")
	[ -n "$LAT" ] && [ "$(version_gt "$LAT" "$CUR")" = "1" ] && install_pkg kmod
}

# Релиз-ноты последнего релиза репозитория (наши пакеты - openwrt-almond3s,
# модем - luci-app-5gmodem). Пишем тег первой строкой, тело - следом.
notes() {
	SRC="$1"
	case "$SRC" in
		5g) NR="luci-app-5gmodem" ;;
		*)  NR="openwrt-almond3s" ;;
	esac
	F="/tmp/almond_notes_$SRC.txt"
	J=$(nf_fetch "https://api.github.com/repos/fildunsky/$NR/releases/latest" 15)
	TAG=$(echo "$J" | jsonfilter -e '@.tag_name' 2>/dev/null)
	BODY=$(echo "$J" | jsonfilter -e '@.body' 2>/dev/null)
	if [ -z "$TAG" ] && [ -z "$BODY" ]; then echo "__ERR__" > "$F"; return; fi
	{ echo "$TAG"; echo "$BODY"; } > "$F"
}

# 5gmodem: инфраструктура своя. check синхронный в stdout - гоним в файл;
# install форкает сам и пишет /tmp/5gmodem_update.json - зеркалим в наш файл.
check_5g() {
	F=$(out_file 5g)
	/usr/share/5gmodem/update.sh check > "$F.tmp" 2>/dev/null
	if [ -s "$F.tmp" ]; then mv "$F.tmp" "$F"
	else json_err "$F" network ""; rm -f "$F.tmp"; fi
}
install_5g() {
	F=$(out_file 5g)
	echo '{"running":true,"act":"install"}' > "$F"
	/usr/share/5gmodem/update.sh install >/dev/null 2>&1
	i=0
	while [ $i -lt 150 ]; do
		S=$(cat /tmp/5gmodem_update.json 2>/dev/null)
		if [ -z "$S" ] || echo "$S" | grep -q '"running":true'; then
			# Пока идёт - держим НАШУ метку с act:install, чтобы строка
			# показывала «Устанавливаю…», а не «Проверяю…» (у 5gmodem поля act нет).
			echo '{"running":true,"act":"install"}' > "$F"
		else
			echo "$S" > "$F"; break
		fi
		sleep 2; i=$((i+1))
	done
}

case "$1" in
	check)   [ "$2" = "5g" ] && check_5g || check_almond ;;
	install) case "$2" in 5g) install_5g ;; all) install_all ;; kmod|lcd|nes) install_pkg "$2" ;; esac ;;
	notes)   notes "$2" ;;
	*)       echo "usage: $0 {check [5g]|install <kmod|lcd|nes|5g|all>|notes <almond|5g>}" >&2; exit 1 ;;
esac
