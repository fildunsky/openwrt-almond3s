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
apk add --allow-untrusted /tmp/kmod-lcd-almond3s-*.apk /tmp/lcd-ui-*.apk
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

and `make package/feeds/almond3s/lcd-almond3s/compile package/feeds/almond3s/lcd-ui/compile`,
or just build the whole image.

While hacking on the code, point the feed at a local checkout instead of
GitHub, so a rebuild picks up your edits without a push:

```
src-link almond3s /home/user/openwrt-almond3s
```

## Configuration

Everything lives in `/etc/config/lcd` and most of it is also reachable from the
screen itself, under `Menu → More → Display`:

```sh
uci set lcd.display.lang='ru'          # ru | en
uci set lcd.display.saver='300'        # seconds until the screensaver, 0 disables it
uci set lcd.display.saver_style='full' # full (weather) | clock | line | off
uci set lcd.weather.city='Voronezh'
uci commit lcd
/etc/init.d/lcd_ui restart
```

`saver_style=off` blanks the panel instead of drawing a screensaver — the
backlight goes out via the driver's ioctl, redrawing stops, and a touch on the
dark screen brings it back. The same switch is available by hand, and can be
bound to any button that produces events:

```sh
/etc/lcd/scripts/screen.sh off|on|toggle

# /etc/rc.button/tamper
[ "$ACTION" = released ] && [ "$SEEN" -lt 2 ] && /etc/lcd/scripts/screen.sh toggle
```

Blanking drives the backlight LED from the device tree (GPIO 31, exported as
`/sys/class/leds/:power`) rather than the driver's own ioctl. Both flip the same
pin, but going through the LED keeps the kernel's idea of `brightness` in sync —
otherwise the next LED trigger reload would silently light the panel back up.
The driver ioctl (`touch_poll b 0|1`) stays as a fallback when the DTS has no
such LED. The `Blank now` button on the Display page does the same thing on
demand.

The **power button is not available to software** on this device: it is wired to
the PIC, which handles the press in its own firmware — a short press produces no
kernel event at all. Only `reset` (GPIO 32, `linux,code = KEY_RESTART`) and
`tamper` (GPIO 28, `BTN_0`) reach the kernel. Note that the hotplug script name
comes from the key code, not from the DTS label: the tamper button runs
`/etc/rc.button/BTN_0`.

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
* **SMS** — the inbox read through `5gmodem`'s bridge: multipart messages are
  glued back together, unread ones are marked, and a message opens full-screen
  with paging when it does not fit. Reachable from the menu or by tapping the
  envelope in the header. The unread mark subtracts `5gmodem`'s live `seen`
  state, so the envelope clears the moment a message is read elsewhere
* **Services** — reachability of YouTube, Telegram, GitHub and others; tapping a
  card rechecks that one service immediately
* **Weather** — current conditions with a city picker
* **Display** — screensaver style and timeout, language
* Header shows an envelope when `luci-app-5gmodem` reports unread SMS

The 5x7 font carries ASCII, Cyrillic and the punctuation that actually turns up
in operator SMS and on the pages: `° « » № ₽ → ← ↑ ↓ ↖ ↗ ↘ ↙ • ✓ … – — “ ” ‘ ’`.
Anything else falls back to a blank rather than a garbage glyph.

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
