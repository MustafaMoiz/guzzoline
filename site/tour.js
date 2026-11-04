import panelCss from '../src/panel.css?inline';
import { createPanel, mascot } from '../src/panelView.js';
import { createDay } from './day.js';

// The panel, as the app shows it under its icon in the menu bar: the real one (panelView.js),
// with made-up sessions, on a Mac's screen with the desktop around it. Once it's in view a
// pointer opens it and works through it, and the caption under it says what each step is for.
// On a computer, the moment you move your own pointer over it, it's yours to try. On a phone it
// plays like a film, the view following the pointer close enough to read.
const SCREEN = { width: 1180, height: 737 }; // in the panel's own pixels; 16:10, like the Mac's
const SESSIONS = [
  { id: 'a', title: 'Landing page', state: 'working', onBar: true },
  { id: 'b', title: 'Invoice parser', state: 'asking', onBar: true },
  { id: 'c', title: 'Flaky tests', state: 'working', onBar: true },
  { id: 'd', title: 'Release notes', state: 'done', onBar: true },
  { id: 'e', title: 'Tax receipts', state: 'idle', onBar: false },
  { id: 'f', title: 'Blog draft', state: 'idle', onBar: false },
];

const icon = (body, w, h) => `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" fill="none" aria-hidden="true">${body}</svg>`;
// The menu bar's other icons, plainly drawn: a few other apps' (sync, clipboard, a display),
// then Focus, music, volume, Wi-Fi, battery, search and Control Center. With them to its right,
// Clawd sits where the panel, centred under it, has desktop on both sides.
const CLOUD = icon('<path d="M4.6 12.2h8.3a3.3 3.3 0 0 0 .3-6.6 4.6 4.6 0 0 0-8.8.9 2.9 2.9 0 0 0 .2 5.7z" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/>', 18, 14);
const CLIPBOARD = icon('<rect x="1.65" y="2.65" width="10.7" height="11.2" rx="1.6" stroke="currentColor" stroke-width="1.3"/><rect x="4.3" y="1" width="5.4" height="3.2" rx="1" fill="currentColor"/>', 14, 15);
const DISPLAY = icon('<rect x=".65" y="1.15" width="14.7" height="9.4" rx="1.6" stroke="currentColor" stroke-width="1.3"/><path d="M5 13.6h6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>', 16, 15);
const MOON = icon('<path d="M9.8 1.2a6.2 6.2 0 1 0 4 10.4A5.2 5.2 0 0 1 9.8 1.2z" fill="currentColor"/>', 15, 14);
const NOTE = icon('<path d="M5 11.4V2.6l7.2-1.6v8.8" stroke="currentColor" stroke-width="1.3"/><circle cx="3.4" cy="11.4" r="2" fill="currentColor"/><circle cx="10.6" cy="9.8" r="2" fill="currentColor"/>', 14, 14);
const VOLUME = icon('<path d="M1 5h3l4-3.5v11L4 9H1z" fill="currentColor"/><path d="M10.5 4.4c1.2 1.4 1.2 3.4 0 4.8M12.7 2.7c2 2.3 2 6.1 0 8.3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>', 16, 14);
const WIFI = icon('<path d="M1.5 5.2a9.5 9.5 0 0 1 13 0M3.9 7.7a6 6 0 0 1 8.2 0M6.3 10.1a2.6 2.6 0 0 1 3.4 0" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>', 16, 12);
const BATTERY = icon('<rect x=".75" y=".75" width="21.5" height="10.5" rx="3" stroke="currentColor" stroke-width="1.2" opacity=".5"/><rect x="2.5" y="2.5" width="14" height="7" rx="1.6" fill="currentColor"/><path d="M23.6 4.3v3.4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" opacity=".5"/>', 25, 12);
const SEARCH = icon('<circle cx="5.8" cy="5.8" r="4.5" stroke="currentColor" stroke-width="1.5"/><path d="m9.2 9.2 3.6 3.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>', 14, 14);
const SWITCHES = icon('<rect x=".75" y=".75" width="13.5" height="5" rx="2.5" stroke="currentColor" stroke-width="1.2"/><circle cx="11.7" cy="3.25" r="1.5" fill="currentColor"/><rect x=".75" y="8.25" width="13.5" height="5" rx="2.5" stroke="currentColor" stroke-width="1.2"/><circle cx="3.3" cy="10.75" r="1.5" fill="currentColor"/>', 15, 14);
const POINTER = '<svg width="20" height="28" viewBox="0 0 20 28" aria-hidden="true"><path d="M2 1.5v20.2l5.3-5 3.7 8.6 3.4-1.5-3.6-8.4h7.2z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';

