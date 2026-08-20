# Единая сеть Wi-Fi из нескольких роутеров: роуминг и объединение узлов

Документ описывает, как собрать из нескольких одинаковых роутеров домашнюю
сеть с одним SSID, бесшовным переходом клиентов между точками (802.11r) и
подсказками клиентам о соседях (802.11k/v). Отдельно разобрано, как узлы
соединяются между собой и как сохранить доступ к веб-интерфейсу каждого узла.

Всё, что ниже, опирается на фактическое состояние сборки
`/home/do/Desktop/openwrt/25.12.5-almond` (OpenWrt 25.12.5, r33051-f5dae5ece4).
Разделы «Пакеты» и «Узкие места» проверены по исходникам этой сборки, а не по
общим рекомендациям.

---

## 1. Что есть в сборке сейчас

Проверено по `.config`, `bin/`, `package/feeds/` и манифесту образа.

**Железо и драйвер**

| Параметр | Значение |
| --- | --- |
| SoC | MT7621, два ядра, четыре аппаратных потока |
| Радио 2,4 ГГц | MT7602EN на `pcie1`, `ieee80211-freq-limit = <2400000 2500000>` |
| Радио 5 ГГц | MT7612EN на `pcie0`, `ieee80211-freq-limit = <5000000 6000000>` |
| Драйвер | один и тот же — `kmod-mt76x2` (PCI ID `0x7602` и `0x7612` в `mt76x2/pci.c`) |
| Версия mt76 | `6.12.94.2026.03.19~39c960c3` |
| Ядро / mac80211 | 6.12.94, backports 6.18.26 |
| Порты Ethernet | `wan`, `lan1`, `lan2` (`ucidef_set_interfaces_lan_wan "lan1 lan2" "wan"`) |
| Бюджет образа | `IMAGE_SIZE := 65216k`, текущий sysupgrade — 13,6 МиБ |

**Wi-Fi стек**

| Параметр | Значение |
| --- | --- |
| hostapd/wpa_supplicant | `2025.08.26~ca266cc2` (git `ca266cc24d87`) |
| Установленный вариант | `wpad-basic-mbedtls` (задан в `target/linux/ramips/mt7621/target.mk`) |
| Генерация конфигурации | ucode, `CONFIG_WIFI_SCRIPTS_UCODE=y` |
| `iw` | 6.17 |
| `hostapd-utils`, `wpa-cli` | **не установлены** (значит, нет `hostapd_cli` и `wpa_cli`) |
| Ядро: 802.11s | `CONFIG_PACKAGE_MAC80211_MESH=y` — поддержка меша в mac80211 уже собрана |
| `kmod-batman-adv` | `=m` (собран, в образ не входит), `BATMAN_V`, `BLA`, `DAT`, `MCAST` включены |
| `batctl-default` | `=m` |
| `mesh11sd`, `dawn`, `usteer`, `umdns`, `luci-proto-batman-adv` | есть в фидах, не выбраны |

Все нужные пакеты в фидах присутствуют. Ничего доставлять извне не требуется.

---

## 2. Выбор схемы объединения узлов

### 2.1 Разбор вариантов

**Проводной backhaul.** Каждый узел — «тупая» точка доступа: мост `br-lan`
из портов Ethernet и обоих радио, DHCP-сервер выключен, NAT нет. Плюсы:
ноль потерь в эфире, каждый узел может стоять на своём канале 5 ГГц, роуминг
802.11r работает без каких-либо дополнительных условий. Минус один — нужен
кабель. У устройства три порта (`wan` можно переиспользовать как LAN), поэтому
узлы можно соединять цепочкой.

**WDS / 4-address.** Технически возможно: `mt76` не выставляет
`SW_CRYPTO_CONTROL`, поэтому mac80211 в `net/mac80211/main.c` автоматически
добавляет `NL80211_IFTYPE_AP_VLAN`, и 4-адресный режим доступен. Но топология
получается звездой с ручной привязкой каждого листа к корню, без многошаговости
и без самовосстановления при падении корня. Для «объединения в одно действие»
это плохо масштабируется: конфигурация каждого узла зависит от того, к кому он
подключается.

**802.11s поверх mac80211.** Драйвер объявляет `NL80211_IFTYPE_MESH_POINT`
в `mt76x02_if_limits[]` и `mt76_alloc_phy()`, до 8 интерфейсов на радио,
`num_different_channels = 1`. То есть меш-интерфейс и обычная точка доступа
могут жить на одном радио, но обязательно на одном канале. Узлы находят друг
друга сами по `mesh_id`, топология любая, многошаговость встроенная.

**802.11s + batman-adv.** То же самое, но пересылку кадров делает не встроенный
в 802.11s forwarding, а batman-adv. Даёт три вещи, которых нет у чистого
802.11s: bridge loop avoidance (защита от петли, когда узел одновременно
подключён и кабелем, и по эфиру), distributed ARP table (меньше широковещания)
и метрику BATMAN_V, учитывающую пропускную способность канала, а не число
переходов.

### 2.2 Что выбрано

**Основной backhaul — проводной, там где дотянулся кабель.
Беспроводной backhaul — 802.11s на 5 ГГц поверх batman-adv.**

