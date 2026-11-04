import { THEMES } from './themes/index.js';
import { view } from './state.js';
import { animate, draw, pose } from './clawd.js';
import { MOST, createRow, rowWidth } from './sessions.js';

// The panel that replaces Guzzoline's menu, dressed in the theme you've picked. It works as it
// would in the app: every theme's card is the Touch Bar as it would look, crew and all, and
// changes as you show or hide sessions; picking a theme restyles the panel; sounds play as you
// pick them, and nothing closes it. panel.html shows it with your own sessions; the landing
// page, with made-up ones.
export const SOUNDS = ['Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse', 'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink'];
const SHOWING = [['front', 'Only in Claude'], ['open', 'While Claude is open'], ['always', 'In every app']];
const COLOUR = { working: '#e0443e', asking: '#f5a623', done: '#4fb477', failed: '#4fb477', idle: '#4a86d8' };
const BAR = { width: 2008, height: 60 };

const icon = (body, w, h) => `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" fill="none" aria-hidden="true">${body}</svg>`;
const SPEAKER = icon('<path d="M1 5h3l4-3.5v13L4 11H1z" fill="currentColor"/><path d="M10.5 5c1.4 1.6 1.4 4.4 0 6M12.6 3c2.5 2.8 2.5 7.2 0 10" stroke="currentColor" stroke-width="1.3"/>', 16, 16);
const MUTED = icon('<path d="M1 5h3l4-3.5v13L4 11H1z" fill="currentColor"/><path d="m10.5 5.5 5 5m0-5-5 5" stroke="currentColor" stroke-width="1.3"/>', 16, 16);
const POWER = icon('<path d="M8 1.5v6" stroke="currentColor" stroke-width="1.4"/><path d="M4.6 3.6a5.5 5.5 0 1 0 6.8 0" stroke="currentColor" stroke-width="1.4"/>', 16, 16);
// Clawd for the menu bar, from the app's template image.
const MASCOT = ['..#############..', '..#############..', '..##.#######.##..', '..##.#######.##..', '#################',
  '#################', '..#############..', '..#############..', '..#.#.......#.#..', '..#.#.......#.#..'];
export const mascot = icon(MASCOT.flatMap((row, r) => [...row].map((ch, c) => (ch === '#' ? `<rect x="${c}" y="${r}" width="1" height="1" fill="currentColor"/>` : ''))).join(''), 17, 10);

const checkRow = (cls, label, on) => `<button class="toggle ${cls}${on ? ' on' : ''}" type="button" role="checkbox" aria-checked="${on}"><span class="check"></span>${label}</button>`;

// Each session's Clawd, in two dimensions, as the bar acts it out: walking, hopping with an arm
// up, cheering, looking from side to side, or asleep; still and dim while it's off the bar.
function glyph(state, t, seed) {
  if (state === 'working') return { grid: animate(t + seed, { working: true }), lift: 0 };
  if (state === 'asking') {
    const p = ((t + seed) % 1.4) / 1.4;
    return { grid: pose({ arms: Math.floor((t + seed) * 4) % 2 ? 'one-up' : 'up' }), lift: p < 0.32 ? Math.sin((p / 0.32) * Math.PI) * 2 : 0 };
  }
  if (state === 'done') {
    const p = ((t + seed) % 3) / 3;
    return p < 0.16 ? { grid: pose({ arms: 'up' }), lift: Math.sin((p / 0.16) * Math.PI) * 1.5 } : { grid: animate(t + seed), lift: 0 };
  }
  if (state === 'failed') {
    const p = ((t + seed) % 2) / 2;
    return { grid: pose({ eyes: p < 0.3 ? (Math.floor((p / 0.3) * 4) % 2 ? 'left' : 'right') : 'open' }), lift: 0 };
  }
  return { grid: pose({ eyes: 'closed' }), lift: 0 };
}

