#!/bin/sh
# На Almond 3S GPIO33 - это #PERST модемного слота: линия настоящая (нужна,
# чтобы модем поднялся при старте), но LM960 в USB-режиме игнорирует её на
# горячую - 5-секундный физический LOW проверен по регистрам, модем даже не
# моргнул. Рабочий способ перезагрузки - гасить USB-порт на уровне хаба
# (метод disable): модем полностью перезагружается и пересчисляется.
# GPIO оставлен последним фолбэком для плат, где reset действует.
RM=/usr/share/5gmodem/reboot_modem.sh
if [ -x "$RM" ]; then
	r=$("$RM" usbpower 2>/dev/null)
	case "$r" in
	*'"success":true'*) exit 0 ;;
	esac
	exec "$RM" power
fi
v=/sys/class/gpio/modem_reset/value
[ -f "$v" ] || exit 1
echo 1 > "$v"
sleep 2
echo 0 > "$v"