Обоснование:

1. Проводное соединение на этом железе выигрывает у любого беспроводного с
   большим отрывом: одно радио 5 ГГц не может одновременно обслуживать клиентов
   и транзит без деления эфира пополам на каждом переходе.
2. Из беспроводных вариантов 802.11s — единственный, где «вступление в сеть»
   действительно сводится к одному действию: узлу достаточно знать `mesh_id`,
   ключ и канал, дальше он находит соседей сам.
3. batman-adv выбран поверх штатного форвардинга 802.11s именно из-за bridge
   loop avoidance. Смешанная топология (часть узлов на кабеле, часть по эфиру)
   без BLA даёт широковещательный шторм на первой же петле, а такая топология
   в доме возникает естественным образом. Ядерная часть уже собрана и уже
   настроена как надо: `BATMAN_ADV_BATMAN_V=y`, `BATMAN_ADV_BLA=y`,
   `BATMAN_ADV_DAT=y`.
4. WDS отброшен: ручная привязка к корню противоречит требованию «в одно
   действие», а выгоды перед 802.11s нет.

Роуминг клиентов (802.11r/k/v) от выбора backhaul не зависит — он работает
одинаково при любом из вариантов, лишь бы все узлы были в одном L2-домене.

---

## 3. Пакеты

### 3.1 Разбор вариантов wpad

Все варианты собираются из одного `package/network/services/hostapd/Makefile`.
Набор возможностей задают два места: файл `files/hostapd-$(CONFIG_VARIANT).config`
и переменная `DRIVER_MAKEOPTS`. Для варианта `mesh` в Makefile стоит
`CONFIG_VARIANT := full` (строки 66–68), поэтому меш-сборка берёт полный
defconfig и добавляет к нему `CONFIG_AP=y CONFIG_MESH=y`.

| Возможность | `wpad-mini` | `wpad-basic-mbedtls` | `wpad-mesh-mbedtls` | `wpad-mbedtls` |
| --- | --- | --- | --- | --- |
| WPA2-PSK | да | да | да | да |
| SAE (WPA3-Personal) | нет | да | да | да |
| 802.11w (MFP) | нет | да | да | да |
| **802.11r (FT)** | нет | **да** | **да** | **да** |
| **802.11k** (`rrm_neighbor_report`, `rrm_beacon_report`) | да | **да** | **да** | **да** |
| **802.11v** (`bss_transition`, `wnm_sleep_mode`) | нет | **нет** | **да** | **да** |
| **802.11s + SAE-меш** | нет | **нет** | **да** | нет |
| WPS | нет | нет | да | да |
| EAP / RADIUS | нет | нет | да | да |
| OWE, DPP, Suite-B | нет | OWE | нет | да |
| Размер `.apk`, mipsel_24kc | 418,3 КБ | 506,9 КБ | 755,7 КБ | 854,0 КБ |

Три вывода, которые важны на практике:

**802.11r есть уже в `basic`.** В `files/hostapd-basic.config` строка 151 —
`CONFIG_IEEE80211R=y`. Если нужен только быстрый роуминг и проводной backhaul,
менять пакет не нужно вообще.

**802.11k тоже есть в `basic`.** Опции `rrm_neighbor_report` и
`rrm_beacon_report` в `hostapd/config_file.c` (строки 4513 и 4517) не закрыты
никаким `#ifdef`.

**802.11v в `basic` нет, и это не «тихо не работает», а отказ запуска.**
Опция `bss_transition` в `config_file.c` закрыта `#ifdef CONFIG_WNM_AP`
(строки 3992–3999), а `CONFIG_WNM_AP` включается только из `CONFIG_WNM`
(`hostapd/Makefile`, строки 338–341), который стоит только в
`files/hostapd-full.config`. Неизвестную опцию парсер обрабатывает так:

```
	} else {
		wpa_printf(MSG_ERROR,
			   "Line %d: unknown configuration item '%s'",
			   line, buf);
		return 1;
	}
```

а вызывающий код при `errors != 0` освобождает конфигурацию и возвращает `NULL`.
То есть `option bss_transition '1'` на сборке с `wpad-basic-*` не просто
игнорируется — соответствующий BSS не поднимется. По той же причине на `basic`
отсутствует ubus-метод `bss_transition_request` (`src/src/ap/ubus.c`, строка
1656 под `#ifdef CONFIG_WNM_AP`), а без него внешние балансировщики не смогут
подсказывать клиенту переход.

**Вывод:** нужен `wpad-mesh-mbedtls`. Он единственный даёт одновременно 802.11r,
802.11v и 802.11s c SAE. Полный `wpad-mbedtls` не нужен — его отличия (OWE, DPP,
Suite-B-192) в домашней сети не используются, а меша в нём нет.

### 3.2 Изменения в сборке

Правильное место — рецепт устройства, потому что `wpad-basic-mbedtls` приезжает
из `DEFAULT_PACKAGES` подцели:

```
target/linux/ramips/mt7621/target.mk:13:
DEFAULT_PACKAGES += wpad-basic-mbedtls uboot-envtools kmod-crypto-hw-eip93
```

