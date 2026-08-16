#!/bin/sh
# Мост к SSClash/mihomo для LCD Almond 3S. Отдаёт статус и группы в JSON,
# переключает узлы и запускает/останавливает службу. Порт и секрет читаются
# из конфига ядра, поэтому работает и с luci-версией, и с SSClash-Go.
SS_DIR=/opt/clash
SS_CFG=$SS_DIR/config.yaml

if [ -x /etc/init.d/ssclash ]; then
	SS_INIT=/etc/init.d/ssclash
elif [ -x /etc/init.d/clash ]; then
	SS_INIT=/etc/init.d/clash
else
	SS_INIT=""
fi

api_port() {
	local p
	p=$(sed -n 's/^external-controller:[[:space:]]*//p' "$SS_CFG" 2>/dev/null \
		| head -n1 | sed 's/.*://;s/[^0-9]//g')
	[ -n "$p" ] || p=9090
	echo "$p"
}

api_secret() {
	sed -n 's/^secret:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
		"$SS_CFG" 2>/dev/null | head -n1
}

api_base() { echo "http://127.0.0.1:$(api_port)"; }

# URL проверки задержки (gstatic generate_204), уже %-кодирован.
TEST_URL="http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"

api_get() {
	curl -s -m "${2:-5}" -H "Authorization: Bearer $(api_secret)" \
		"$(api_base)$1" 2>/dev/null
}

installed() { [ -n "$SS_INIT" ]; }
running()   { [ -n "$(api_get /version 3)" ]; }
enabled()   { [ -n "$SS_INIT" ] && "$SS_INIT" enabled 2>/dev/null; }

# %-кодирование пробелов в имени группы для URL пути.
urlenc() { printf '%s' "$1" | sed 's/ /%20/g'; }

case "$1" in
	installed)
		installed && echo 1 || echo 0
		;;
	status)
		i=0; r=0; e=0
		installed && i=1
		if [ "$i" = 1 ]; then running && r=1; enabled && e=1; fi
		printf '{"installed":%d,"running":%d,"enabled":%d}\n' "$i" "$r" "$e"
		;;
	groups)
		# Сырой ответ /proxies - разбор групп делает ucode (ему удобнее обходить
		# объект). Пустой ответ = ядро молчит (не запущено).
		raw=$(api_get /proxies 6)
		[ -n "$raw" ] && printf '%s\n' "$raw" || echo '{}'
		;;
	providers)
		# Узлы подписок с их history (задержки). У SSClash реальные серверы
		# приходят отсюда, а не из /proxies. Разбор - в ucode.
		raw=$(api_get /providers/proxies 8)
		[ -n "$raw" ] && printf '%s\n' "$raw" || echo '{}'
		;;
	log)
		# Последние строки лога ядра - тот же источник, что у luci-страницы
		# (logread -e clash). Срезаем дату/facility, вытаскиваем msg="...",
		# помечаем уровень одной буквой (E/W/I) - остальное разбирает ucode.
		logread -e clash 2>/dev/null | tail -n 40 | awk '
		{
			lv="I";
			if (index($0,"level=error")) lv="E";
			else if (index($0,"level=warn")) lv="W";
			msg="";
			m=index($0,"msg=\"");
			if (m>0) { rest=substr($0,m+5); q=index(rest,"\""); if (q>0) msg=substr(rest,1,q-1); }
			if (msg=="") { c=index($0,"]: "); if (c>0) msg=substr($0,c+3); else msg=$0; }
			print lv "\t" msg;
		}'
		;;
	select)
		# Работает для любых групп, включая url-test/fallback: ядро фиксирует
		# выбор мгновенно, без перезапуска (mihomo Set()).
		g="$2"; n="$3"
		[ -n "$g" ] && [ -n "$n" ] || exit 1
		curl -s -o /dev/null -m 6 -X PUT \
			-H "Authorization: Bearer $(api_secret)" \
			-H "Content-Type: application/json" \
			--data "{\"name\":\"$n\"}" \
			"$(api_base)/proxies/$(urlenc "$g")" 2>/dev/null
		;;
	unfix)
		# Снять ручную фиксацию url-test/fallback - вернуть автоподбор (DELETE).
		g="$2"
		[ -n "$g" ] || exit 1
		curl -s -o /dev/null -m 6 -X DELETE \
			-H "Authorization: Bearer $(api_secret)" \
			"$(api_base)/proxies/$(urlenc "$g")" 2>/dev/null
		;;
	delay)
		# Замер задержки прямого узла (есть в /proxies). Для узлов подписки
		# используем ndelay - их в /proxies нет.
		n="$2"
		[ -n "$n" ] || exit 1
		api_get "/proxies/$(urlenc "$n")/delay?timeout=5000&url=$TEST_URL" 8
		;;
	ndelay)
		# Замер узла подписки через health-check провайдера. Ядро пишет history.
		p="$2"; n="$3"
		[ -n "$p" ] && [ -n "$n" ] || exit 1
		api_get "/providers/proxies/$(urlenc "$p")/$(urlenc "$n")/healthcheck?url=$TEST_URL&timeout=5000" 12
		;;
	gdelay)
		# Замер всей группы разом (health-check): ядро проставит history всем
		# членам. Дольше - таймаут больше.
		g="$2"
		[ -n "$g" ] || exit 1
		api_get "/group/$(urlenc "$g")/delay?timeout=5000&url=$TEST_URL" 40
		;;
	start)
		[ -n "$SS_INIT" ] || exit 1
		"$SS_INIT" enable 2>/dev/null
		"$SS_INIT" start 2>/dev/null
		;;
	stop)
		[ -n "$SS_INIT" ] || exit 1
		"$SS_INIT" stop 2>/dev/null
		"$SS_INIT" disable 2>/dev/null
		;;
	*)
		echo "usage: vpn_clash.sh {installed|status|groups|select G N|start|stop}" >&2
		exit 1
		;;
esac
