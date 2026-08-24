#!/usr/bin/env python3
# Веб-морда эмулятора Almond 3S: отдаёт кадры фреймбуфера (RGB565 320x240) в
# canvas, превращает клики в тапы (/tmp/.lcd_touch) и умеет тянуть живые
# данные с настоящего роутера по ssh (поле IP на странице). Только stdlib.
import json
import os
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FB = "/tmp/almond3s-emu/lcd.fb"
FB_SIZE = 320 * 240 * 2
TOUCH = "/tmp/.lcd_touch"
GOTO = "/tmp/.lcd_goto"
PORT = 8380

# Файлы, которые забираем с живого устройства как есть.
SYNC_FILES = ["/tmp/lcd_data.json", "/tmp/lcd_zig_peers.json", "/tmp/lcd_weather.txt",
              "/tmp/5gmodem_speedtest.json"]
# Источники для адаптера: роутер без LCD-стека (нет lcd_data.json), но с
# 5gmodem и ubus - собираем минимальный lcd_data.json сами.
ADAPT_FILES = ["/tmp/5gmodem_tele.json"]
SEED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed")

source = {"ip": "", "password": "", "status": "фикстуры (без устройства)", "ok": False}
source_lock = threading.Lock()
# Окно ускоренного опроса: пока идёт спидтест, тянем файлы раз в секунду.
fast_until = [0.0]


def make_askpass(password):
    fd, path = tempfile.mkstemp(prefix="emu_ap_")
    os.write(fd, ("#!/bin/sh\necho '%s'\n" % password.replace("'", "'\\''")).encode())
    os.close(fd)
    os.chmod(path, 0o700)
    return path


def synth_wifi_clients(chunks):
    # hostapd get_clients (JSON на каждый интерфейс) + dhcp.leases для имён.
    names = {}
    for line in chunks.get("wifi:leases", b"").decode(errors="replace").splitlines():
        f = line.split()
        if len(f) >= 4:
            names[f[1].lower()] = f[3]
    clients = []
    blob = chunks.get("wifi:clients", b"").decode(errors="replace")
    depth, start = 0, None
    for i, ch in enumerate(blob):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    obj = json.loads(blob[start:i + 1])
                except ValueError:
                    obj = {}
                for mac, inf in (obj.get("clients") or {}).items():
                    clients.append({
                        "mac": mac.upper(),
                        "name": names.get(mac.lower(), mac[-8:]),
                        "signal": inf.get("signal"),
                    })
    return clients


def sig_from_rsrp(rsrp):
    # Грубая шкала RSRP(dBm) -> проценты для гейджа, если sig не пришёл.
    if rsrp is None:
        return None
    p = int((rsrp + 120) * 100 / 44)
    return max(0, min(100, p))


def band_tok(v):
    # "B7 (2600 MHz) DL: @20 MHz" -> "B7"; None/пусто/"-" -> "".
    if not v or v == "-":
        return ""
    return str(v).split()[0].split("(")[0].strip()


def mode_tok(v):
    # "LTE | B7 (2600 MHz) ..." -> "LTE"; коллектор нормализует к 4G/4G+/5G,
    # но короткого имени достаточно, ярлык дорисует UI по несущим.
    if not v:
        return ""
    head = str(v).split("|")[0].strip()
    return {"LTE": "4G", "WCDMA": "3G", "NR5G": "5G", "5G": "5G"}.get(head, head)


def build_ca(met):
    # Цепочка несущих: PCC + активные SCC (как в 5gmodem), токены бендов.
    segs = [t for t in [band_tok(met.get("pband"))] if t]
    for i in range(1, 5):
        b = band_tok(met.get("s%dband" % i))
        if b and met.get("s%dstate" % i) == "activated":
            segs.append(b)
    return "+".join(segs)