В `target/linux/ramips/image/mt7621.mk`, секция `Device/securifi_almond-3s`,
строка `DEVICE_PACKAGES` дополняется так:

```
  DEVICE_PACKAGES := kmod-mt76x2 kmod-usb3 -uboot-envtools \
  	kmod-usb-net-qmi-wwan kmod-usb-serial-option uqmi \
  	-wpad-basic-mbedtls wpad-mesh-mbedtls hostapd-utils wpa-cli \
  	kmod-batman-adv batctl-default
```

Соответствующее состояние `.config`:

```
# CONFIG_PACKAGE_wpad-basic-mbedtls is not set
CONFIG_PACKAGE_wpad-mesh-mbedtls=y
CONFIG_PACKAGE_hostapd-utils=y
CONFIG_PACKAGE_wpa-cli=y
CONFIG_PACKAGE_kmod-batman-adv=y
CONFIG_PACKAGE_batctl-default=y
CONFIG_PACKAGE_MAC80211_MESH=y
CONFIG_BATMAN_ADV_BATMAN_V=y
CONFIG_BATMAN_ADV_BLA=y
CONFIG_BATMAN_ADV_DAT=y
CONFIG_BATMAN_ADV_MCAST=y
```

Последние пять строк уже стоят в текущем `.config`, менять их не нужно —
меняется только `=m` на `=y` у `kmod-batman-adv` и `batctl-default`.

Что убрать: `wpad-basic-mbedtls`. Он конфликтует с `wpad-mesh-mbedtls` через
`CONFLICTS := $(HOSTAPD_PROVIDERS) $(SUPPLICANT_PROVIDERS)`, поэтому оставить
оба нельзя.

Цена по размеру (сжатые `.apk`, mipsel_24kc, 25.12.5):

| Пакет | Размер | Дельта |
| --- | --- | --- |
| `wpad-mesh-mbedtls` вместо `wpad-basic-mbedtls` | 755,7 КБ вместо 506,9 КБ | +248,8 КБ |
| `kmod-batman-adv` | 98,8 КБ | +98,8 КБ |
| `batctl-default` | 36,6 КБ | +36,6 КБ |
| `hostapd-utils` | 20,0 КБ | +20,0 КБ |
| `wpa-cli` | 34,2 КБ | +34,2 КБ |
| **Итого** | | **≈ +438 КБ** |

При бюджете 65216 КБ и текущем образе 13,6 МиБ это несущественно.

### 3.3 Необязательные пакеты

| Пакет | Версия в фиде | Зачем | Комментарий |
| --- | --- | --- | --- |
| `usteer` | `2025.10.04~1d6524c6`, 25,5 КБ | заполняет базу соседей 802.11k и отправляет клиентам запросы перехода 802.11v | требует `wpad-mesh`/`wpad-full`, иначе нет ubus-метода `bss_transition_request` |
| `dawn` | `2025.11.07~7414c34a`, 37,8 КБ | то же самое, другой алгоритм принятия решения | ставить вместе с `usteer` бессмысленно |
| `mesh11sd` | `6.2.1`, 61,4 КБ | автонастройка параметров 802.11s | при статической конфигурации из этого документа не нужен |
| `luci-proto-batman-adv` | из фида luci | секции `batadv` в веб-интерфейсе | удобно, если настраивать руками через LuCI |
| `umdns` | `2026-06-16` | разрешение имён узлов в локальной сети | не заменяет фиксированные адреса, см. раздел 6 |

Без `usteer`/`dawn` 802.11k тоже работает, но hostapd будет отдавать клиенту
отчёт о соседях, содержащий только сам себя: межточечная база соседей
заполняется извне через ubus (`rrm_nr_set`). Клиент при этом всё равно найдёт
вторую точку обычным сканированием и перейдёт через FT, просто чуть медленнее.

---

## 4. Схема сети

Роли:

* **Узел A** — шлюз. Держит uplink (`wan` или модем), DHCP-сервер, NAT,
  firewall. Адрес `192.168.11.1/24`.
* **Узлы B, C, …** — точки доступа. Ни NAT, ни DHCP-сервера. Адреса
  `192.168.11.2`, `192.168.11.3`, … в той же подсети, шлюз и DNS —
  `192.168.11.1`.

Все узлы — один L2-домен: мост `br-lan` объединяет Ethernet-порты, оба радио
в режиме точки доступа и (для беспроводных узлов) интерфейс `bat0`.

---

## 5. Конфигурация

Ниже фрагменты для `/etc/config/wireless` и `/etc/config/network`. Ключи и
идентификаторы — примеры, их надо заменить на свои.

### 5.1 Радио

Одинаково на всех узлах, кроме канала 2,4 ГГц.

```
config wifi-device 'radio0'
	option type 'mac80211'
	option band '5g'
	option channel '36'
	option htmode 'VHT80'
	option country 'RU'
	option cell_density '0'
	option disabled '0'

config wifi-device 'radio1'
	option type 'mac80211'
	option band '2g'
	option channel '1'
	option htmode 'HT20'
	option country 'RU'
	option cell_density '0'
	option disabled '0'
```

