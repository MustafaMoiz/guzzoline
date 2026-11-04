import '@fontsource/ibm-plex-mono/300.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import './style.css';
import { THEMES } from './themes/index.js';
import { MOST, SAMPLE_SESSIONS, createRow, rowWidth, slotAt } from './sessions.js';
import { HOUR, MIN, SCENARIOS, createLapse, createModel, describe, fromUsage, slots, view } from './state.js';
import { until } from './format.js';

// The 13-inch MacBook Pro's Touch Bar, in pixels; ?width=2170 tries the earlier models'.
const BAR = { width: Number(new URLSearchParams(location.search).get('width')) || 2008, height: 60 };
const LAPSE_SPEED = 240; // a 5-hour session in 75 seconds

const params = new URLSearchParams(location.search);
const solo = params.get('solo');
// On the Touch Bar the app feeds real usage in, and copies each frame the page draws, so the
// page draws only as often as it needs to.
const live = params.has('live');
const app = window.webkit?.messageHandlers?.guzzoline;
document.body.classList.toggle('solo', Boolean(solo));

await Promise.all([
  '300 20px "IBM Plex Mono"', '400 20px "IBM Plex Mono"', '500 20px "IBM Plex Mono"',
  '500 20px "Barlow Condensed"', '600 20px "Barlow Condensed"',
].map((font) => document.fonts.load(font)));

let now = Date.now();
const model = createModel(now);
if (live) Object.assign(model, { windows: [], live: true });
const lapse = createLapse(model);
let lapsing = false;

// A canvas a given number of pixels wide, as a share of the bar.
function canvasFor(holder, width, label) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = BAR.height;
  canvas.style.width = `${(width / BAR.width) * 100}%`;
  canvas.setAttribute('aria-label', label);
  holder.append(canvas);
  return canvas;
}

// Each bar is the theme, and to its right a row of sessions when there are any: the theme
// narrows to make room, laid out again for its new width.
function mount(entry, count) {
  entry.holder.replaceChildren();
  const rowW = rowWidth(count);
  entry.canvas = canvasFor(entry.holder, BAR.width - rowW, `${entry.theme.name} theme`);
  entry.bar = entry.theme.create(entry.canvas, { width: BAR.width - rowW, height: BAR.height });
  entry.rowCanvas = count ? canvasFor(entry.holder, rowW, 'Sessions') : null;
  entry.row = count ? createRow(entry.rowCanvas, { width: rowW, height: BAR.height }) : null;
  entry.count = count;
  if (count) touchToRead(entry, rowW);
}

const STATE_WORDS = { working: 'working', asking: 'needs you', done: 'done', failed: 'failed', idle: 'idle' };

// Touching a Clawd shows its session's title across the rest of the bar; sliding moves to the
// next Clawd, and letting go is where the Touch Bar app opens that session.
function touchToRead(entry, rowW) {
  const card = document.createElement('div');
  card.className = 'reading';
  card.style.width = `${((BAR.width - rowW) / BAR.width) * 100}%`;
  card.hidden = true;
  entry.holder.append(card);
  const canvas = entry.rowCanvas;
  const show = (event) => {
    const sessions = sessionsNow();
    const box = canvas.getBoundingClientRect();
    const x = ((event.clientX - box.left) / box.width) * canvas.width;
    const i = Math.max(0, Math.min(sessions.length - 1, slotAt(x)));
    const s = sessions[i];
    if (!s) return;
    entry.row.touch(i);
    card.style.fontSize = `${entry.holder.clientHeight * 0.46}px`;
    card.replaceChildren(s.title, Object.assign(document.createElement('span'), { textContent: STATE_WORDS[s.state] ?? '' }));
    card.hidden = false;
  };
  let pressed = false;
  const hide = () => {
    pressed = false;
    entry.row.touch(-1);
    card.hidden = true;
  };
  canvas.addEventListener('pointerdown', (e) => { pressed = true; show(e); });
  canvas.addEventListener('pointermove', (e) => { if (pressed) show(e); });
  window.addEventListener('pointerup', hide);
  window.addEventListener('pointercancel', hide);
}