def synth_lcd_data(chunks):
    def j(name):
        try:
            return json.loads(chunks.get(name, b"") or b"null")
        except ValueError:
            return None
    tele = j("/tmp/5gmodem_tele.json") or {}
    met = j("modem:metrics") or {}
    info = j("ubus:system:info") or {}
    board = j("ubus:system:board") or {}
    if not tele and not info and not met:
        return None
    import re as _re
    _pr = chunks.get("ping:ya", b"").decode(errors="replace")
    _m = _re.search(r"time=([0-9.]+)", _pr) or _re.search(r"=\s*[0-9.]+/([0-9.]+)", _pr)
    ping_raw = float(_m.group(1)) if _m else None

    def j2(name):
        try:
            return float(chunks.get(name, b"").decode().strip())
        except (ValueError, AttributeError):
            return None

    def mnum(k):
        v = met.get(k)
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return None
    mem = info.get("memory", {})
    data = {
        "uptime": info.get("uptime", 0),
        "mem_free_mb": int(mem.get("free", 0) / 1048576),
        "mem_total_mb": int(mem.get("total", 0) / 1048576),
        "battery": {"no_battery": True, "percent": 0, "charging": False},
        "wifi": {"clients": synth_wifi_clients(chunks)},
        "ping": {"google_ms": int(ping_raw) if ping_raw else -1},
        "lte": {
            "modem": met.get("modem") or met.get("alias") or board.get("model", "router"),
            "operator": met.get("operator_name") or tele.get("oper", ""),
            "mode": mode_tok(met.get("mode")) or tele.get("mode", ""),
            "band": band_tok(met.get("pband")) or tele.get("band", ""),
            "signal": tele.get("sig") or sig_from_rsrp(mnum("rsrp")),
            "rsrp": mnum("rsrp"), "rsrq": mnum("rsrq"), "sinr": mnum("sinr"),
            "rssi": mnum("rssi"), "csq": mnum("csq"),
            "temp": mnum("mtemp"), "apn": met.get("iface_apn", ""),
            "ip": met.get("ipaddr", ""), "imei": met.get("imei", ""),
            "roaming": 1 if met.get("roaming") in ("1", 1, "yes", "true") else 0,
            "conn_time": mnum("conn_time_sec"),
            "rx_bytes": mnum("rx"), "tx_bytes": mnum("tx"),
            # Идентификаторы соты страница читает из lte.* напрямую (не из cell).
            "mcc": met.get("operator_mcc", ""), "mnc": met.get("operator_mnc", ""),
            "pci": mnum("pci"), "earfcn": mnum("earfcn"),
            "enbid": mnum("enbid"), "cid": mnum("cid_dec"),
            "uecat": met.get("uecat", ""), "cqi": met.get("cqi", ""),
            "txpower": met.get("txpower", ""), "pathloss": met.get("pathloss", ""),
            "volte": met.get("volte", ""), "pmimo": met.get("pmimo", ""),
            "cell": {
                "lac": met.get("lac_hex", ""), "cid_hex": met.get("cid_hex", ""),
                "cqi": met.get("cqi", ""), "bandwidth": met.get("bandwidth", ""),
                "uecat": met.get("uecat", ""), "txpower": met.get("txpower", ""),
                "mcc": met.get("operator_mcc", ""), "mnc": met.get("operator_mnc", ""),
                "tac": met.get("tac_hex", ""), "cid": met.get("cid_hex", ""),
                "pci": mnum("pci"), "earfcn": mnum("earfcn"),
                "enbid": met.get("enbid", ""), "bandwidth": met.get("bandwidth", ""),
                "s1band": band_tok(met.get("s1band")), "s1state": met.get("s1state", ""),
                "s1pci": mnum("s1pci"), "s1earfcn": mnum("s1earfcn"),
                "s2band": band_tok(met.get("s2band")), "s2state": met.get("s2state", ""),
                "s3band": band_tok(met.get("s3band")), "s3state": met.get("s3state", ""),
                "ca": build_ca(met),
            },
        },
    }
    return json.dumps(data, ensure_ascii=False).encode()


RSH = "/tmp/almond3s-emu/rsh"
AP = "/tmp/almond3s-emu/ap"


def write_rsh(ip, password):
    if not ip:
        for f in (RSH, AP, "/tmp/almond3s-emu/rsh.conf"):
            try:
                os.unlink(f)
            except OSError:
                pass
        return
    with open(AP, "w") as f:
        f.write("#!/bin/sh\necho '%s'\n" % password.replace("'", "'\\''"))
    os.chmod(AP, 0o700)
    with open(RSH, "w") as f:
        f.write("#!/bin/sh\n"
                "exec env -u SSH_AUTH_SOCK SSH_ASKPASS=%s SSH_ASKPASS_REQUIRE=force "
                "setsid -w ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "
                "root@%s \"$@\"\n" % (AP, ip))
    os.chmod(RSH, 0o700)
    # Для интерактивного терминала (forkpty) нужен ssh БЕЗ setsid - его
    # параметры кладём отдельным конфигом, который читает forward-ash.
    with open("/tmp/almond3s-emu/rsh.conf", "w") as f:
        f.write("RSH_IP='%s'\nRSH_AP='%s'\n" % (ip, AP))