Канал 5 ГГц обязан совпадать на всех узлах, если backhaul беспроводной:
`num_different_channels = 1` в `mt76x02_if_comb[]` не даст радио развести
меш-интерфейс и точку доступа по разным каналам. Канал выбирается вне
диапазона DFS (36–48 или 149–165): при обнаружении радара точка обязана уйти
на другой канал, и меш в этот момент разваливается, потому что соседи остаются
на старом. По той же причине нельзя ставить `channel auto` — ACS выберет разные
каналы на разных узлах.

Канал 2,4 ГГц, наоборот, стоит развести (1 / 6 / 11): там нет меша, а
переход 802.11r между точками на разных каналах работает штатно.

При проводном backhaul оба ограничения снимаются: можно и `auto`, и DFS, и
разные каналы 5 ГГц на разных узлах — так даже лучше.

Секции `wifi-device` в 25.12.5 привязываются к железу через `option path`.
Реальные значения смотреть в выводе `ubus call network.wireless status` на
устройстве: `radio0`/`radio1` могут соответствовать разным диапазонам в
зависимости от порядка инициализации PCIe.

### 5.2 Точки доступа с 802.11r/k/v

Одинаково на всех узлах и на обоих диапазонах.

```
config wifi-iface 'ap5'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'HomeNet'
	option encryption 'psk2'
	option key 'ОБЩИЙ_ПАРОЛЬ_WIFI'
	option ieee80211w '1'
	option ieee80211r '1'
	option mobility_domain 'a1b2'
	option ft_over_ds '0'
	option ft_psk_generate_local '1'
	option reassociation_deadline '20000'
	option ieee80211k '1'
	option bss_transition '1'
	option wnm_sleep_mode '1'
	option disassoc_low_ack '1'
	option disabled '0'

config wifi-iface 'ap24'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'HomeNet'
	option encryption 'psk2'
	option key 'ОБЩИЙ_ПАРОЛЬ_WIFI'
	option ieee80211w '1'
	option ieee80211r '1'
	option mobility_domain 'a1b2'
	option ft_over_ds '0'
	option ft_psk_generate_local '1'
	option reassociation_deadline '20000'
	option ieee80211k '1'
	option bss_transition '1'
	option wnm_sleep_mode '1'
	option disassoc_low_ack '1'
	option disabled '0'
```

Что делает каждый ключ и откуда он берётся — по
`package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/ap.uc`,
функция `iface_roaming()` и `files-ucode/usr/share/schema/wireless.wifi-iface.json`:

* `ieee80211r '1'` — включает FT. Работает только при `wpa >= 2`, то есть с
  `psk2`, `sae`, `psk-sae`, `eap2`. В список `wpa_key_mgmt` добавляется `FT-PSK`
  (`iface.uc`, функция `wpa_key_mgmt`).
* `mobility_domain` — четыре шестнадцатеричные цифры, домен мобильности.
  Если не задать, ucode подставит `substr(md5(ssid + "\n"), 0, 4)`, то есть при
  одинаковом SSID значение и так совпадёт. Задавать явно всё равно стоит: это
  снимает зависимость от совпадения SSID байт в байт и делает конфигурацию
  самодокументируемой.
* `ft_psk_generate_local '1'` — ключевая опция для домашней сети. Точка
  вычисляет ответ FT локально из PSK, поэтому обмен PMK-R1 между точками не
  нужен вовсе, и **списки `r0kh`/`r1kh` не требуются**. Для `auth_type == psk`
  это значение и так по умолчанию, но лучше зафиксировать.
* `ft_over_ds '0'` — переход только «по воздуху». Значение по умолчанию в схеме
  тоже `false`. FT-over-DS быстрее на бумаге, но требует рабочего L2-пути между
  точками в момент перехода, а через меш это лишняя точка отказа. Включать
  имеет смысл только на проводном backhaul и только если замеры покажут выигрыш.
* `reassociation_deadline '20000'` — окно в TU (примерно 20 секунд), в течение
  которого целевая точка принимает реассоциацию после FT-аутентификации.
  Диапазон по схеме — 1000…65535.
* `ieee80211k '1'` — разворачивается в `rrm_neighbor_report` и
  `rrm_beacon_report` (`ap.uc`, строки 233–234).
* `bss_transition '1'` и `wnm_sleep_mode '1'` — 802.11v. **Требуют
  `wpad-mesh-mbedtls` или `wpad-mbedtls`**, см. раздел 3.1.
* `ieee80211w '1'` — MFP опционально. Не обязательно для FT-PSK, но нужно для
  `WPA-PSK-SHA256` и не ломает старых клиентов. Значение `2` (обязательный MFP)
  ставить только вместе с `encryption 'sae'`.

**Вариант с WPA3.** Если все клиенты современные, `encryption 'psk2'` меняется
на `'sae'` c `ieee80211w '2'`; тогда в `wpa_key_mgmt` попадёт `FT-SAE`. Для
смешанного парка есть `'psk-sae'` с `ieee80211w '1'` — этот режим добавляет и
`FT-SAE`, и `FT-PSK`. Начинать лучше с `psk2`: это исключает целый класс проблем
с клиентами при отладке роуминга.

