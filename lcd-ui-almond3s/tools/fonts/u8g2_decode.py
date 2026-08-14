#!/usr/bin/env python3
"""Декодер шрифтов u8g2 из u8g2_fonts.c в простые глифы-битмапы.

Формат по u8g2_font.c: 23-байтовый заголовок, ASCII-глифы [код, размер,
битполя], юникод-секция с 4-байтовой таблицей прыжков и 2-байтовыми кодами.
Битовый поток LSB-first, знаковые поля хранятся со смещением 2^(n-1).
Битмап: RLE-раны нулей и единиц, повтор пары по флажному биту.
"""
import re, sys, json

def extract_array(path, name):
    src = open(path, encoding='utf-8', errors='replace').read()
    m = re.search(re.escape(name) + r'\[\d+\]\s*U8G2_FONT_SECTION\([^)]*\)\s*=', src)
    if not m:
        raise SystemExit(f"нет массива {name}")
    # конец массива - первая ';' ВНЕ кавычек: внутри строк бывает сырой ';'
    i = m.end(); depth_q = False; esc = False; end = None
    while i < len(src):
        c = src[i]
        if depth_q:
            if esc: esc = False
            elif c == '\\': esc = True
            elif c == '"': depth_q = False
        else:
            if c == '"': depth_q = True
            elif c == ';': end = i; break
        i += 1
    body = src[m.end():end]
    data = bytearray()
    for lit in re.findall(r'"((?:\\.|[^"\\])*)"', body, re.S):
        i = 0
        while i < len(lit):
            c = lit[i]
            if c != '\\':
                data.append(ord(c)); i += 1; continue
            i += 1
            c = lit[i]
            if c == 'x':
                j = i + 1
                while j < len(lit) and lit[j] in '0123456789abcdefABCDEF':
                    j += 1
                v = int(lit[i+1:j], 16)
                if v > 0xFF:
                    raise SystemExit(f"hex-escape >0xFF: \\x{lit[i+1:j]}")
                data.append(v); i = j
            elif c in '01234567':
                j = i
                while j < len(lit) and j < i + 3 and lit[j] in '01234567':
                    j += 1
                data.append(int(lit[i:j], 8)); i = j
            else:
                data.append({'n':10,'r':13,'t':9,'\\':92,"'":39,'"':34,'a':7,'b':8,'f':12,'v':11}[c])
                i += 1
    # C-строковый литерал несёт неявный '\0' - без него терминатор
    # юникод-секции (два нулевых байта) неполон
    return bytes(data) + b'\0'

class Bits:
    def __init__(self, data, pos):
        self.d = data; self.byte = pos; self.bit = 0
    def get(self, cnt):
        val = self.d[self.byte] >> self.bit
        if self.bit + cnt >= 8:
            val |= (self.d[self.byte+1] if self.byte+1 < len(self.d) else 0) << (8 - self.bit)
        self.bit += cnt
        if self.bit >= 8:
            self.bit -= 8; self.byte += 1
        return val & ((1 << cnt) - 1)
    def sget(self, cnt):
        return self.get(cnt) - (1 << (cnt - 1))

def parse_font(font):
    hdr = dict(
        glyph_cnt=font[0], bbx_mode=font[1], bits_per_0=font[2], bits_per_1=font[3],
        bpw=font[4], bph=font[5], bpx=font[6], bpy=font[7], bpd=font[8],
        max_w=font[9], max_h=font[10],
        ascent_A=font[13] - 256 if font[13] > 127 else font[13],
        descent_g=font[14] - 256 if font[14] > 127 else font[14],
        start_A=(font[17] << 8) | font[18], start_a=(font[19] << 8) | font[20],
        start_uni=(font[21] << 8) | font[22],
    )
    glyphs = {}

    def decode_at(pos, code):
        b = Bits(font, pos)
        w = b.get(hdr['bpw']); h = b.get(hdr['bph'])
        x = b.sget(hdr['bpx']); y = b.sget(hdr['bpy']); d = b.sget(hdr['bpd'])
        pix = []
        if w > 0:
            total = w * h
            while len(pix) < total:
                a = b.get(hdr['bits_per_0']); one = b.get(hdr['bits_per_1'])
                while True:
                    pix.extend([0]*a); pix.extend([1]*one)
                    if b.get(1) == 0:
                        break
            pix = pix[:total]
        glyphs[code] = dict(w=w, h=h, x=x, y=y, adv=d,
                            rows=[pix[r*w:(r+1)*w] for r in range(h)])

    pos = 23
    while True:
        enc = font[pos]; size = font[pos+1]
        if size == 0:
            break
        decode_at(pos + 2, enc)
        pos += size

    if hdr['start_uni']:
        base = 23 + hdr['start_uni']
        # таблица прыжков: [offset u16][encoding u16]... до encoding >= искомого;
        # для полного обхода прыгаем по первой записи и идём подряд
        pos = base + ((font[base] << 8) | font[base+1])
        while True:
            enc = (font[pos] << 8) | font[pos+1]
            if enc == 0:
                break
            size = font[pos+2]
            decode_at(pos + 3, enc)
            pos += size
    return hdr, glyphs

def render_preview(hdr, glyphs, text, scale, out):
    from PIL import Image
    base = hdr['max_h'] + 4
    W = 4
    for ch in text:
        g = glyphs.get(ord(ch))
        W += (g['adv'] if g else 4)
    im = Image.new('RGB', ((W+4)*scale, (base+6)*scale), (255, 130, 0))
    px = im.load()
    cx = 2
    for ch in text:
        g = glyphs.get(ord(ch))
        if not g:
            cx += 4; continue
        gx = cx + g['x']; gy = base - g['h'] - g['y']
        for ry, row in enumerate(g['rows']):
            for rx, v in enumerate(row):
                if v:
                    for sy in range(scale):
                        for sx in range(scale):
                            X = (gx+rx)*scale+sx; Y = (gy+ry)*scale+sy
                            if 0 <= X < im.width and 0 <= Y < im.height:
                                px[X, Y] = (10, 10, 10)
        cx += g['adv']
    im.save(out)
    return out

if __name__ == '__main__':
    src, name, text, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    font = extract_array(src, name)
    hdr, glyphs = parse_font(font)
    print(f"{name}: {len(glyphs)} глифов, max {hdr['max_w']}x{hdr['max_h']}, ascent {hdr['ascent_A']}")
    cyr = [c for c in glyphs if c >= 0x400]
    print(f"кириллица: {len(cyr)} глифов" + (f" ({chr(min(cyr))}..{chr(max(cyr))})" if cyr else ""))
    render_preview(hdr, glyphs, text, 2, out)
    json.dump({str(k): v for k, v in glyphs.items()},
              open(out.rsplit('.',1)[0] + '.json', 'w'))
    print("превью:", out)