def parse_uci_export(text):
    # Формат `uci export`: config <тип> '<имя>' / option k 'v' / list k 'v'.
    out = {}
    sec = None
    anon = 0
    for line in text.splitlines():
        t = line.strip()
        if t.startswith("config "):
            parts = t.split(None, 2)
            styp = parts[1]
            name = parts[2].strip("'") if len(parts) > 2 else "@%s[%d]" % (styp, anon)
            anon += 1
            sec = out.setdefault(name, {".type": styp, ".name": name})
        elif sec is not None and t.startswith("option "):
            _, k, v = t.split(None, 2)
            sec[k] = v.strip("'")
        elif sec is not None and t.startswith("list "):
            _, k, v = t.split(None, 2)
            sec.setdefault(k, [])
            if isinstance(sec[k], list):
                sec[k].append(v.strip("'"))
    return out


MIRROR_CONFIGS = ["wireless", "network", "5gmodem", "ssclash", "firewall"]


def merge_uci_mirror(chunks):
    # Живые конфиги роутера подмешиваются в базу стаба; локальная секция
    # almond3s (настройки самого эмулятора) не трогается.
    try:
        with open("/tmp/almond3s-emu/uci.json") as f:
            db = json.load(f)
    except Exception:
        db = {}
    changed = False
    for cfg in MIRROR_CONFIGS:
        body = chunks.get("uci:" + cfg, b"").decode(errors="replace")
        if body.strip():
            db[cfg] = parse_uci_export(body)
            changed = True
    if changed:
        with open("/tmp/almond3s-emu/uci.json.emu_new", "w") as f:
            json.dump(db, f, ensure_ascii=False)
        os.replace("/tmp/almond3s-emu/uci.json.emu_new", "/tmp/almond3s-emu/uci.json")


def fetch_once(ip, password):
    marker = "===EMU==="
    cmd = "for f in %s; do echo '%s'$f; cat $f 2>/dev/null; done; " % (
        " ".join(SYNC_FILES + ADAPT_FILES), marker)
    cmd += "echo '%subus:system:info'; ubus call system info 2>/dev/null; " % marker
    cmd += "echo '%subus:system:board'; ubus call system board 2>/dev/null; " % marker
    cmd += "echo '%swifi:clients'; for h in $(ubus list 2>/dev/null | grep '^hostapd\\.'); do " % marker
    cmd += "ubus call $h get_clients 2>/dev/null; done; "
    cmd += "echo '%swifi:leases'; cat /tmp/dhcp.leases 2>/dev/null; " % marker
    # Полные метрики модема: активный слот пишет 5gmodem_metrics_<path>.json;
    # берём самый свежий.
    cmd += "echo '%smodem:metrics'; cat $(ls -t /tmp/5gmodem_metrics_*.json 2>/dev/null | head -1) 2>/dev/null; " % marker
    cmd += "echo '%ssms:new'; cat /tmp/5gmodem_sms_new.json 2>/dev/null; " % marker
    cmd += "echo '%sproc:netdev'; cat /proc/net/dev 2>/dev/null; " % marker
    cmd += "echo '%ssys:tz'; uci -q get system.@system[0].zonename; cat /etc/TZ 2>/dev/null; " % marker
    cmd += "echo '%sping:ya'; ping -c2 -W2 77.88.8.8 2>/dev/null; " % marker
    cmd += "echo '%subus:network.wireless:status'; ubus call network.wireless status 2>/dev/null; " % marker
    for cfg in MIRROR_CONFIGS:
        cmd += "echo '%suci:%s'; uci export %s 2>/dev/null; " % (marker, cfg, cfg)
    cmd = cmd.rstrip("; ")
    env = dict(os.environ)
    askpass = None
    ssh = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
           "root@" + ip, cmd]
    try:
        if password:
            askpass = make_askpass(password)
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.pop("SSH_AUTH_SOCK", None)
        out = subprocess.run(ssh, capture_output=True, timeout=25, env=env,
                             start_new_session=True).stdout
    finally:
        if askpass:
            os.unlink(askpass)
    if not out:
        return None
    chunks = {}
    for chunk in out.split(marker.encode())[1:]:
        nl = chunk.find(b"\n")
        if nl < 0:
            continue
        chunks[chunk[:nl].decode()] = chunk[nl + 1:]

    def put(path, body):
        with open(path + ".emu_new", "wb") as f:
            f.write(body)
        os.replace(path + ".emu_new", path)

    merge_uci_mirror(chunks)
    sms = chunks.get("sms:new", b"")
    if sms.strip():
        put("/tmp/5gmodem_sms_new.json", sms)
    nd = chunks.get("proc:netdev", b"")
    if nd.strip():
        put("/tmp/almond3s-emu/proc_net_dev", nd)
    tz = chunks.get("sys:tz", b"").decode(errors="replace").strip().splitlines()
    if tz and tz[0].strip():
        with open("/tmp/almond3s-emu/tz", "w") as f:
            f.write(tz[0].strip())
    # ubus-фикстуры эмулятора кормим живыми ответами (аптайм, память, борда).
    for name in ("system:info", "system:board", "network.wireless:status"):
        body = chunks.get("ubus:" + name, b"")
        if body.strip():
            put("/tmp/almond3s-emu/ubus/" + name.replace(":", "__") + ".json", body)

    mode = None
    if chunks.get("/tmp/lcd_data.json", b"").strip():
        for path in SYNC_FILES:
            body = chunks.get(path, b"")
            if body.strip():
                put(path, body)
        mode = "almond"
    else:
        body = synth_lcd_data(chunks)
        if body:
            put("/tmp/lcd_data.json", body)
            mode = "adapter"
    return mode