**Когда всё-таки нужны `r0kh`/`r1kh`.** Только если `ft_psk_generate_local '0'`,
то есть при обмене ключами между точками. Тогда, если списки не заданы явно,
ucode подставляет универсальные записи с ключом `md5(mobility_domain + "/" + key)`:

```
	set_default(config, 'r0kh', [ 'ff:ff:ff:ff:ff:ff,*,' + ft_key ]);
	set_default(config, 'r1kh', [ '00:00:00:00:00:00,00:00:00:00:00:00,' + ft_key ]);
```

Явная форма для сети из трёх узлов выглядит так (одинаково на всех узлах,
MAC — адреса соответствующих BSS):

```
	option ft_psk_generate_local '0'
	option pmk_r1_push '1'
	list r0kh '02:11:22:33:44:01,ap-a,d3f1...'
	list r0kh '02:11:22:33:44:02,ap-b,d3f1...'
	list r0kh '02:11:22:33:44:03,ap-c,d3f1...'
	list r1kh '02:11:22:33:44:01,02:11:22:33:44:01,d3f1...'
	list r1kh '02:11:22:33:44:02,02:11:22:33:44:02,d3f1...'
	list r1kh '02:11:22:33:44:03,02:11:22:33:44:03,d3f1...'
	option nasid 'ap-a'
```

`nasid` при этом должен быть **разным** на каждом узле и совпадать с
`r0kh_id` в списке. Если `nasid` не задан, hostapd подставит BSSID без
двоеточий (`files/hostapd.uc`, строка 84) — этого достаточно, пока списки
формируются автоматически.

Для домашней сети рекомендуется первый вариант — `ft_psk_generate_local '1'`
без списков. Он проще, не требует синхронизации MAC-адресов и не ломается при
замене узла.

### 5.3 Меш-интерфейс 802.11s

Только на узлах без кабеля. Добавляется третьей секцией на радио 5 ГГц.

```
config wifi-iface 'mesh5'
	option device 'radio0'
	option network 'meshlink'
	option mode 'mesh'
	option mesh_id 'homemesh'
	option encryption 'sae'
	option key 'ОТДЕЛЬНЫЙ_ПАРОЛЬ_МЕША'
	option mesh_fwding '0'
	option mesh_rssi_threshold '-80'
	option disabled '0'
```

Как это обрабатывается (`supplicant.uc`, ветка `case 'mesh'`):
`mesh_id` подставляется в `ssid`, режим сети становится `mode=5`, частота
фиксируется (`fixed_freq`), а при любом `encryption` кроме `none`
принудительно ставится `key_mgmt = SAE`, и `key` уходит в `sae_password`.
Отсюда и требование к пакету: меш с шифрованием невозможен без
`CONFIG_MESH` **и** `CONFIG_SAE` в wpa_supplicant, то есть без
`wpad-mesh-*`.

`mesh_fwding '0'` — потому что пересылку берёт на себя batman-adv. Если
оставить `1`, кадры будут пересылаться дважды.

Пароль меша стоит сделать отдельным от пароля клиентской сети: он не
раздаётся людям и меняется только при перенастройке узлов.

### 5.4 batman-adv и мост

`/etc/config/network`, добавляется на всех узлах, участвующих в беспроводном
backhaul:

```
config interface 'bat0'
	option proto 'batadv'
	option routing_algo 'BATMAN_V'
	option bridge_loop_avoidance '1'
	option distributed_arp_table '1'
	option multicast_mode '1'
	option aggregated_ogms '1'
	option fragmentation '1'
	option gw_mode 'off'
	option orig_interval '5000'
	option hop_penalty '30'

config interface 'meshlink'
	option proto 'batadv_hardif'
	option master 'bat0'
```

Имя секции `bat0` значимо: `proto_batadv_setup()` в
`feeds/routing/batman-adv/files/lib/netifd/proto/batadv.sh` берёт имя
интерфейса прямо из имени секции (`local iface="$config"`) и выполняет
`batctl meshif "$iface" interface create`. Секция `meshlink` устройства не
имеет — устройство ей даёт `wifi-iface mesh5` через `option network 'meshlink'`,
а `proto_batadv_hardif_setup()` присоединяет его к `bat0`.

`bat0` включается в мост:

```
config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'lan1'
	list ports 'lan2'
	list ports 'bat0'
```

`bridge_loop_avoidance '1'` здесь обязателен: как только один и тот же узел
окажется и в меше, и на кабеле в тот же `br-lan`, без BLA получится петля.

`gw_mode 'off'` на всех узлах — шлюз в сети один и находится за обычным
мостом, механизм выбора шлюза batman-adv не используется.

### 5.5 Сеть узла-шлюза (A)

Ничего необычного, стандартная конфигурация OpenWrt:

```
config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.11.1'
	option netmask '255.255.255.0'
```

DHCP-сервер, firewall и uplink остаются как есть.

### 5.6 Сеть вторичного узла (B, C, …)

```
config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.11.2'
	option netmask '255.255.255.0'
	option gateway '192.168.11.1'
	list dns '192.168.11.1'
```

`/etc/config/dhcp`:

