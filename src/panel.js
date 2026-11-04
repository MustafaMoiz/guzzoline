import '@fontsource/ibm-plex-mono/300.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import './panel.css';
import { createModel, fromUsage } from './state.js';
import { SAMPLE_SESSIONS } from './sessions.js';
import { SOUNDS, createPanel, mascot } from './panelView.js';

// A prototype of the panel that replaces Guzzoline's menu (built in panelView.js), hanging from
// a slice of the menu bar, with your own sessions, usage and settings when the app has them.
await Promise.all(['400 13px "IBM Plex Mono"', '500 13px "IBM Plex Mono"', '300 13px "IBM Plex Mono"',
  '500 13px "Barlow Condensed"', '600 13px "Barlow Condensed"'].map((font) => document.fonts.load(font)));

const get = (url, fallback) => fetch(url).then((r) => (r.ok ? r.json() : fallback)).catch(() => fallback);
const [recent, cached, prefs] = await Promise.all([get('/__recent', []), get('/__usage', null), get('/__prefs', {})]);
const sessions = (recent.length ? recent : SAMPLE_SESSIONS.map((s) => ({ ...s, onBar: true }))).map((s) => ({ ...s }));

// Your usage, as the bar draws it.
const model = createModel(Date.now());
const windows = cached?.usage ? fromUsage(cached.usage) : [];
if (windows.length) model.windows = windows;

const sounds = new Map();
function play(name) {
  if (!sounds.has(name)) sounds.set(name, new Audio(`/__sound?name=${name}`));
  const sound = sounds.get(name);
  sound.currentTime = 0;
  sound.play().catch(() => {});
}

const panel = createPanel({ sessions, model, theme: prefs.theme, showing: prefs.showing ?? 'front', sound: prefs.sound, play });
const column = document.createElement('div');
column.className = 'option';
column.innerHTML = `<div class="menubar"><span class="icon">${mascot}</span><span class="clock">Wed 4 Nov 01:42</span></div>`;
column.append(panel.el);
document.getElementById('desk').append(column);

let last = performance.now();
function frame(ms) {
  const t = ms / 1000;
  const dt = Math.min(0.1, (ms - last) / 1000);
  last = ms;
  panel.frame(t, dt);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
