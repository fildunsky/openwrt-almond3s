import re, sys
src = open(sys.argv[1]).read()
lines = src.split('\n')
# собрать позиции определений функций и топ-level let-переменных
func_def = {}
for i, l in enumerate(lines):
    m = re.match(r'\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', l)
    if m: func_def.setdefault(m.group(1), i)
    m2 = re.match(r'\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=', l)
    if m2 and (len(l) - len(l.lstrip())) == 0: func_def.setdefault(m2.group(1), i)
# для каждого вызова f(...) внутри тела функции g, если f определена ниже g — forward ref
fwd = 0
cur_fn = None; cur_line = 0
for i, l in enumerate(lines):
    m = re.match(r'\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', l)
    if m: cur_fn = m.group(1); cur_line = i; continue
    for call in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\(', l):
        if call in func_def and func_def[call] > i and func_def.get(cur_fn, 0) < func_def[call]:
            # вызов внутри тела функции, определённой раньше цели
            if cur_fn and func_def.get(cur_fn, 1e9) < func_def[call]:
                print(f"FWD-REF {sys.argv[1].split('/')[-1]}:{i+1} {call}() опред. на {func_def[call]+1} (внутри {cur_fn})")
                fwd += 1
print(f"forward-ссылок: {fwd}")
