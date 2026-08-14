# Шрифт Flipper для render

Альтернативный шрифт интерфейса - haxrcorp4089 из Flipper Zero (u8g2, BSD),
уложенный моноширинно в клетку 6x8 встроенного 5x7. Включается кнопкой
«Шрифт» на странице «Экран» (uci almond3s.display.font = std | flipper).

Конвейер:

    u8g2_decode.py  - декодер битового формата u8g2: вытащил глифы из
                      u8g2_fonts.c прошивки flipperzero-firmware в
                      hax_preview.json (пропорциональные, как в оригинале)
    make_mono.py    - укладка в моноширинную клетку: широкие буквы (М, Ш, W...)
                      перерисованы руками в 5 колонок, узкие (i, l, 1...)
                      расширены засечками, ':' в узкой клетке 5; результат
                      hax_mono.json
    gen_header.py   - hax_mono.json -> ../../src/flipper_fonts.h для render.c

Поправить букву: найти её кодпоинт в таблицах WIDE/NARROW/MISSING в
make_mono.py (или добавить), нарисовать '#'/'.' по строкам, затем:

    python3 make_mono.py && python3 gen_header.py
    cp flipper_fonts.h ../../src/

и пересобрать пакет.