def spd_remote(ip, password, arg):
    env = dict(os.environ)
    askpass = None
    try:
        if password:
            askpass = make_askpass(password)
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.pop("SSH_AUTH_SOCK", None)
        subprocess.run(["ssh", "-o", "ConnectTimeout=5",
                        "-o", "StrictHostKeyChecking=accept-new", "root@" + ip,
                        "/usr/share/5gmodem/speedtest.sh " + arg +
                        " >/dev/null 2>&1 &"],
                       capture_output=True, timeout=15, env=env,
                       start_new_session=True)
    except Exception:
        pass
    finally:
        if askpass:
            os.unlink(askpass)


def tweak_fixture(what):
    try:
        with open("/tmp/lcd_data.json") as f:
            d = json.load(f)
        if what == "battery":
            b = d.setdefault("battery", {})
            pct = int(b.get("percent", 0) or 0)
            b["percent"] = 5 if pct >= 95 else min(pct + 20, 100)
            b["charging"] = bool(b.get("charging"))
            b["no_battery"] = False
        else:
            l = d.setdefault("lte", {})
            sig = int(l.get("signal", 0) or 0)
            sig = (sig + 25) if sig < 100 else 0
            l["signal"] = sig
            l["rsrp"] = -115 + int(sig * 0.35)
        with open("/tmp/lcd_data.json.emu_new", "w") as f:
            json.dump(d, f, ensure_ascii=False)
        os.replace("/tmp/lcd_data.json.emu_new", "/tmp/lcd_data.json")
        return True
    except Exception:
        return False


def sync_loop():
    while True:
        with source_lock:
            ip, pw = source["ip"], source["password"]
        if ip:
            try:
                mode = fetch_once(ip, pw)
            except Exception:
                mode = None
            with source_lock:
                if source["ip"] == ip:
                    source["ok"] = mode is not None
                    if mode == "almond":
                        source["status"] = "живые данные с " + ip
                    elif mode == "adapter":
                        source["status"] = ip + ": адаптер (5gmodem+ubus, без LCD-стека)"
                    else:
                        source["status"] = ip + ": нет ответа (ssh)"
        time.sleep(1 if time.time() < fast_until[0] else 3)


PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Almond 3S emulator</title>
<style>
 body { background:#0b0e13; color:#c9d1d9; font-family:monospace; display:flex;
        flex-direction:column; align-items:center; gap:12px; padding:20px; }
 canvas { image-rendering:pixelated; cursor:crosshair; display:block;
          border:2px solid #05070a; border-radius:3px; }
 #bezel { position:relative; padding:192px 240px 240px;
          background:linear-gradient(160deg,#23272e,#171a1f 60%,#101318);
          border-radius:58px; box-shadow:0 18px 50px rgba(0,0,0,.6),
          inset 0 1px 0 rgba(255,255,255,.06); margin-bottom:32px; }
 /* Широкая рамка на самом пластике корпуса: чуть темнее панели, с
    правильным скруглением. Тонкая тёмная окантовка экрана - на canvas. */
 /* Объём: свет падает сбоку - нижняя и левая грани рамки ловят свет,
    верхняя и правая уходят в тень. */
 #recess { padding:45px; border-radius:27px;
           background:linear-gradient(45deg,#1b1f26 0%,#14171c 45%,#0f1216 100%);
           box-shadow: inset 0 7px 12px rgba(0,0,0,.5),
                       inset -7px 0 12px rgba(0,0,0,.38),
                       inset 0 -7px 12px rgba(255,255,255,.10),
                       inset 7px 0 12px rgba(255,255,255,.07),
                       0 1px 0 rgba(255,255,255,.04); }
 #led { position:absolute; top:174px; left:50%; transform:translateX(-50%);
        width:5px; height:5px; border-radius:50%; background:#2a2e34;
        transition:background .15s; }
 #led.on { background:#f5f7fa; box-shadow:0 0 8px 2px rgba(245,247,250,.75); }
 #led.blink { animation: ledblink .5s steps(1) infinite; }
 @keyframes ledblink {
   0%,100% { background:#f5f7fa; box-shadow:0 0 8px 2px rgba(245,247,250,.75); }
   50% { background:#2a2e34; box-shadow:none; }
 }
 #brand { position:absolute; right:56px; bottom:42px; color:#5a6270;
          font:12px monospace; letter-spacing:2px; }
 .bar { display:flex; gap:8px; align-items:center; }
 input,button { background:#161b22; color:#c9d1d9; border:1px solid #30363d;
                padding:6px 10px; border-radius:6px; font-family:monospace; }
 button { cursor:pointer; } #st { color:#8b949e; }
</style></head><body>
<div id="bezel">
  <div id="led"></div>
  <div id="recess"><canvas id="lcd" width="320" height="240" style="width:320px;height:240px"></canvas></div>
  <div id="brand">Almond 3S</div>
</div>
<div class="bar">
 <input id="ip" placeholder="IP роутера (живые данные)" size="22">
 <input id="pw" placeholder="пароль root (пусто = ключи)" type="password" size="22">
 <button onclick="setSrc()">подключить</button>
 <button onclick="setSrc(true)">фикстуры</button>
</div>
<div class="bar">
 <input id="goto" placeholder="страница (menu, lte, dcust...)" size="22">
 <button onclick="gotoPage()">перейти</button>
 <span id="st"></span>
</div>
<script>
const cv = document.getElementById('lcd'), cx = cv.getContext('2d');
const img = cx.createImageData(320, 240);
async function frame() {
  try {
    const r = await fetch('/frame?ts=' + Date.now());
    const b = new Uint8Array(await r.arrayBuffer());
    const d = img.data;
    for (let i = 0, p = 0; i < b.length - 1 && p < d.length; i += 2, p += 4) {
      const v = b[i] | (b[i + 1] << 8);
      d[p]     = ((v >> 11) & 31) * 255 / 31;
      d[p + 1] = ((v >> 5) & 63) * 255 / 63;
      d[p + 2] = (v & 31) * 255 / 31;
      d[p + 3] = 255;
    }
    cx.putImageData(img, 0, 0);
  } catch (e) {}
  setTimeout(frame, 150);
}
frame();
cv.addEventListener('click', ev => {
  const r = cv.getBoundingClientRect();
  const x = Math.round((ev.clientX - r.left) * 320 / r.width);
  const y = Math.round((ev.clientY - r.top) * 240 / r.height);
  fetch('/tap', {method: 'POST', body: x + ' ' + y});
});
async function setSrc(clear) {
  const ip = clear ? '' : document.getElementById('ip').value.trim();
  const pw = clear ? '' : document.getElementById('pw').value;
  await fetch('/source', {method: 'POST', body: JSON.stringify({ip, password: pw})});
}
function gotoPage() {
  fetch('/goto', {method: 'POST', body: document.getElementById('goto').value.trim()});
}
// Физическая клавиатура -> терминал: раскладываем в байты PTY и шлём на /key.
// Работает всегда; если терминал не открыт, сервер молча игнорирует.
const KEYMAP = {
  Enter:'\\r', Backspace:'\\x7f', Tab:'\\t', Escape:'\\x1b',
  ArrowUp:'\\x1b[A', ArrowDown:'\\x1b[B', ArrowRight:'\\x1b[C', ArrowLeft:'\\x1b[D',
  Home:'\\x1b[H', End:'\\x1b[F', Delete:'\\x1b[3~',
  PageUp:'\\x1b[5~', PageDown:'\\x1b[6~'
};
document.addEventListener('keydown', ev => {
  const t = ev.target.tagName;
  if (t === 'INPUT' || t === 'TEXTAREA') return;   // не мешаем полям IP/страницы
  let bytes = null;
  if (ev.ctrlKey && ev.key.length === 1) {
    const c = ev.key.toLowerCase().charCodeAt(0);
    if (c >= 97 && c <= 122) bytes = String.fromCharCode(c - 96);   // Ctrl+A..Z
  } else if (KEYMAP[ev.key]) {
    bytes = KEYMAP[ev.key];
  } else if (ev.key.length === 1) {
    bytes = ev.key;
  }
  if (bytes === null) return;
  ev.preventDefault();
  fetch('/key', {method: 'POST', body: new Blob([bytes])});
});
async function status() {
  try {
    const s = await (await fetch('/status')).json();
    document.getElementById('st').textContent = s.status;
    const led = document.getElementById('led');
    led.classList.toggle('on', s.led === 'on');
    led.classList.toggle('blink', s.led === 'blink');
  } catch (e) {}
  setTimeout(status, 2000);
}
status();
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/frame"):
            try:
                with open(FB, "rb") as f:
                    data = f.read(FB_SIZE)
            except OSError:
                data = b""
            data = data.ljust(FB_SIZE, b"\x00")
            self._send(200, data, "application/octet-stream")
        elif self.path.startswith("/status"):
            led = "off"
            try:
                base = "/tmp/almond3s-emu/leds/white:status/"
                with open(base + "trigger") as f:
                    trig = f.read()
                with open(base + "brightness") as f:
                    br = f.read().strip()
                led = "blink" if "timer" in trig.split() or trig.strip() == "timer"                     else ("on" if br not in ("", "0") else "off")
            except OSError:
                pass
            with source_lock:
                d = dict(source)
            d["led"] = led
            self._send(200, json.dumps(d, ensure_ascii=False).encode(),
                       "application/json")
        else:
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        if self.path == "/tap":
            with source_lock:
                live = bool(source["ip"])
            handled = False
            if not live:
                try:
                    x, y = [int(v) for v in body.split()[:2]]
                except ValueError:
                    x, y = -1, -1
                # Песочница данных: тап по батарее в шапке добавляет ячейку
                # заряда, тап по сигналу крутит уровень. Только на фикстурах.
                if 0 <= y <= 18 and x >= 250:
                    handled = tweak_fixture("battery")
                elif 0 <= y <= 18 and 0 <= x <= 60:
                    handled = tweak_fixture("signal")
            if not handled:
                with open(TOUCH + ".emu_new", "wb") as f:
                    f.write(body.strip() + b"\n")
                os.replace(TOUCH + ".emu_new", TOUCH)
            self._send(200, b"ok")
        elif self.path == "/key":
            try:
                with open("/tmp/.almond3s_term_in", "wb") as f:
                    f.write(body)
            except OSError:
                pass
            self._send(200, b"ok")
        elif self.path == "/goto":
            with open(GOTO, "wb") as f:
                f.write(body.strip() + b"\n")
            self._send(200, b"ok")
        elif self.path == "/spd":
            arg = body.decode(errors="replace").strip() or "start"
            with source_lock:
                ip, pw = source["ip"], source["password"]
            if ip and arg in ("start", "stop"):
                fast_until[0] = time.time() + (120 if arg == "start" else 5)
                threading.Thread(target=spd_remote, args=(ip, pw, arg),
                                 daemon=True).start()
            self._send(200, b"ok")
        elif self.path == "/source":
            try:
                cfg = json.loads(body.decode() or "{}")
            except ValueError:
                cfg = {}
            with source_lock:
                source["ip"] = cfg.get("ip", "").strip()
                source["password"] = cfg.get("password", "")
                source["ok"] = False
                source["status"] = ("подключаюсь к " + source["ip"]) if source["ip"] \
                    else "фикстуры (без устройства)"
            write_rsh(cfg.get("ip", "").strip(), cfg.get("password", ""))
            if not cfg.get("ip", "").strip():
                # Возврат на фикстуры: пересеять файлы, живые остатки стереть.
                import shutil
                for name in ("lcd_data.json", "lcd_zig_peers.json", "lcd_weather.txt"):
                    try:
                        shutil.copy(os.path.join(SEED_DIR, name), "/tmp/" + name)
                    except OSError:
                        pass
            self._send(200, b"ok")
        else:
            self._send(404, b"")


if __name__ == "__main__":
    threading.Thread(target=sync_loop, daemon=True).start()
    print("эмулятор: http://127.0.0.1:%d" % PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
