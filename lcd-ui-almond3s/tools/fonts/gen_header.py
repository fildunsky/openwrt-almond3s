#!/usr/bin/env python3
"""Из JSON-глифов u8g2_decode.py делает flipper_fonts.h для render.c
и fontmetrics.json для ui.uc (ширины строк считаются на стороне ucode).

Формат: битмапы всех глифов подряд, ряд глифа выровнен на байт (MSB первым);
таблица глифов сортирована по кодпоинту - в render бинарный поиск.
"""
import json, sys

FONTS = [
    ("hax", "hax_mono.json", "haxrcorp4089 + кириллица, моноширинная клетка 6, широкие ужаты руками"),
]

hdr = ["/* Шрифты Flipper Zero, декодированы из u8g2 (BSD). Автогенерация gen_header.py */",
       "#include <stdint.h>",
       "",
       "struct fz_glyph { uint16_t cp; int8_t w, h, x, y, adv; uint32_t off; };",
       ""]
metrics = {}

for cname, jfile, comment in FONTS:
    glyphs = json.load(open(jfile))
    items = sorted(((int(cp), g) for cp, g in glyphs.items()))
    bits = bytearray()
    table = []
    adv_map = {}
    max_h = 0; min_y = 127
    for cp, g in items:
        off = len(bits)
        for row in g["rows"]:
            acc = 0; n = 0
            for v in row:
                acc = (acc << 1) | (1 if v else 0); n += 1
                if n == 8:
                    bits.append(acc); acc = 0; n = 0
            if n:
                bits.append(acc << (8 - n))
        table.append((cp, g["w"], g["h"], g["x"], g["y"], g["adv"], off))
        adv_map[cp] = g["adv"]
        max_h = max(max_h, g["h"] + g["y"])
        if g["h"]: min_y = min(min_y, g["y"])
    ascent = max((g["h"] + g["y"]) for _, g in items)
    descent = -min((g["y"] for _, g in items))
    hdr.append(f"/* {comment}: {len(table)} глифов, ascent {ascent}, descent {descent} */")
    hdr.append(f"static const uint8_t fz_{cname}_bits[{len(bits)}] = {{")
    for i in range(0, len(bits), 16):
        hdr.append("    " + ", ".join(f"0x{b:02x}" for b in bits[i:i+16]) + ",")
    hdr.append("};")
    hdr.append(f"static const struct fz_glyph fz_{cname}_glyphs[{len(table)}] = {{")
    for cp, w, h, x, y, adv, off in table:
        hdr.append(f"    {{ {cp}, {w}, {h}, {x}, {y}, {adv}, {off} }},")
    hdr.append("};")
    hdr.append(f"#define FZ_{cname.upper()}_COUNT {len(table)}")
    hdr.append(f"#define FZ_{cname.upper()}_ASCENT {ascent}")
    hdr.append(f"#define FZ_{cname.upper()}_DESCENT {descent}")
    hdr.append("")
    metrics[cname] = {"ascent": ascent, "descent": descent,
                      "adv": {str(cp): a for cp, a in adv_map.items()}}

open("flipper_fonts.h", "w").write("\n".join(hdr) + "\n")
json.dump(metrics, open("fontmetrics.json", "w"))
print("flipper_fonts.h:", sum(1 for _ in open("flipper_fonts.h")), "строк")
print("fontmetrics.json:", len(open("fontmetrics.json").read()), "байт")
