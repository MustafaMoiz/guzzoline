import '@fontsource/ibm-plex-mono/300.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/im-fell-english/400.css';
import '@fontsource/im-fell-english/400-italic.css';
import '@fontsource/im-fell-english-sc/400.css';
import './style.css';
import { THEMES } from './themes/index.js';
import { HOUR, MIN, SCENARIOS, createLapse, createModel, describe, fromUsage, slots, view } from './state.js';
import { until } from './format.js';

const BAR = { width: 2008, height: 60 }; // the 13-inch MacBook Pro's Touch Bar, in pixels
const LAPSE_SPEED = 240; // a 5-hour session in 75 seconds

const params = new URLSearchParams(location.search);
const solo = params.get('solo');
// On the Touch Bar the app feeds real usage in, and copies each frame the page draws, so the
// page draws only as often as it needs to.
const live = params.has('live');
const app = window.webkit?.messageHandlers?.barometer;
document.body.classList.toggle('solo', Boolean(solo));

await Promise.all([
  '300 20px "IBM Plex Mono"', '400 20px "IBM Plex Mono"', '500 20px "IBM Plex Mono"',
  '400 20px "IM Fell English"', 'italic 400 20px "IM Fell English"', '400 20px "IM Fell English SC"',
].map((font) => document.fonts.load(font)));

let now = Date.now();
const model = createModel(now);
if (live) Object.assign(model, { windows: [], live: true });
const lapse = createLapse(model);
let lapsing = false;

const bars = THEMES.filter((t) => !solo || t.id === solo).map((theme) => {
  const section = document.createElement('section');
  section.className = 'theme';
  section.innerHTML = `<h2></h2><p></p><div class="deck"><div class="key esc">esc</div>`
    + `<div class="bar"><canvas></canvas></div><div class="key touchid" aria-hidden="true"></div></div>`;
  section.querySelector('h2').textContent = theme.name;
  section.querySelector('p').textContent = theme.note;
  const canvas = section.querySelector('canvas');
  canvas.width = BAR.width;
  canvas.height = BAR.height;
  canvas.setAttribute('aria-label', `${theme.name} theme`);
  document.getElementById('themes').append(section);
  return { theme, canvas, bar: theme.create(canvas, BAR) };
});

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
}
sync(true);

let last = performance.now();
let lastDrawn = 0;
function frame(t) {
  requestAnimationFrame(frame);
  // On the Touch Bar: 24 frames a second while Claude works or something moves, 6 otherwise
  // (enough for a blink).
  const busy = model.working || bars.some(({ bar }) => bar.busy);
  if (app && t - lastDrawn < 1000 / (busy ? 24 : 6) - 2) return;
  lastDrawn = t;
  const dt = Math.min(0.1, (t - last) / 1000);
  last = t;
  const simDt = live ? (Date.now() - now) : dt * 1000 * (lapsing ? LAPSE_SPEED : 1);
  now += simDt;
  if (lapsing) lapse(now, simDt);
  sync();
  const v = view(model, now);
  for (const { canvas, bar } of bars) {
    canvas.hidden = !v.primary;
    if (v.primary) bar.render(v, dt, t / 1000);
  }
  app?.postMessage('frame');
}
requestAnimationFrame(frame);

// For the Touch Bar app, for poking at states from the console, and for saving full-size
// PNGs through the dev server.
window.barometer = {
  model,
  SCENARIOS,
  live: applyUsage,
  // `settle` plays that many seconds first, so a bar has finished moving to the state.
  capture(suffix = '', settle = 4) {
    const v = view(model, now);
    const t = performance.now() / 1000;
    return Promise.all(bars.map(({ theme, canvas, bar }) => {
      for (let i = 0; i < settle * 60; i++) bar.render(v, 1 / 60, t - settle + i / 60);
      bar.render(v, 1 / 60, t);
      return new Promise((done) => canvas.toBlob((blob) => {
        fetch(`/__capture?name=${theme.id}${suffix}`, { method: 'POST', body: blob }).then(done);
      }));
    }));
  },
};

// Inside the Touch Bar app: ready for numbers.
app?.postMessage('ready');
