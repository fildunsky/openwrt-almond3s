#!/bin/sh
# Общая лестница запросов наружу: сперва напрямую, затем через прокси clash.
# Подключается точкой: . /etc/almond3s/scripts/netfetch.sh

NF_DEAD="/tmp/.lcd_direct_dead"

nf_clash_api() {
	[ -f /opt/clash/config.yaml ] || return 1
	NF_ADDR=$(sed -n 's/^external-controller:[[:space:]]*//p' /opt/clash/config.yaml | head -n1 | tr -d '"'\''')
	[ -n "$NF_ADDR" ] || return 1
	case "$NF_ADDR" in
		0.0.0.0:*) NF_ADDR="127.0.0.1:${NF_ADDR##*:}" ;;
		:*)        NF_ADDR="127.0.0.1$NF_ADDR" ;;
	esac
	NF_SECRET=$(sed -n 's/^secret:[[:space:]]*//p' /opt/clash/config.yaml | head -n1 | tr -d '"'\''')
	return 0
}

nf_api_get() {
	if [ -n "$NF_SECRET" ]; then
		curl -s -m 4 -H "Authorization: Bearer $NF_SECRET" "http://$NF_ADDR/configs"
	else
		curl -s -m 4 "http://$NF_ADDR/configs"
	fi
}

nf_api_patch() {
	if [ -n "$NF_SECRET" ]; then
		curl -s -m 4 -X PATCH -H "Authorization: Bearer $NF_SECRET" \
			"http://$NF_ADDR/configs" -d "$1" >/dev/null 2>&1
	else
		curl -s -m 4 -X PATCH "http://$NF_ADDR/configs" -d "$1" >/dev/null 2>&1
	fi
}

# Порт HTTP-прокси. У SSClash его обычно нет: он работает прозрачным портом, а
# трафик самого роутера мимо туннеля. Тогда поднимаем порт через API на лету -
# конфиг при этом не трогаем, после перезапуска clash всё вернётся как было.
nf_proxy() {
	pidof clash >/dev/null 2>&1 || pidof mihomo >/dev/null 2>&1 || return 1
	NF_PORT=$(sed -n 's/^mixed-port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' /opt/clash/config.yaml 2>/dev/null | head -n1)
	[ -n "$NF_PORT" ] && [ "$NF_PORT" != "0" ] && { printf 'http://127.0.0.1:%s' "$NF_PORT"; return 0; }
	nf_clash_api || return 1
	NF_PORT=$(nf_api_get | jsonfilter -e '@["mixed-port"]' 2>/dev/null)
	[ -n "$NF_PORT" ] && [ "$NF_PORT" != "0" ] && { printf 'http://127.0.0.1:%s' "$NF_PORT"; return 0; }
	nf_api_patch '{"mixed-port":7890}'
	sleep 1
	NF_PORT=$(nf_api_get | jsonfilter -e '@["mixed-port"]' 2>/dev/null)
	[ -n "$NF_PORT" ] && [ "$NF_PORT" != "0" ] || return 1
	printf 'http://127.0.0.1:%s' "$NF_PORT"
}

nf_direct_dead() {
	[ -f "$NF_DEAD" ] || return 1
	[ -n "$(find "$NF_DEAD" -mmin -60 2>/dev/null)" ] || { rm -f "$NF_DEAD"; return 1; }
	return 0
}

# nf_fetch <url> [таймаут]
nf_fetch() {
	NF_URL="$1"
	NF_T="${2:-8}"
	NF_PX=$(nf_proxy)

	if command -v curl >/dev/null 2>&1; then
		if ! nf_direct_dead; then
			curl --http1.1 -k -s -f --max-time "$NF_T" "$NF_URL" && return 0
			[ -n "$NF_PX" ] && : > "$NF_DEAD"
		fi
		[ -n "$NF_PX" ] && curl --http1.1 -k -s -f --max-time $((NF_T * 2)) -x "$NF_PX" "$NF_URL" && \
			{ rm -f "$NF_DEAD"; return 0; }
		return 1
	fi

	if ! nf_direct_dead; then
		wget --no-check-certificate -q -T "$NF_T" -O - "$NF_URL" && return 0
		[ -n "$NF_PX" ] && : > "$NF_DEAD"
	fi
	[ -n "$NF_PX" ] && http_proxy="$NF_PX" https_proxy="$NF_PX" \
		wget --no-check-certificate -q -T $((NF_T * 2)) -O - "$NF_URL" && \
		{ rm -f "$NF_DEAD"; return 0; }
	return 1
}
