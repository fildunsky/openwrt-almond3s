# openwrt-almond3s

*[Русская версия](README.ru.md)*

LCD support for the **Securifi Almond 3S** and **Almond 3** on OpenWrt: a kernel
driver for the 2.8" panel (ILI9341 on the 3S, ST7789V on the Almond 3) with its
SX8650 touchscreen, and a userspace dashboard that shows network, modem, Wi-Fi,
traffic and weather right on the device. The board is detected from the DT
compatible, the same packages serve both.

The repository is an OpenWrt feed with three packages:

| Package | What it is |
|---|---|
| `kmod-lcd-almond3s` | kernel driver: RGB565 framebuffer at `/dev/lcd`, touch, battery gauge over the PIC16LF1509 |
| `lcd-ui-almond3s` | userspace: renderer, touch daemon, data collector and the ucode UI |
| `nes-almond3s` | optional NES emulator (QuickNES) with a browser gamepad served over Wi-Fi |

## Screens

<table>
<tr>
<td align="center"><img src="docs/screens/menu.png" width="260"><br><sub>Main menu</sub></td>
<td align="center"><img src="docs/screens/modem.png" width="260"><br><sub>Modem: signal and cell</sub></td>
<td align="center"><img src="docs/screens/wifi.png" width="260"><br><sub>Wi-Fi with join QR codes</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/screens/traffic.png" width="260"><br><sub>Traffic, live curves</sub></td>
<td align="center"><img src="docs/screens/services.png" width="260"><br><sub>Service reachability</sub></td>
<td align="center"><img src="docs/screens/weather.png" width="260"><br><sub>Weather</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/screens/vpn.png" width="260"><br><sub>VPN: SSClash groups</sub></td>
<td align="center"><img src="docs/screens/settings.png" width="260"><br><sub>Settings</sub></td>
<td align="center"><img src="docs/screens/night.png" width="260"><br><sub>Night schedule</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/screens/alarm.png" width="260"><br><sub>Alarm clock</sub></td>
<td align="center"><img src="docs/screens/info.png" width="260"><br><sub>System info</sub></td>
<td align="center"><img src="docs/screens/games.png" width="260"><br><sub>Games list</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/screens/game-mario.png" width="260"><br><sub>NES emulator</sub></td>
<td align="center"><img src="docs/screens/game-mario-select.png" width="260"><br><sub>On-screen gamepad</sub></td>
<td align="center"><img src="docs/screens/terminal.png" width="260"><br><sub>Shell with on-screen keyboard</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/screens/saver-widgets-overview.png" width="260"><br><sub>Widgets: overview</sub></td>
<td align="center"><img src="docs/screens/saver-widgets-modem.png" width="260"><br><sub>Widgets: modem</sub></td>
<td align="center"><img src="docs/screens/saver-widgets-system.png" width="260"><br><sub>Widgets: system</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/screens/saver-weather.png" width="260"><br><sub>Weather screensaver</sub></td>
<td align="center"><img src="docs/screens/saver-matrix.png" width="260"><br><sub>Matrix screensaver</sub></td>
<td align="center"><img src="docs/screens/saver-logo.png" width="260"><br><sub>Logo screensaver</sub></td>
</tr>
</table>

## What it does

* **Network** — uplink list (modem, Wi-Fi STA, wired) with addresses and metrics;
  tapping a card makes that uplink primary
* **Wi-Fi** — both bands with client counts, on/off toggles and a QR code to join
* **Modem** — operator, signal ladder with RSRP/RSRQ/SINR/RSSI, band, cell,
  temperature and a second page with cell details and neighbours
* **SMS** — inbox through `luci-app-5gmodem`: multipart messages glued back
  together, unread marks synced both ways, full-screen reading with paging
* **Traffic** — RX/TX for the modem and the current uplink, live curves,
  tap zooms one graph full screen