const CSS = `
  :host { display: block; }
  .window { position: relative; overflow: hidden; height: var(--window-h, ${SCREEN.height}px); border-radius: 12px;
    box-shadow: 0 34px 70px -24px rgba(30, 8, 0, 0.75), 0 0 0 1px rgba(255, 240, 214, 0.1); }
  .screen { position: absolute; left: 0; top: 0; width: ${SCREEN.width}px; height: ${SCREEN.height}px; transform-origin: 0 0;
    background:
      radial-gradient(60% 70% at 18% 100%, rgba(40, 14, 4, 0.75), transparent 70%),
      radial-gradient(110% 90% at 78% -10%, #f4a54e 0%, #d4732b 28%, #93401a 58%, #3d180a 100%);
    transition: transform 0.9s cubic-bezier(0.45, 0, 0.2, 1); }
  .screen.still { transition: none; }
  .menubar { position: absolute; inset: 0 0 auto; justify-content: space-between; gap: 0; height: 25px; padding: 0 14px 0 18px;
    background: rgba(250, 243, 234, 0.74); -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);
    color: #1a1714; font: 500 13px/1 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; white-space: nowrap; }
  .menubar .menus, .menubar .status { display: flex; align-items: center; height: 100%; }
  .menubar .menus { gap: 20px; }
  .menubar .menus b { font-weight: 700; }
  .menubar .status { gap: 18px; }
  .menubar .status > * { display: flex; align-items: center; }
  .menubar .icon { margin: 0 -2px; padding: 4px 6px; border: 0; border-radius: 4px; background: none; color: inherit; font: inherit; cursor: default; transition: background 0.12s; }
  .menubar .icon.open { background: rgba(0, 0, 0, 0.14); }
  .menubar .clock { font-variant-numeric: tabular-nums; }
  .drop { position: absolute; top: 30px; left: 0; opacity: 0; transform: translateY(-3px); visibility: hidden;
    transition: opacity 0.14s, transform 0.14s, visibility 0s 0.14s; }
  .drop.open { opacity: 1; transform: none; visibility: visible; transition: opacity 0.14s, transform 0.14s; }
  .drop .panel { margin: 0; }
  .pointer { position: absolute; left: 0; top: 0; z-index: 3; pointer-events: none; transform: translate(var(--x), var(--y));
    transition: transform 0.75s cubic-bezier(0.45, 0, 0.2, 1), opacity 0.3s; filter: drop-shadow(0 2px 3px rgba(0, 0, 0, 0.35)); }
  .pointer svg { display: block; transition: transform 0.12s; transform-origin: 2px 2px; }
  .pointer.down svg { transform: scale(0.86); }
  .pointer.gone { opacity: 0; }
`;

// What each step is for, said under the screen while the pointer does it.
const SAY = {
  open: 'Click Clawd in the menu bar for the panel.',
  sessions: 'Choose which sessions get a Clawd on the Touch Bar.',
  theme: 'Pick a theme. The panel changes to match.',
  showing: 'Choose when the Touch Bar shows.',
  sound: 'Pick the sound it plays when it’s your turn.',
  awake: 'Keep your Mac awake with the lid shut.',
  close: 'Click Clawd again to close it.',
  yours: 'Now try it yourself.',
};

