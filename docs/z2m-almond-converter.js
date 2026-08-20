// Внешний преобразователь zigbee2mqtt для Almond 3S.
//
// Аппарат отдаёт батарею и температуру стандартными кластерами, а весь
// остальной набор метрик — своим кластером 0xFC00, атрибут 0x0000, строкой
// байтов. Внутри простые записи: идентификатор, длина, значение младшим
// байтом вперёд. Строки передаются как есть.
//
// Куда класть: каталог внешних преобразователей zigbee2mqtt, затем в
// configuration.yaml:
//   external_converters:
//     - z2m-almond-converter.js

const NUM = {
    0x01: ['sig', 1, false],   0x02: ['rsrp', 1, true],  0x03: ['batt', 1, false],
    0x04: ['chg', 1, false],   0x05: ['cpu', 1, false],  0x06: ['mem', 1, false],
    0x07: ['disk', 1, false],  0x08: ['up', 2, false],   0x09: ['wifi', 1, false],
    0x0a: ['ping', 2, true],   0x0b: ['sms', 1, false],  0x0c: ['rx', 4, false],
    0x0d: ['tx', 4, false],    0x0e: ['temp', 1, true],  0x0f: ['vpn', 1, false],
    0x11: ['rsrq', 1, true],   0x12: ['sinr', 1, true],
};
const STR = { 0x10: 'oper', 0x13: 'band', 0x14: 'ca', 0x15: 'mode', 0x16: 'vpn_node' };

function unpack(buf) {
    const out = {};
    let i = 0;
    while (i + 2 <= buf.length) {
        const id = buf[i], len = buf[i + 1];
        const val = buf.slice(i + 2, i + 2 + len);
        if (val.length < len) break;
        if (STR[id]) {
            out[STR[id]] = val.toString('latin1').replace(/[^\x20-\x7e]/g, '');
        } else if (NUM[id]) {
            const [name, width, signed] = NUM[id];
            let v = 0;
            for (let b = 0; b < Math.min(width, len); b++) v |= val[b] << (8 * b);
            if (signed && width === 1 && v > 127) v -= 256;
            if (signed && width === 2 && v > 32767) v -= 65536;
            out[name] = v;
        }
        i += 2 + len;
    }
    return out;
}

const fzAlmond = {
    cluster: 'manuSpecificAlmond',
    type: ['attributeReport', 'readResponse'],
    convert: (model, msg) => {
        const raw = msg.data['0'] ?? msg.data[0];
        if (!raw) return {};
        // Первая запись - имя узла: длина, затем символы. Дальше метрики.
        const buf = Buffer.from(raw);
        const nameLen = buf[0];
        const name = buf.slice(1, 1 + nameLen).toString('latin1');
        const m = unpack(buf.slice(1 + nameLen));
        return Object.assign({ node: name }, m);
    },
};

module.exports = [{
    zigbeeModel: ['Almond 3S'],
    model: 'Almond3S',
    vendor: 'Securifi',
    description: 'Роутер Almond 3S с телеметрией',
    fromZigbee: [fzAlmond],
    toZigbee: [],
    exposes: [],
    meta: { multiEndpoint: false },
    configure: async (device, coordinatorEndpoint) => {
        const ep = device.getEndpoint(1);
        await ep.bind('genPowerCfg', coordinatorEndpoint);
        await ep.bind('msTemperatureMeasurement', coordinatorEndpoint);
    },
}];