* **Services** — reachability and latency for a configurable host list
* **Speedtest** — download/upload run right from the screen
* **Weather** — current conditions from Open-Meteo with a city picker
* **VPN** — SSClash: on/off, proxy groups, node latency, switching a node
* **Games** — NES emulator (QuickNES): touch buttons, USB keyboard or a phone
  gamepad in the browser over Wi-Fi, opened by a QR code
* **Terminal** — a real shell on the panel (`forkpty` + libvterm) with an
  on-screen keyboard: `ls`, `cd`, line editing, `top` and `vi` all work
* **Alarm** — melody, time, one-shot or repeating; the schedule is written into
  cron, so it fires even with the screen asleep
* **Battery** — charge, charging state, drain rate and remaining time
* **Info** — model, firmware, kernel, uptime, load, memory, storage, LAN
* **Settings** — brightness, warm filter, language, 180° rotation, menu icons,
  screensaver style and timeout, night schedule, LED, icon editor, panel tuning
* **Screensavers** — widgets (three auto-rotating pages of cards), weather with
  a big clock, plain clock, one-line header, Matrix rain and the Almond logo
* **Night mode** — a schedule that dims the screen, warms the colours, switches
  the screensaver to green and can turn the access points off until morning
* **Power** — reboot, shutdown and a modem restart from the menu

## Hardware

* MT7621A, 256 MB RAM, 64 MB flash
* Panel S028HQ29NN (ILI9341), 320×240, 8-bit 8080-II bus bit-banged on GPIO 13–18 and 22–27
* Touch controller SX8650 on the palmbus I²C
* PIC16LF1509 — battery gauge, buzzer, LED
* Battery, charged by a BQ24133

The Almond 3 differs: an ST7789V panel on the same bus, a PIC16F1503 without a
battery or modem, and an RGB front LED (exposed as `red:status`, `green:status`,
`blue:status`; the colour is picked on the LED page).

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
apk add --allow-untrusted /tmp/kmod-lcd-almond3s-*.apk /tmp/lcd-ui-almond3s-*.apk
reboot
```

`nes-almond3s-*.apk` is the optional NES emulator — install it the same way if
you want the Games page to run anything.

**A kernel module is tied to the exact kernel build it was compiled against**
(vermagic). The prebuilt `kmod` will refuse to load on any other OpenWrt
version — for those, build it from source as described below. `lcd-ui-almond3s` itself
is not tied to the kernel and installs on any 25.12.x.

### Build from source

```sh
echo "src-git almond3s https://github.com/fildunsky/openwrt-almond3s.git" >> feeds.conf.default
./scripts/feeds update almond3s
./scripts/feeds install -a -p almond3s
```

Then in `make menuconfig`:

* `Kernel modules` → `Video Support` → `kmod-lcd-almond3s`
* `Utilities` → `lcd-ui-almond3s`

and `make package/feeds/almond3s/lcd-almond3s/compile package/feeds/almond3s/lcd-ui-almond3s/compile`,
or just build the whole image.

While hacking on the code, point the feed at a local checkout instead of
GitHub, so a rebuild picks up your edits without a push:

```
src-link almond3s /home/user/openwrt-almond3s
```

## Configuration

Everything lives in `/etc/config/almond3s` and most of it is also reachable from the
screen itself, under `Menu → More → Display`:

```sh
uci set almond3s.display.lang='ru'          # ru | en
uci set almond3s.display.saver='60'          # seconds until the screensaver, 0 disables it
uci set almond3s.display.saver_style='clock' # clock | full (weather) | line | off
uci set almond3s.display.night='1'           # night mode for the screensaver
uci set almond3s.display.night_from='22'      # from this hour
uci set almond3s.display.night_to='6'         # until this hour
uci set almond3s.weather.city='Voronezh'
uci commit almond3s
/etc/init.d/almond3s-lcd restart
```

`saver_style=off` blanks the panel instead of drawing a screensaver — the
backlight goes out via the driver's ioctl, redrawing stops, and a touch on the
dark screen brings it back. The same switch is available by hand, and can be
bound to any button that produces events:

```sh
/etc/almond3s/scripts/screen.sh off|on|toggle