// onStep(key): told as each step starts (record.html uses it to cut one loop for a video).
export function createTour(host, { caption = null, reduce = false, onStep = null } = {}) {
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `<style>${panelCss}${CSS}</style>
    <div class="window"><div class="screen">
      <div class="menubar">
        <div class="menus" aria-hidden="true"><b>Claude</b><span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span></div>
        <div class="status">
          <button class="icon" type="button" aria-label="Guzzoline" aria-expanded="false">${mascot}</button>
          <span>${CLOUD}</span><span>${CLIPBOARD}</span><span>${DISPLAY}</span><span>${MOON}</span><span>${NOTE}</span><span>${VOLUME}</span><span>${WIFI}</span><span>${BATTERY}</span><span>${SEARCH}</span><span>${SWITCHES}</span>
          <span class="clock"></span>
        </div>
      </div>
      <div class="drop"></div>
      <div class="pointer gone">${POINTER}</div>
    </div></div>`;
  const $ = (selector) => root.querySelector(selector);
  const win = $('.window');
  const screen = $('.screen');
  const drop = $('.drop');
  const button = $('.menubar .icon');
  const pointer = $('.pointer');

  // The clock, in your own words for the time.
  const clock = $('.clock');
  const day = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
  const time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
  const tick = () => { clock.textContent = `${day.format(new Date()).replace(/,/g, '')}  ${time.format(new Date())}`; };
  tick();
  setInterval(tick, 15e3);

  // The panel draws the five themes again for its cards, so it's made only as you come near.
  // The screen around it is here from the start, so nothing below moves when it arrives.
  let panel = null;
  function makePanel() {
    if (panel) return;
    const model = { ...createDay(Date.now()).at(0, Date.now()), working: true };
    const sessions = SESSIONS.map((s) => ({ ...s }));
    panel = createPanel({ sessions, model, theme: 'walk', showing: 'front', sound: 'Glass' });
    drop.append(panel.el);
    place();
  }
  new IntersectionObserver(([entry], observer) => {
    if (!entry.isIntersecting) return;
    observer.disconnect();
    makePanel();
  }, { rootMargin: '100% 0px' }).observe(host);

  // Where the app puts it: centred under the icon, 5 points below the menu bar, and kept 8
  // from the screen's edges.
  function place() {
    if (!panel) return;
    const middle = button.offsetLeft + button.offsetWidth / 2; // the menu bar starts at the screen's edge
    const w = panel.el.offsetWidth;
    drop.style.left = `${Math.round(Math.min(Math.max(middle - w / 2, 8), SCREEN.width - w - 8))}px`;
  }
  place();
  document.fonts.ready.then(place);
  setInterval(place, 15e3); // the clock's width moves the icon

  function open(on) {
    drop.classList.toggle('open', on);
    button.classList.toggle('open', on);
    button.setAttribute('aria-expanded', String(on));
  }
  button.addEventListener('click', () => open(!drop.classList.contains('open')));
  // As in the app: a click anywhere else closes it.
  screen.addEventListener('click', (event) => {
    if (!event.composedPath().some((el) => el === drop || el === button)) open(false);
  });

  // The caption under the screen, fading from one line to the next.
  let said = '';
  function say(key) {
    const text = SAY[key];
    if (!caption || text === said) return;
    said = text;
    caption.classList.add('hush');
    setTimeout(() => {
      caption.textContent = text;
      caption.classList.remove('hush');
    }, 180);
  }
  if (caption) caption.textContent = SAY.open;

  // The view: on a wide screen, all of it; on a narrow one, closer, following the pointer.
  let scale = 1;
  let follow = false;
  let target = { x: SCREEN.width / 2, y: 140 };
  function layout() {
    const w = win.clientWidth;
    const fit = w / SCREEN.width;
    follow = fit < 0.7;
    scale = follow ? 0.76 : fit;
    win.style.setProperty('--window-h', `${Math.round(follow ? Math.min(SCREEN.height * scale, w * 1.1) : SCREEN.height * fit)}px`);
    aim(target, true);
  }
  function aim(p, now = false) {
    target = p;
    let x = 0;
    let y = 0;
    if (follow) {
      const w = win.clientWidth;
      const h = win.clientHeight;
      x = Math.min(0, Math.max(w - SCREEN.width * scale, w / 2 - p.x * scale));
      y = Math.min(0, Math.max(h - SCREEN.height * scale, h / 2 - p.y * scale));
    }
    screen.classList.toggle('still', now);
    screen.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
  }
  new ResizeObserver(layout).observe(win);

  // Where something is, in the screen's own pixels.
  function spot(el) {
    const s = screen.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const k = s.width / SCREEN.width;
    return { x: (r.left - s.left + r.width / 2) / k, y: (r.top - s.top + r.height / 2) / k };
  }

  // The walk through it. Each step: what it's for, where the pointer goes, a click there, and
  // how long to let it show.
  const at = (selector, i = 0) => () => panel.el.querySelectorAll(selector)[i];
  const STEPS = [
    ['open', () => button, 1.1],
    ['sessions', at('.session', 1), 1.2],
    ['theme', at('.theme', 3), 1.6],
    ['showing', at('.choice', 2), 1.0],
    ['sound', at('.tone', 9), 1.0],
    ['awake', at('.toggle.awake'), 1.2],
    ['theme', at('.theme', 4), 1.6],
    ['sessions', at('.session', 1), 1.0],
    ['theme', at('.theme', 0), 1.2],
    ['close', () => button, 1.4],
  ];
  const REST = { x: 240, y: 520 }; // where the pointer waits, out on the desktop
  let visible = false;
  let yours = false;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  // Waits so long while it's on screen; it holds still while it isn't.
  async function hold(seconds) {
    let left = seconds * 1000;
    while (left > 0 && !yours) {
      await sleep(100);
      if (visible) left -= 100;
    }
  }
  function moveTo(p) {
    pointer.style.setProperty('--x', `${p.x - 2}px`);
    pointer.style.setProperty('--y', `${p.y - 2}px`);
    if (follow) aim(p);
  }
  async function press(el) {
    pointer.classList.add('down');
    await sleep(110);
    pointer.classList.remove('down');
    el.click();
  }
  // Back as it began, out of sight while the panel is shut.
  function reset() {
    at('.choice', 0)().click();
    at('.tone', 5)().click();
    const awake = at('.toggle.awake')();
    if (awake.classList.contains('on')) awake.click();
  }
  async function play() {
    moveTo(REST);
    await hold(0.2);
    pointer.classList.remove('gone');
    while (!yours) {
      for (const [key, find, after] of STEPS) {
        if (yours) return;
        const el = find();
        say(key);
        onStep?.(key);
        moveTo(spot(el));
        await hold(0.85);
        if (yours) return;
        await press(el);
        await hold(after);
      }
      reset();
      moveTo(REST);
      await hold(2.2);
    }
  }

  // Yours to try, the moment your own pointer moves over it (not a finger: that's scrolling).
  function takeOver() {
    if (yours || follow) return;
    yours = true;
    pointer.classList.add('gone');
    open(true);
    say('yours');
  }
  host.addEventListener('pointermove', (event) => {
    if (event.isTrusted && event.pointerType === 'mouse') takeOver();
  });

  let started = false;
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible && !started) {
      started = true;
      makePanel();
      // Without motion: the panel open and still, to look at (and, on a computer, to try).
      if (reduce) open(true);
      else play();
    }
  }, { threshold: 0.35 }).observe(host);

  return {
    // Drawn only while it's on screen.
    frame(t, dt) {
      if (visible && panel) panel.frame(t, dt);
    },
  };
}