const bars = THEMES.filter((t) => !solo || t.id === solo).map((theme) => {
  const section = document.createElement('section');
  section.className = 'theme';
  section.innerHTML = `<h2></h2><p></p><div class="deck"><div class="key esc">esc</div>`
    + `<div class="bar"></div><div class="key touchid" aria-hidden="true"></div></div>`;
  section.querySelector('h2').textContent = theme.name;
  section.querySelector('p').textContent = theme.note;
  const holder = section.querySelector('.bar');
  holder.style.aspectRatio = `${BAR.width} / ${BAR.height}`;
  holder.style.flexBasis = `${BAR.width / 2}px`;
  document.getElementById('themes').append(section);
  const entry = { theme, holder };
  mount(entry, 0);
  return entry;
});

// Sessions: none, made-up ones, or yours, read by the dev server from the Claude app.
let sessionsShown = 'none';
let yourSessions = [];
const sessionsNow = () => (sessionsShown === 'sample' ? SAMPLE_SESSIONS : sessionsShown === 'yours' ? yourSessions : []);
setInterval(() => {
  if (sessionsShown !== 'yours') return;
  fetch('/__sessions').then((r) => (r.ok ? r.json() : [])).then((list) => { yourSessions = list; }).catch(() => {});
}, 2000);

const $ = (id) => document.getElementById(id);
const notice = $('notice');

// Usage from the Touch Bar app: the usage API's response, whether Claude is working, and a
// note when there's nothing to show (no sign-in to read usage with, say).
function applyUsage({ usage, working = false, note = '' } = {}) {
  model.windows = fromUsage(usage);
  model.working = working;
  model.live = true;
  notice.textContent = note;
  notice.hidden = !note || model.windows.length > 0;
}

let liveTimer = null;
function stopLive() {
  clearInterval(liveTimer);
  liveTimer = null;
  model.live = false;
}

for (const name of Object.keys(SCENARIOS)) {
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = name;
  button.addEventListener('click', () => {
    stopLive();
    model.windows = SCENARIOS[name](now);
    sync(true);
  });
  $('scenarios').append(button);
}

// In the gallery, "Live" shows what the Touch Bar app last read, through the dev server.
if (!solo) {
  const read = () => fetch('/__usage').then((r) => (r.ok ? r.json() : null));
  read().then((cache) => {
    if (!cache?.usage) return;
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Live';
    button.addEventListener('click', () => {
      lapsing = false;
      stopLive();
      const apply = (c) => c && applyUsage({ usage: c.usage, working: model.working });
      read().then(apply);
      liveTimer = setInterval(() => read().then(apply), 30e3);
      sync(true);
    });
    $('scenarios').prepend(button);
  }).catch(() => {});
}

$('working').addEventListener('click', () => { model.working = !model.working; sync(true); });
for (const button of document.querySelectorAll('[data-sessions]')) {
  button.addEventListener('click', () => {
    sessionsShown = button.dataset.sessions;
    if (sessionsShown === 'yours') fetch('/__sessions').then((r) => r.json()).then((list) => { yourSessions = list; }).catch(() => {});
    sync(true);
  });
}
$('lapse').addEventListener('click', () => { stopLive(); lapsing = !lapsing; sync(true); });
for (const button of document.querySelectorAll('[data-show]')) {
  button.addEventListener('click', () => { model.show = button.dataset.show; sync(true); });
}

// Two rows of sliders, for the bar's first and second limit, whichever those are.
const slot = (i) => slots(model.windows)[i];
const active = (w) => w && w.resetsAt != null && w.resetsAt > now;
const unit = (w) => (describe(w.key).kind === 'session' ? MIN : HOUR);
const sliders = ['a', 'b'].flatMap((p, i) => [
  {
    id: `${p}Used`,
    read: (w) => (active(w) ? Math.round(w.used * 100) : 0),
    write: (w, v) => {
      if (!active(w)) w.resetsAt = now + describe(w.key).length - MIN;
      w.used = v / 100;
    },
    text: (w, v) => `${v}%`,
    i,
  },
  {
    id: `${p}Reset`,
    max: (w) => (unit(w) === MIN ? 300 : 168),
    read: (w) => (active(w) ? Math.ceil((w.resetsAt - now) / unit(w)) : unit(w) === MIN ? 300 : 168),
    write: (w, v) => { w.resetsAt = now + v * unit(w); },
    text: (w) => (active(w) ? until(w.resetsAt - now) : '—'),
    i,
  },
]);