# /etc/rc.button/tamper
[ "$ACTION" = released ] && [ "$SEEN" -lt 2 ] && /etc/almond3s/scripts/screen.sh toggle
```

Blanking drives the backlight LED from the device tree (GPIO 31, exported as
`/sys/class/leds/:power`) rather than the driver's own ioctl. Both flip the same
pin, but going through the LED keeps the kernel's idea of `brightness` in sync —
otherwise the next LED trigger reload would silently light the panel back up.
The driver ioctl (`almond3s-lcd b 0|1`) stays as a fallback when the DTS has no
such LED. The `Blank now` button on the Display page does the same thing on
demand.

The **power button is not available to software** on this device: it is wired to
the PIC, which handles the press in its own firmware — a short press produces no
kernel event at all. Only `reset` (GPIO 32, `linux,code = KEY_RESTART`) and
`tamper` (GPIO 28, `BTN_0`) reach the kernel. Note that the hotplug script name
comes from the key code, not from the DTS label: the tamper button runs
`/etc/rc.button/BTN_0`.

Weather is fetched by `/etc/almond3s/scripts/weather_fetch.sh` from wttr.in and the
service pings by `/etc/almond3s/scripts/svcping.sh`; both are put on cron by the
package on install.

## Notes on the pages

The page list is above; a few things worth knowing beyond it:

* **LED** — the white LED above the screen: on/off, and blinking while unread
  SMS remain. It hangs off the PIC, not a GPIO (port E bit 4), so it is driven
  by `almond3s-lcd led on|off|blink`
* **Sound** — the piezo buzzer, also on the PIC (port C bit 0). The stock
  tones were recovered from the factory firmware: `almond3s-lcd bell` (the door
  chime, 1975/1675 Hz), `ambulance`, `police`, plus `tone <hz> <ms> ...` for
  up to 64 notes and `volume 1..3`
* Header shows an envelope when `luci-app-5gmodem` reports unread SMS

The 5x7 font carries ASCII, Cyrillic and the punctuation that actually turns up
in operator SMS and on the pages: `° « » № ₽ → ← ↑ ↓ ↖ ↗ ↘ ↙ • ✓ … – — “ ” ‘ ’`.
Anything else falls back to a blank rather than a garbage glyph.

The driver pushes only the rows that actually changed, and the UI redraws a page
only when something on it changed — an idle screen sends no frames at all. A full
repaint costs 75 ms of progressive update, which is visible as flicker once the
backlight is dimmed.

## Debugging the layout

`almond3s-lcdshot` dumps the framebuffer as a PPM, so you can see exactly what the panel
shows without a camera:

```sh
ssh root@192.168.1.1 almond3s-lcdshot > shot.ppm
```

## Known limitations

* A full frame flush takes ~75 ms — the bus is bit-banged and the driver
  redraws the whole screen. Dirty-row updates are on the to-do list.
* Brightness is done by **scaling the picture**: the driver dims pixels on the
  way to the panel while the backlight stays lit. Steps on the Display page are
  10/20/35/50/70/85 /100 %, by hand `almond3s-lcd gray 0..255`; `almond3s-lcd level`
  prints both levels. The screensaver dims further during night-mode hours.

  The driver also carries a software PWM for the backlight itself
  (`almond3s-lcd dim 0..255`, GPIO 31 via hrtimer). It gives real darkness and is
  used to switch the panel off, but it is unusable for smooth dimming: the panel
  updates progressively, so a blinking backlight shows it mid-update — visible as
  flicker on every repaint. The stock firmware had no brightness control at all —
  its "BackLight Settings" screen only picks the hours the backlight stays on.
* Zigbee (EM357) is reachable but unsupported here: the chip answers EZSP v4
  (EmberZNet 5.1.0) on `/dev/ttyS2` at 57600, which modern coordinators refuse.
  The siren is not supported either.
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