```
config dhcp 'lan'
	option interface 'lan'
	option ignore '1'
```

Интерфейс `wan` на вторичных узлах отключается или удаляется, а порт `wan`
переводится в `br-lan` — получается третий LAN-порт:

```
config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'lan1'
	list ports 'lan2'
	list ports 'wan'
	list ports 'bat0'
```

Firewall на вторичном узле трогать не обязательно: если зона `wan` осталась
без интерфейсов, она просто ничего не фильтрует. Важно лишь, чтобы зона `lan`
сохранила `input ACCEPT` — иначе веб-интерфейс окажется недоступен.

---

## 6. Что синхронизировать при вступлении узла в сеть

Разделение на «должно совпадать» и «должно различаться» — самая частая
причина неработающего роуминга и недоступной админки.

### Обязано совпадать на всех узлах

| Параметр | Где | Что будет, если не совпадёт |
| --- | --- | --- |
| `ssid` | оба `wifi-iface` в режиме `ap` | клиент видит две разные сети и переключается разрывом |
| `encryption` | оба `wifi-iface` | несовместимые RSN IE, роуминг невозможен |
| `key` | оба `wifi-iface` | то же |
| `mobility_domain` | оба `wifi-iface` | FT не применяется, переход идёт полной аутентификацией |
| `ieee80211r` | оба `wifi-iface` | точка без FT выпадает из роуминга |
| `ft_psk_generate_local` | оба `wifi-iface` | несогласованный способ вывода PMK-R1 |
| `ft_over_ds` | оба `wifi-iface` | клиент выбирает метод по данным точки, рассогласование даёт отказы |
| `mesh_id` | `wifi-iface` в режиме `mesh` | узел не найдёт соседей |
| ключ меша | `wifi-iface` в режиме `mesh` | пиринг не установится |
| канал 5 ГГц | `wifi-device` | меш не соберётся: одно радио — один канал |
| `htmode` 5 ГГц | `wifi-device` | пиринг может установиться, но с деградацией скорости |
| `country` | `wifi-device` | разные списки разрешённых каналов и мощностей |
| `routing_algo` | секция `bat0` | узлы с разными алгоритмами не видят друг друга |
| подсеть LAN | `network.lan` | узел вне общего L2-домена |

### Обязано различаться

| Параметр | Где | Что будет, если совпадёт |
| --- | --- | --- |
| `ipaddr` интерфейса `lan` | `network.lan` | **второй узел недоступен**, конфликт адресов |
| `hostname` | `system` | путаница в списке клиентов и в DHCP |
| канал 2,4 ГГц | `wifi-device` | лишние взаимные помехи (не фатально) |
| `nasid` / `r1_key_holder` | `wifi-iface`, только при `ft_psk_generate_local '0'` | FT не отработает |

BSSID различаются автоматически: они выводятся из MAC-адресов устройства.

### Отдельно про адрес

В сборке есть `files/etc/uci-defaults/99-almond.sh`, который на первой загрузке
чистой прошивки выставляет `network.lan.ipaddr=192.168.11.1` и hostname
`Almond`, после чего ставит флаг `almond.setup.done=1`. То есть **любой
свежепрошитый узел приходит с адресом 192.168.11.1**. Если включить второй
узел в сеть, не поменяв адрес, оба станут недоступны или доступен будет
случайный из них. Смена адреса должна быть первым шагом процедуры
присоединения, до подключения кабеля или поднятия меша.

---

## 7. Присоединение «в одно действие»

Требование сводится к тому, чтобы вся синхронизация из раздела 6 выполнялась
одной командой. Разумная форма — скрипт на узле-шлюзе, который выводит набор
параметров, и скрипт на новом узле, который их принимает.

Что должен сделать шаг присоединения на новом узле:

1. Выбрать свободный адрес в подсети. Простой и предсказуемый способ —
   пройти `192.168.11.2 … 192.168.11.20` и взять первый, не отвечающий на
   `arping` с интерфейса `br-lan`. Записать в `network.lan.ipaddr`, задать
   `gateway` и `dns`.
2. Задать уникальный `hostname`, например по последним трём байтам MAC.
3. Отключить DHCP-сервер: `dhcp.lan.ignore=1`.
4. Убрать интерфейс `wan` и перевести порт `wan` в `br-lan`.
5. Записать в обе секции `wifi-iface` режима `ap`: `ssid`, `encryption`, `key`,
   `ieee80211r`, `mobility_domain`, `ft_psk_generate_local`, `ft_over_ds`,
   `reassociation_deadline`, `ieee80211k`, `bss_transition`, `wnm_sleep_mode`.
6. Записать канал и `htmode` для радио 5 ГГц; для 2,4 ГГц выбрать канал из
   1/6/11, наименее занятый по результату `iw dev … scan`.
7. Если backhaul беспроводной: создать `wifi-iface` в режиме `mesh` с общими
   `mesh_id` и ключом, создать секции `bat0` и `meshlink`, добавить `bat0` в
   список портов `br-lan`.
8. `uci commit`, затем `/etc/init.d/network reload` и `wifi reload`.

