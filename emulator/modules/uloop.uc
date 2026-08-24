// Стаб uloop для эмулятора: ровно то подмножество, которым пользуется ui.uc -
// init(), timer(мс, колбэк) c методами set()/cancel() и run(). Планировщик
// на socket.poll в роли сна. С ним ui.uc идёт по «родному» событийному пути,
// а не по фолбэк-петле - поведение совпадает с устройством.
import { poll as sock_poll } from "socket";

let TIMERS = [];

function now_ms() {
    let c = clock(true);
    return c[0] * 1000 + int(c[1] / 1000000);
}

function timer(ms, cb) {
    let t = { cb: cb, due: null };
    t.set = function(m) { t.due = now_ms() + m; return true; };
    t.cancel = function() { t.due = null; return true; };
    if (ms != null) t.set(ms);
    push(TIMERS, t);
    return t;
}

function init() { return true; }

function run() {
    while (true) {
        let now = now_ms(), next = null;
        for (let t in TIMERS)
            if (t.due != null && (next == null || t.due < next)) next = t.due;
        let wait = next == null ? 200 : next - now;
        if (wait > 200) wait = 200;
        if (wait > 0) sock_poll(wait);
        now = now_ms();
        for (let t in TIMERS) {
            if (t.due != null && t.due <= now) {
                t.due = null;
                t.cb();
            }
        }
    }
}

return { init: init, timer: timer, run: run };
