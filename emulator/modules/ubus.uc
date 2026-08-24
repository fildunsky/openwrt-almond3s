// Стаб ubus для эмулятора: call(объект, метод) читает фикстуру из
// /tmp/almond3s-emu/ubus/<объект>__<метод>.json. Нет файла - null, ровно как
// отсутствующий объект на шине; ui.uc это штатно переживает.
let fs = require("fs");

const DIR = "/tmp/almond3s-emu/ubus/";

function connect() {
    return {
        call: function(obj, method, args) {
            let raw = fs.readfile(DIR + obj + "__" + method + ".json");
            if (!raw) return null;
            try { return json(raw); } catch (e) { return null; }
        },
        disconnect: function() { return true; },
    };
}

return { connect: connect };