// sessions: [{ id, title, state, onBar }], changed in place as you show and hide them.
// model: the usage the theme cards draw. play(name): one of the Mac's sounds.
export function createPanel({ sessions, model, theme = 'walk', showing: shown = 'front', sound = 'Glass', play = () => {} }) {
  const onBar = () => sessions.filter((s) => s.onBar);
  const ink = (el, name) => getComputedStyle(el).getPropertyValue(name).trim();

  const el = document.createElement('section');
  el.className = 'panel';
  el.dataset.skin = THEMES.some((t) => t.id === theme) ? theme : 'walk';
  // Sessions beside when the bar shows and how it sounds; across the bottom, the themes as the
  // Touch Bar itself, as wide as the panel; then the app's own settings.
  el.innerHTML = `
    <div class="cols">
      <div class="col">
        <div class="head"><h3>Sessions</h3><span class="lead"></span></div>
        <ul class="sessions"></ul>
      </div>
      <div class="col">
        <div class="head"><h3>Show the bar</h3><span class="lead"></span></div>
        <ul class="showing"></ul>
        <div class="head"><h3>Sound</h3><span class="lead"></span></div>
        <div class="sound"><button class="mute" type="button" aria-label="Sound on" title="Sound on">${SPEAKER}</button><ul class="tones"></ul></div>
      </div>
    </div>
    <div class="band">
      <div class="head"><h3>Theme</h3><span class="lead"></span></div>
      <ul class="themes"></ul>
    </div>
    <div class="foot">
      ${checkRow('login', 'Open at login', true)}
      ${checkRow('awake', 'Stay awake with the lid shut', false)}
      <span class="spring"></span>
      <button class="quit" type="button" aria-label="Quit Guzzoline" title="Quit Guzzoline">${POWER}</button>
    </div>`;

  // Sessions: a click puts one on the bar or takes it off. Its Clawd says which, lit or a dim
  // silhouette, and says what the session is doing; showing a fifth hides the one you've been
  // away from longest.
  const glyphs = [];
  const list = el.querySelector('.sessions');
  sessions.forEach((s, i) => {
    const row = document.createElement('li');
    row.className = `session${s.onBar ? ' on' : ''}`;
    row.title = s.title;
    row.innerHTML = '<span class="title"></span><canvas width="36" height="28"></canvas>';
    row.querySelector('.title').textContent = s.title;
    row.addEventListener('click', () => {
      const before = onBar().length;
      if (!s.onBar && before >= MOST) {
        // The list runs from the latest; the last one shown is the one you've been away from longest.
        const out = onBar().at(-1);
        out.onBar = false;
        out.row.classList.remove('on');
      }
      s.onBar = !s.onBar;
      row.classList.toggle('on', s.onBar);
      if (onBar().length !== before) mountAll(true);
    });
    s.row = row;
    list.append(row);
    glyphs.push({ canvas: row.querySelector('canvas'), s, seed: i * 0.61 });
  });

  // Themes: the Touch Bar as it would look in each, with the Clawds for the sessions you're
  // showing, and no names: the bars say it. Picking one dresses the panel in it.
  const stages = [];
  const themes = el.querySelector('.themes');
  for (const t of THEMES) {
    const item = document.createElement('li');
    item.className = `theme${t.id === el.dataset.skin ? ' on' : ''}`;
    item.title = t.name;
    item.innerHTML = '<div class="stage"></div>';
    item.addEventListener('click', () => {
      themes.querySelectorAll('.theme').forEach((other) => other.classList.toggle('on', other === item));
      el.dataset.skin = t.id;
    });
    themes.append(item);
    stages.push({ theme: t, holder: item.querySelector('.stage') });
  }

  // Each theme draws off screen, and the one crew they share draws once; what's shown are plain
  // canvases they're copied onto. So no card can lose its picture, and the browser keeps six
  // drawing contexts rather than one per card. (Past about sixteen it drops the oldest, which
  // went white.)
  const canvasFor = (width) => {
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = BAR.height;
    return canvas;
  };
  const release = (canvas) => canvas?.getContext('webgl2')?.getExtension('WEBGL_lose_context')?.loseContext();
  let crew = null; // { canvas, row, width }

  function paint(stage, t, dt, v) {
    stage.bar.render(v, dt, t);
    const ctx = stage.view.getContext('2d');
    ctx.drawImage(stage.canvas, 0, 0);
    if (crew) ctx.drawImage(crew.canvas, BAR.width - crew.width, 0);
  }

  // The theme narrows to make room for the crew, laid out again for its new width, as on the bar;
  // the new picture fades in over the old.
  function mountAll(fade) {
    const count = Math.min(MOST, onBar().length);
    const rowW = rowWidth(count);
    release(crew?.canvas);
    crew = count ? { canvas: canvasFor(rowW), width: rowW } : null;
    if (crew) crew.row = createRow(crew.canvas, { width: rowW, height: BAR.height });
    const t = performance.now() / 1000;
    const v = view(model, Date.now());
    crew?.row.render(onBar().slice(0, MOST), 1 / 60, t);
    for (const stage of stages) {
      release(stage.canvas);
      stage.canvas = canvasFor(BAR.width - rowW);
      stage.bar = stage.theme.create(stage.canvas, { width: BAR.width - rowW, height: BAR.height });
      const old = stage.view;
      stage.view = canvasFor(BAR.width);
      paint(stage, t, 1 / 60, v);
      if (!old || !fade) {
        stage.holder.replaceChildren(stage.view);
        continue;
      }
      stage.view.classList.add('arriving');
      stage.holder.append(stage.view);
      requestAnimationFrame(() => requestAnimationFrame(() => stage.view.classList.remove('arriving')));
      setTimeout(() => old.remove(), 450);
    }
  }
  mountAll(false);

  // When the bar shows, in so many words.
  const showing = el.querySelector('.showing');
  for (const [id, label] of SHOWING) {
    const item = document.createElement('li');
    item.className = `choice${id === shown ? ' on' : ''}`;
    item.innerHTML = `<i class="radio"></i>${label}`;
    item.addEventListener('click', () => showing.querySelectorAll('.choice').forEach((c) => c.classList.toggle('on', c === item)));
    showing.append(item);
  }
  el.querySelectorAll('.toggle').forEach((t) => t.addEventListener('click', () => {
    const on = t.classList.toggle('on');
    t.setAttribute('aria-checked', String(on));
  }));

  // Sound: the speaker turns it on or off; each square is one of the Mac's sounds, and a click
  // plays it and picks it.
  const soundRow = el.querySelector('.sound');
  const tones = el.querySelector('.tones');
  const picked = SOUNDS.includes(sound) ? sound : 'Glass';
  for (const name of SOUNDS) {
    const tone = document.createElement('li');
    tone.className = `tone${name === picked ? ' on' : ''}`;
    tone.title = name;
    tone.addEventListener('click', () => {
      tones.querySelectorAll('.tone').forEach((t) => t.classList.toggle('on', t === tone));
      soundRow.classList.remove('off');
      play(name);
    });
    tones.append(tone);
  }
  const mute = el.querySelector('.mute');
  mute.addEventListener('click', () => {
    const off = soundRow.classList.toggle('off');
    mute.innerHTML = off ? MUTED : SPEAKER;
    mute.title = mute.ariaLabel = off ? 'Sound off' : 'Sound on';
  });

  return {
    el,
    // One frame: the theme cards, with their crew, and each session's Clawd.
    frame(t, dt) {
      const v = view(model, Date.now());
      crew?.row.render(onBar().slice(0, MOST), dt, t);
      for (const stage of stages) paint(stage, t, dt, v);
      for (const g of glyphs) {
        const ctx = g.canvas.getContext('2d');
        const { grid, lift } = g.s.onBar ? glyph(g.s.state, t, g.seed) : { grid: pose(), lift: 0 };
        ctx.clearRect(0, 0, g.canvas.width, g.canvas.height);
        // Two device pixels a unit, so it's crisp at twice the screen's scale.
        draw(ctx, grid, 1, 6 - Math.round(lift * 2), 2, g.s.onBar ? COLOUR[g.s.state] ?? COLOUR.idle : ink(el, '--ghost'));
      }
    },
  };
}