let dragging = null;
for (const s of sliders) {
  const input = $(s.id);
  input.addEventListener('pointerdown', () => { dragging = s.id; });
  input.addEventListener('input', () => {
    const w = slot(s.i);
    if (!w) return;
    stopLive();
    s.write(w, Number(input.value));
    sync(true);
  });
}
window.addEventListener('pointerup', () => { dragging = null; });

let lastSync = 0;
function sync(force = false) {
  const t = performance.now();
  if (solo || (!force && t - lastSync < 250)) return;
  lastSync = t;
  ['a', 'b'].forEach((p, i) => {
    const w = slot(i);
    $(`${p}Name`).textContent = w ? describe(w.key).name : '—';
  });
  for (const s of sliders) {
    const input = $(s.id);
    const w = slot(s.i);
    input.disabled = !w;
    if (!w) continue;
    if (s.max) input.max = String(s.max(w));
    if (dragging !== s.id) input.value = String(s.read(w));
    $(`${s.id}Out`).textContent = s.text(w, Number(input.value));
  }
  $('working').setAttribute('aria-pressed', String(model.working));
  $('lapse').setAttribute('aria-pressed', String(lapsing));
  for (const button of document.querySelectorAll('[data-show]')) {
    button.setAttribute('aria-pressed', String(button.dataset.show === model.show));
  }
  for (const button of document.querySelectorAll('[data-sessions]')) {
    button.setAttribute('aria-pressed', String(button.dataset.sessions === sessionsShown));
  }
}
sync(true);

let last = performance.now();
let lastDrawn = 0;
function frame(t) {
  requestAnimationFrame(frame);
  // On the Touch Bar: 60 frames a second while Claude works or something moves, 6 while it's
  // still (enough for a blink).
  const busy = model.working || bars.some(({ bar, row }) => bar.busy || row?.busy);
  if (app && t - lastDrawn < 1000 / (busy ? 60 : 6) - 2) return;
  lastDrawn = t;
  const dt = Math.min(0.1, (t - last) / 1000);
  last = t;
  const simDt = live ? (Date.now() - now) : dt * 1000 * (lapsing ? LAPSE_SPEED : 1);
  now += simDt;
  if (lapsing) lapse(now, simDt);
  sync();
  const v = view(model, now);
  const sessions = sessionsNow();
  for (const entry of bars) {
    if (Math.min(sessions.length, MOST) !== entry.count) mount(entry, Math.min(sessions.length, MOST));
    entry.canvas.hidden = !v.primary;
    if (v.primary) entry.bar.render(v, dt, t / 1000);
    entry.row?.render(sessions, dt, t / 1000);
  }
  app?.postMessage('frame');
}
requestAnimationFrame(frame);

// For the Touch Bar app, for poking at states from the console, and for saving full-size
// PNGs through the dev server.
window.guzzoline = {
  model,
  SCENARIOS,
  bars,
  live: applyUsage,
  // `settle` plays that many seconds first, so a bar has finished moving to the state.
  capture(suffix = '', settle = 4) {
    const v = view(model, now);
    const t = performance.now() / 1000;
    const sessions = sessionsNow();
    for (const entry of bars) if (Math.min(sessions.length, MOST) !== entry.count) mount(entry, Math.min(sessions.length, MOST));
    return Promise.all(bars.map(({ theme, canvas, bar, rowCanvas, row }) => {
      for (let i = 0; i <= settle * 60; i++) {
        const at = t - settle + i / 60;
        bar.render(v, 1 / 60, at);
        row?.render(sessions, 1 / 60, at);
      }
      // The theme and its row, side by side as on the Touch Bar.
      const whole = document.createElement('canvas');
      whole.width = BAR.width;
      whole.height = BAR.height;
      const c = whole.getContext('2d');
      c.drawImage(canvas, 0, 0);
      if (rowCanvas) c.drawImage(rowCanvas, canvas.width, 0);
      return new Promise((done) => whole.toBlob((blob) => {
        fetch(`/__capture?name=${theme.id}${suffix}`, { method: 'POST', body: blob }).then(done);
      }));
    }));
  },
};

// Inside the Touch Bar app: ready for numbers.
app?.postMessage('ready');
