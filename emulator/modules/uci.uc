// Стаб uci для эмулятора: та же сигнатура cursor(), состояние - в JSON-файле
// /tmp/almond3s-emu/uci.json ({"конфиг":{"секция":{"опция":"значение"}}}).
// Типы секций не храним: foreach нужен ui.uc только для wireless/firewall,
// которых в эмуляторе нет - колбэк просто не зовётся.
let fs = require("fs");

const DB_PATH = "/tmp/almond3s-emu/uci.json";

function cursor() {
    let db;
    let reload = function() {
        let raw = fs.readfile(DB_PATH);
        let d = null;
        if (raw) try { d = json(raw); } catch (e) { d = null; }
        db = type(d) == "object" ? d : {};
    };
    reload();
    return {
        load: function(c) { reload(); return true; },
        get: function(c, s, o) {
            // Всегда перечитываем: ui создаёт курсор один раз на старте, а
            // конфиги роутера обновляются синком/правками на лету.
            reload();
            if (o == null) return db?.[c]?.[s] != null ? "emu" : null;
            return db?.[c]?.[s]?.[o];
        },
        set: function(c, s, o, v) {
            db[c] ??= {};
            if (v == null) { db[c][s] ??= {}; return true; }
            db[c][s] ??= {};
            db[c][s][o] = v;
            return true;
        },
        delete: function(c, s, o) {
            if (o == null) { if (db?.[c]) delete db[c][s]; }
            else if (db?.[c]?.[s]) delete db[c][s][o];
            return true;
        },
        commit: function(c) {
            let f = fs.open(DB_PATH, "w");
            if (f) { f.write(sprintf("%.J\n", db)); f.close(); }
            return true;
        },
        foreach: function(c, t, cb) {
            // Зеркальные конфиги живого роутера несут тип в ".type" и имя в
            // ".name" - обходим как настоящий uci.
            let cfgd = db?.[c];
            if (type(cfgd) != "object") return true;
            for (let name, sec in cfgd) {
                if (type(sec) != "object") continue;
                if (t != null && sec[".type"] != t) continue;
                cb(sec);
            }
            return true;
        },
    };
}

return { cursor: cursor };