Передача параметров между узлами — отдельный вопрос, и вариантов немного:
ввод одной строки с общими параметрами вручную, чтение из файла на USB-носителе
или обмен по временной служебной сети. Первый вариант проще всего и не требует
дополнительной инфраструктуры: строка содержит SSID, два пароля,
`mobility_domain`, `mesh_id` и канал 5 ГГц — этого достаточно.

Важно: смена адреса (шаг 1) и включение радио (шаг 8) должны быть в одной
транзакции `uci commit`, иначе узел успеет появиться в сети со старым адресом.

---

## 8. Узкие места на MT7621 и mt76

### 8.1 802.11r в драйвере

FT реализован целиком в hostapd и mac80211, специальной поддержки от драйвера
не требует. Ограничений со стороны `mt76x2` здесь нет. Единственное, на что
стоит смотреть — hostapd должен уметь ставить ключи через штатный путь
`set_key`, а `mt76x02_set_key()` поддерживает `CCMP`, что и нужно.

### 8.2 Групповые ключи меша считаются в software

В `mt76x02_util.c` есть явный отказ от аппаратного шифрования:

```
	/*
	 * The hardware does not support per-STA RX GTK, fall back
	 * to software mode for these.
	 */
	if ((vif->type == NL80211_IFTYPE_ADHOC ||
	     vif->type == NL80211_IFTYPE_MESH_POINT) &&
	    (key->cipher == WLAN_CIPHER_SUITE_TKIP ||
	     key->cipher == WLAN_CIPHER_SUITE_CCMP) &&
	    !(key->flags & IEEE80211_KEY_FLAG_PAIRWISE))
		return -EOPNOTSUPP;
```

Одноадресный трафик по мешу шифруется аппаратно (парные ключи), а
широковещательный и многоадресный — процессором. Плюс сам batman-adv не имеет
аппаратной разгрузки на MT7621: включённые в `99-almond.sh`
`flow_offloading` и `flow_offloading_hw` на транзит через `bat0` не
распространяются. Практический вывод: беспроводной backhaul нагружает
процессор заметно сильнее проводного, и на многоадресном трафике (обнаружение
устройств, потоковое вещание в локальной сети) это будет видно.

### 8.3 Одно радио — один канал

`mt76x02_if_comb[]` объявляет `num_different_channels = 1`. Меш-интерфейс и
точка доступа на радио 5 ГГц обязаны быть на одном канале. Отсюда:

* эфир 5 ГГц делится между клиентами и транзитом, пропускная способность
  падает примерно вдвое на каждом переходе;
* все узлы стоят на одном канале и мешают друг другу;
* DFS-каналы непригодны для беспроводного backhaul.

Лимит по интерфейсам не ограничивает: до 8 виртуальных интерфейсов на радио
(`.max_interfaces = 8`), маска маяков — 8 бит (`beacon_mask` типа `u8`), до 128
станций (`MT76x02_N_WCIDS`).

### 8.4 2,4 ГГц — только 802.11n

MT7602EN — 2×2 802.11n. Как backhaul непригоден: реальная пропускная
способность даже в идеальных условиях ниже, чем у 5 ГГц с одним переходом.
Использовать только для клиентов и только для дальних/медленных устройств.

### 8.5 WDS доступен, но не выбран

`mt76` не выставляет `SW_CRYPTO_CONTROL`, поэтому mac80211 автоматически
добавляет `AP_VLAN` и 4-адресный режим формально работает. Оставлено как
запасной вариант, если 802.11s на этом драйвере окажется нестабильным.

### 8.6 Что проверить сразу после включения

1. Поднялись ли оба BSS и меш-интерфейс на одном радио одновременно.
2. Не появились ли в `logread` сообщения об ошибках конфигурации hostapd —
   особенно `unknown configuration item` (признак того, что в образе остался
   `wpad-basic`).
3. Не деградирует ли скорость клиента на 5 ГГц после поднятия меша больше, чем
   вдвое.
4. Держится ли меш при `htmode VHT80`. Если пиринг нестабилен — понизить до
   `VHT40` и перепроверить.
5. Не появляются ли в `logread` сообщения о срабатывании bridge loop avoidance
   — это признак реальной петли, которую надо устранить топологически, а не
   лечить BLA.
6. Загрузка процессора при потоковой передаче через беспроводной backhaul.

---

## 9. Как проверить

### 9.1 Возможности драйвера

```
iw phy
iw phy phy0 info | grep -A20 "Supported interface modes"
iw phy phy0 info | grep -A10 "valid interface combinations"
```

Ожидается `mesh point` и `AP` в списке режимов, и комбинация с
`total <= 8, #channels <= 1`.

### 9.2 Что реально собрано в hostapd

```
grep -c . /lib/apk/packages/wpad-mesh-mbedtls.list
apk info -e wpad-mesh-mbedtls
hostapd -v
```

Проверка 802.11v на живой точке — наличие ubus-метода:

```
ubus list | grep hostapd
ubus -v list hostapd.wlan0 | grep bss_transition_request
```

Если метода нет, в образе стоит `wpad-basic-*`, и `option bss_transition` надо
убрать, иначе BSS не поднимется.

### 9.3 Конфигурация, которую сгенерировал ucode

