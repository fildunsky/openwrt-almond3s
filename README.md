# openwrt-almond3s

*[Русская версия](README.ru.md)*

LCD support for the **Securifi Almond 3S** on OpenWrt: a kernel driver for the
2.8" ILI9341 panel with its SX8650 touchscreen, and a userspace dashboard that
shows network, modem, Wi-Fi, traffic and weather right on the device.

The repository is an OpenWrt feed with two packages:

| Package | What it is |
|---|---|
| `kmod-lcd-almond3s` | kernel driver: RGB565 framebuffer at `/dev/lcd`, touch, battery gauge over the PIC16LF1509 |
| `lcd-ui` | userspace: renderer, touch daemon, data collector and the ucode UI |

## Hardware

* MT7621A, 256 MB RAM, 64 MB flash
* Panel S028HQ29NN (ILI9341), 320×240, 8-bit 8080-II bus bit-banged on GPIO 13–18 and 22–27
* Touch controller SX8650 on the palmbus I²C
* PIC16LF1509 — battery gauge, buzzer, LED
* Battery, charged by a BQ24133

## Requirements

* Device support for the Almond 3S. It is not in OpenWrt yet — see
  [PR #22141](https://github.com/openwrt/openwrt/pull/22141). The DTS must free
  the panel pins, that is `&state_default` with
  `groups = "jtag", "wdt", "rgmii2"`.
* [`luci-app-5gmodem`](https://github.com/fildunsky/luci-app-5gmodem) —
  **optional but recommended**. The modem pages, the service pings and the
  unread-SMS envelope all read its data. Without it the LCD still works, those
  cards are simply empty.
* `qrencode` — pulled in as a dependency, used for the Wi-Fi QR code.

## Install

### Prebuilt packages

`prebuilt/25.12.5/` holds packages built for **OpenWrt 25.12.5**
(`r33051-f5dae5ece4`, kernel 6.12.94):

```sh
scp prebuilt/25.12.5/*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/kmod-lcd-almond3s-6.12.94-r1.apk /tmp/lcd-ui-1.apk
reboot
```

**A kernel module is tied to the exact kernel build it was compiled against**
(vermagic). The prebuilt `kmod` will refuse to load on any other OpenWrt
version — for those, build it from source as described below. `lcd-ui` itself
is not tied to the kernel and installs on any 25.12.x.

### Build from source

```sh
echo "src-git almond3s https://github.com/fildunsky/openwrt-almond3s.git" >> feeds.conf.default
./scripts/feeds update almond3s
./scripts/feeds install -a -p almond3s
```

Then in `make menuconfig`:

* `Kernel modules` → `Video Support` → `kmod-lcd-almond3s`
* `Utilities` → `lcd-ui`

and `make package/kernel/lcd-almond3s/compile package/utils/lcd-ui/compile`, or
just build the whole image.

## Configuration

Everything lives in `/etc/config/lcd` and most of it is also reachable from the
screen itself, under `Menu → More → Display`:

```sh
uci set lcd.display.lang='ru'          # ru | en
uci set lcd.display.saver='300'        # seconds until the screensaver, 0 disables it
uci set lcd.display.saver_style='full' # full (weather) | clock | line
uci set lcd.weather.city='Voronezh'
uci commit lcd
/etc/init.d/lcd_ui restart
```

Weather is fetched by `/etc/lcd/scripts/weather_fetch.sh` from wttr.in and the
service pings by `/etc/lcd/scripts/svcping.sh`; both are put on cron by the
package on install.

## What is on the screen

* **Network** — WWAN and WAN addresses, Wi-Fi clients
* **Wi-Fi** — SSIDs, clients, a QR code to join the network
* **Modem** — operator, phone number, signal ladder, carrier aggregation,
  temperature, and a second page with cell details (TAC, CID, bandwidth,
  pathloss, CQI, MIMO, neighbouring cells)
* **Traffic** — RX/TX with log-scaled history graphs
* **Info** — uptime, load, memory, battery
* **Services** — reachability of YouTube, Telegram, GitHub and others; tapping a
  card rechecks that one service immediately
* **Weather** — current conditions with a city picker
* **Display** — screensaver style and timeout, language
* Header shows an envelope when `luci-app-5gmodem` reports unread SMS

## Debugging the layout

`lcdshot` dumps the framebuffer as a PPM, so you can see exactly what the panel
shows without a camera:

```sh
ssh root@192.168.1.1 lcdshot > shot.ppm
```

## Known limitations

* A full frame flush takes ~75 ms — the bus is bit-banged and the driver
  redraws the whole screen. Dirty-row updates are on the to-do list.
* Backlight brightness cannot be changed yet. On the stock firmware it went
  through the PIC (`ioctl(/dev/almond_backlight, 14, N)`); this is still being
  worked out.
* Zigbee (EM357) and the siren are not supported.
* The driver talks to the GPIO block directly instead of going through pinctrl,
  which is why it is a feed package and not something submitted upstream yet.

## Credits

* The panel driver grew out of the research and code by
  **[iSublimity](https://github.com/isublimity/Securifi-Almond-3S)** — the bus
  timing, the PIC protocol and the SX8650 sequence come from there.
* The UI layout is based on **[zipfo/almond-lcd-menu](https://github.com/zipfo/almond-lcd-menu)**,
  including the idea of the weather widget.

## License

GPL-2.0-only, same as OpenWrt itself.
