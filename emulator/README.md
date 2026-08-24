# Эмулятор Almond 3S для ПК

Настоящие `ui.uc` и `render.c` из этого репозитория, исполняемые на компьютере;
экран — в браузере (canvas 320x240), тапы — кликами. Железо (kmod, PIC, тач,
Zigbee, модем) подменено файлами и заглушками, поэтому вся логика интерфейса,
включая конструктор «Виджеты Зигби», работает один в один как на устройстве.

## Запуск

```sh
./run.sh          # затем открыть http://127.0.0.1:8380
```

Требуется: `bwrap` (bubblewrap), `python3`, `gcc`, собранные `prefix/`
(хостовый ucode) и `bin/render-emu` — см. «Сборка» ниже.

На странице:
- клик по экрану = тап;
- поле **IP** — живые данные с настоящего устройства: каждые 3 секунды по ssh
  забираются `/tmp/lcd_data.json`, `/tmp/lcd_zig_peers.json`,
  `/tmp/lcd_weather.txt` (пароль опционален, пусто = ssh-ключи). Кнопка
  «фикстуры» возвращает встроенные данные;
- поле «страница» = `echo <имя> > /tmp/.lcd_goto` (menu, lte, dcust, zigbee…).

## Как устроено

| Железо на роутере            | В эмуляторе                                   |
|------------------------------|-----------------------------------------------|
| `/dev/lcd` (kmod)            | файл `/tmp/almond3s-emu/lcd.fb` (env `ALMOND_LCD_DEV` в render) |
| тач (ioctl → демон)          | `/tmp/.lcd_touch` из кликов браузера          |
| `almond3s-lcd` (утилита)     | заглушка `bin/almond3s-lcd` (waittouch по файлу) |
| uci                          | стаб `modules/uci.uc` → `/tmp/almond3s-emu/uci.json` |
| ubus                         | стаб `modules/ubus.uc` → фикстуры `/tmp/almond3s-emu/ubus/*.json` |
| uloop                        | отсутствует — ui.uc сам уходит в фолбэк-петлю |
| collector                    | фикстура `/tmp/lcd_data.json` или живой файл с устройства |
| `/etc/almond3s`, `/usr/bin/almond3s-lcd` | подмена через bwrap (в систему ничего не ставится) |

Чего эмулятор не умеет: сцены kmod (заставки «Матрица»/«Лого»), реальный
Zigbee/модем/батарея (только данные с живого устройства или фикстуры), NES.

## Сборка (один раз)

```sh
# хостовый ucode со штатными модулями fs/socket (uci/ubus здесь не нужны):
git clone --depth 1 https://github.com/json-c/json-c.git
cmake -S json-c -B json-c/build -DCMAKE_INSTALL_PREFIX=$PWD/prefix -DBUILD_SHARED_LIBS=ON
cmake --build json-c/build -j && cmake --install json-c/build

git clone --depth 1 https://github.com/jow-/ucode.git
PKG_CONFIG_PATH=$PWD/prefix/lib/pkgconfig cmake -S ucode -B ucode/build \
  -DCMAKE_INSTALL_PREFIX=$PWD/prefix -DCMAKE_INSTALL_RPATH=$PWD/prefix/lib \
  -DULOOP_SUPPORT=OFF -DUCI_SUPPORT=OFF -DUBUS_SUPPORT=OFF \
  -DNL80211_SUPPORT=OFF -DRTNL_SUPPORT=OFF
cmake --build ucode/build -j && cmake --install ucode/build

# рендер для ПК:
gcc -O2 -o bin/render-emu ../lcd-ui-almond3s/src/render.c
```

`prefix/` и `bin/render-emu` в git не кладутся (бинарники хост-специфичны).