```
cat /var/run/hostapd-phy0.conf
grep -E "mobility_domain|ft_|nas_identifier|rrm_|bss_transition|wpa_key_mgmt" /var/run/hostapd-phy0.conf
```

Признак правильной настройки: в `wpa_key_mgmt` присутствует `FT-PSK`,
`mobility_domain` одинаков на всех узлах, `ft_psk_generate_local=1`.

### 9.4 Состояние точки и клиентов

```
hostapd_cli -i wlan0 status
hostapd_cli -i wlan0 all_sta
iw dev wlan0 station dump
ubus call hostapd.wlan0 get_clients
```

### 9.5 Меш

```
iw dev mesh5 info
iw dev mesh5 station dump
iw dev mesh5 mpath dump
wpa_cli -i mesh5 status
```

`wpa_cli` требует пакета `wpa-cli`; управляющий сокет создаётся автоматически
в `/var/run/wpa_supplicant` (`supplicant.uc`, строка 275). Установленный пиринг — станция в `station dump` с `mesh plink: ESTAB`.

### 9.6 batman-adv

```
batctl meshif bat0 interface
batctl meshif bat0 originators
batctl meshif bat0 neighbors
batctl meshif bat0 statistics
batctl meshif bat0 backbonetable
batctl meshif bat0 ping <MAC другого узла>
batctl meshif bat0 throughputmeter <MAC другого узла>
```

`originators` должен содержать все остальные узлы. `backbonetable`
показывает, какие узлы BLA считает мостами в общий L2-домен: если там
неожиданно много записей, значит топология содержит петлю.

### 9.7 Что считать успешным переходом FT

Отслеживать на обеих точках одновременно:

```
logread -f | grep -E "wlan|hostapd|FT|assoc"
```

Признаки успешного быстрого перехода на **целевой** точке:

```
hostapd: wlan0: STA aa:bb:cc:dd:ee:ff IEEE 802.11: authentication OK (FT)
hostapd: wlan0: STA aa:bb:cc:dd:ee:ff WPA: FT authentication already completed - do not start 4-way handshake
hostapd: wlan0: STA aa:bb:cc:dd:ee:ff IEEE 802.11: associated
hostapd: wlan0: STA aa:bb:cc:dd:ee:ff RADIUS: starting accounting session
```

Ключевая строка — **`FT authentication already completed - do not start 4-way
handshake`**. Она означает, что четырёхстороннего рукопожатия не было, то есть
переход действительно быстрый. Если вместо неё видно
`WPA: pairwise key handshake completed (RSN)`, значит FT не сработал и клиент
переподключился обычным способом: надо проверить совпадение `mobility_domain`,
наличие `FT-PSK` в `wpa_key_mgmt` и то, что клиент вообще умеет 802.11r.

Признак на **исходной** точке:

```
hostapd: wlan0: STA aa:bb:cc:dd:ee:ff IEEE 802.11: disassociated
```

без сообщений `deauthenticated due to inactivity`.

Со стороны клиента (если это устройство на OpenWrt):

```
wpa_cli -i wlan0 status | grep key_mgmt
```

должно быть `key_mgmt=FT-PSK`.

Практическая проверка бесшовности: запустить с клиента непрерывный `ping` до
шлюза и физически пройти между точками. Приемлемый результат — потеря нуля или
одного-двух пакетов. Потеря 5–20 пакетов означает полное переподключение,
то есть FT не работает.

### 9.8 Проверка 802.11k

```
ubus call hostapd.wlan0 rrm_nr_get_own
ubus call hostapd.wlan0 rrm_nr_list
```

Без внешнего наполнения `rrm_nr_list` будет содержать только саму точку. После
установки `usteer` там должны появиться соседние узлы.

### 9.9 Проверка доступности админок

С клиента, подключённого к любому узлу:

```
for i in 1 2 3; do
	echo -n "192.168.11.$i: "
	curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 http://192.168.11.$i/
done
```

Все узлы должны отвечать `200` или `302`. Если какой-то не отвечает —
скорее всего конфликт адресов, см. раздел 6.

---

## 10. Что осталось непроверенным

Ниже — то, что нельзя подтвердить без стенда с двумя устройствами. Считать
это гипотезами, а не фактами.

1. **Стабильность 802.11s на `mt76x2` в связке AP + mesh на одном радио.**
   Драйвер режим объявляет, но одновременная работа маяка точки доступа и
   меш-маяка на одном чипе — это то, что проверяется только вживую.
2. **802.11s при `htmode VHT80`.** Возможно, потребуется понизить до `VHT40`.
3. **Реальная пропускная способность через один переход по мешу.** Ожидание —
   не выше 40–45 % от скорости прямого подключения к 5 ГГц, но конкретная
   цифра зависит от расстояния между узлами.
4. **Поведение клиентов при FT.** Часть устройств игнорирует 802.11r либо
   переходит только при очень слабом сигнале. Это не настраивается со стороны
   точки — только подсказками 802.11v, и только для тех клиентов, кто их
   слушает.
5. **Влияние на процессор.** Программное шифрование групповых ключей меша плюс
   batman-adv без разгрузки — нагрузку надо измерить, а не оценивать.
