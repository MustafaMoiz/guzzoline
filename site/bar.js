import { THEMES } from '../src/themes/index.js';
import { createRow, rowWidth, slotAt } from '../src/sessions.js';
import { view } from '../src/state.js';

// The 13-inch MacBook Pro's Touch Bar, in pixels.
const BAR = { width: 2008, height: 60 };
const HOLD = 0.5; // seconds a finger rests on a Clawd before it listens
const FADE = 0.45; // seconds to cross from one theme to the next

// How each theme dresses the recording card: its ink, and the shape of the waveform.
const DRESS = {
  walk: { ink: '#f2efe9', muted: '#8b877f', wave: 'capsule' },
  phosphor: { ink: '#ff8a5c', muted: '#8f4c35', wave: 'capsule', glow: 10 },
  engraving: { ink: '#ece8e0', muted: '#8e8a82', wave: 'hairline' },
  marquee: { ink: '#ffa040', muted: '#7d4d22', wave: 'lamps', glow: 8 },
  incense: { ink: '#ffb27a', muted: '#8d6a55', wave: 'ember', glow: 12 },
};

// What you might say to each made-up session.
const SAID = ['Ship it once the tests pass', 'Use the March totals', 'Retry it, then merge', 'Mention the new themes'];
const WORDS = { working: 'working', asking: 'needs you', done: 'done', failed: 'failed', idle: 'dozing' };

export function createBar(holder, count) {
  const rowW = rowWidth(count);
  const width = BAR.width - rowW;

  holder.style.aspectRatio = `${BAR.width} / ${BAR.height}`;
  holder.innerHTML = `<div class="lit"><div class="screen"></div><canvas class="crew" aria-label="Sessions"></canvas></div>`
    + '<div class="front left"></div><div class="front right"></div>';
  const lit = holder.querySelector('.lit');
  const screen = holder.querySelector('.screen');
  screen.style.width = `${(width / BAR.width) * 100}%`;
  const crewCanvas = holder.querySelector('.crew');
  crewCanvas.style.width = `${(rowW / BAR.width) * 100}%`;

  const themes = THEMES.map((theme) => {
    const canvas = document.createElement('canvas');
    canvas.setAttribute('aria-label', `${theme.name} theme`);
    canvas.style.opacity = '0';
    screen.append(canvas);
    return { theme, canvas, bar: theme.create(canvas, { width, height: BAR.height }) };
  });
  const row = createRow(crewCanvas, { width: rowW, height: BAR.height });

  // Over the usage: a session's title while its Clawd is touched, and the recording card.
  const reading = Object.assign(document.createElement('div'), { className: 'reading', hidden: true });
  const voice = Object.assign(document.createElement('canvas'), { className: 'voice', width, height: BAR.height, hidden: true });
  screen.append(reading, voice);
  const ctx = voice.getContext('2d');

  // A ring that fills round the touched Clawd while you hold it.
  const ring = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  ring.setAttribute('class', 'ring');
  ring.setAttribute('viewBox', '0 0 60 60');
  ring.innerHTML = '<circle cx="30" cy="30" r="25" pathLength="1"/>';
  ring.style.display = 'none';
  lit.append(ring);

  let active = 0;
  let fading = null; // { from, p }
  let press = null; // { i, held, talking, off, start }
  let status = null; // { text, until }
  const busyUntil = new Map(); // a session you just spoke to works for a while
  let waveLevels = new Array(64).fill(0);

  const slotFrom = (event) => {
    const box = crewCanvas.getBoundingClientRect();
    const x = ((event.clientX - box.left) / box.width) * rowW;
    return Math.max(0, Math.min(count - 1, slotAt(x)));
  };

  function placeRing(i) {
    // A Clawd stands at PAD + i·SLOT + 25 in the row's pixels (see src/sessions.js).
    const box = lit.getBoundingClientRect();
    const crew = crewCanvas.getBoundingClientRect();
    const scale = crew.width / rowW;
    ring.style.left = `${crew.left - box.left + (22 + i * 72 + 25) * scale}px`;
    ring.style.top = `${crew.top - box.top + crew.height / 2}px`;
    ring.style.setProperty('--size', `${crew.height * 0.92}px`);
    ring.style.display = '';
  }

  let sessions = [];
  crewCanvas.addEventListener('pointerdown', (event) => {
    try { crewCanvas.setPointerCapture(event.pointerId); } catch { /* not a real pointer */ }
    const i = slotFrom(event);
    press = { i, held: 0, talking: false, off: false, start: 0 };
    placeRing(i);
  });
  crewCanvas.addEventListener('pointermove', (event) => {
    if (!press) return;
    if (press.talking) {
      // Sliding off the Clawds cancels, as on the Touch Bar.
      const box = holder.getBoundingClientRect();
      const crew = crewCanvas.getBoundingClientRect();
      press.off = event.clientX < crew.left - 12 || event.clientY < box.top - 48 || event.clientY > box.bottom + 48;
      return;
    }
    const i = slotFrom(event);
    if (i !== press.i) Object.assign(press, { i, held: 0 });
    placeRing(i);
  });
  const lift = () => {
    if (!press) return;
    const s = sessions[press.i];
    if (press.talking && s) {
      if (press.off) status = { text: 'Cancelled', until: performance.now() / 1000 + 1.2 };
      else {
        status = { text: `Sent to ${s.title}`, until: performance.now() / 1000 + 1.8 };
        busyUntil.set(press.i, performance.now() / 1000 + 7);
      }
    }
    press = null;
    ring.style.display = 'none';
  };
  crewCanvas.addEventListener('pointerup', lift);
  crewCanvas.addEventListener('pointercancel', lift);

  function drawVoice(t, dt, s, said, dress) {
    const h = BAR.height;
    ctx.clearRect(0, 0, width, h);
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, width, h);
    ctx.shadowColor = dress.ink;
    ctx.shadowBlur = dress.glow ?? 0;
    // A red dot, breathing.
    ctx.globalAlpha = 0.65 + 0.35 * Math.sin(t * 5);
    ctx.fillStyle = '#e0443e';
    ctx.beginPath();
    ctx.arc(30, h / 2, 6, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.fillStyle = dress.ink;
    ctx.font = '600 26px "Barlow Condensed"';
    ctx.textBaseline = 'middle';
    ctx.fillText(s.title, 48, h / 2 + 1);
    const nameEnd = 48 + ctx.measureText(s.title).width + 28;

    // Your voice: a level a 20th of a second, flowing in from the right.
    const spoken = Math.min(said.length, Math.floor((t - press.start) * 11));
    const speaking = spoken < said.length && Math.sin(t * 7.3) + Math.sin(t * 3.1) > -1.1;
    const target = speaking ? 0.25 + 0.75 * Math.abs(Math.sin(t * 13.7) * Math.cos(t * 5.9)) : 0.04;
    waveLevels.push(waveLevels[waveLevels.length - 1] + (target - waveLevels[waveLevels.length - 1]) * Math.min(1, dt * 18));
    waveLevels = waveLevels.slice(-64);
    const waveEnd = width * 0.6;
    const step = 9;
    const bars = Math.floor((waveEnd - nameEnd) / step);
    for (let b = 0; b < bars; b++) {
      const level = waveLevels[waveLevels.length - bars + b] ?? 0;
      const x = nameEnd + b * step;
      const half = Math.max(1, level * (h * 0.36));
      ctx.globalAlpha = 0.35 + 0.65 * (b / bars);
      ctx.fillStyle = dress.ink;
      ctx.strokeStyle = dress.ink;
      if (dress.wave === 'capsule') {
        ctx.beginPath();
        ctx.roundRect(x, h / 2 - half, 4, half * 2, 2);
        ctx.fill();
      } else if (dress.wave === 'hairline') {
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(x + 2, h / 2 - half);
        ctx.lineTo(x + 2, h / 2 + half);
        ctx.stroke();
      } else if (dress.wave === 'lamps') {
        for (let y = -2; y <= 2; y++) {
          ctx.globalAlpha = Math.abs(y) * 0.18 <= level ? 0.95 * (0.35 + 0.65 * (b / bars)) : 0.12;
          ctx.beginPath();
          ctx.arc(x + 2, h / 2 + y * 9, 2.6, 0, Math.PI * 2);
          ctx.fill();
        }
      } else {
        ctx.beginPath();
        ctx.arc(x + 2, h / 2 - half * 0.6, 1.6 + level * 2.2, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    ctx.globalAlpha = 1;
    ctx.shadowBlur = 0;
    ctx.fillStyle = dress.muted;
    ctx.font = '400 19px "IBM Plex Mono"';
    ctx.fillText(said.slice(0, spoken), waveEnd + 24, h / 2 + 1);
    ctx.textAlign = 'right';
    ctx.font = '400 15px "IBM Plex Mono"';
    ctx.fillText(press.off ? 'let go to cancel' : 'let go to send', width - 22, h / 2 + 1);
    ctx.textAlign = 'left';
  }

  function drawStatus(text, dress) {
    const h = BAR.height;
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, width, h);
    ctx.fillStyle = dress.ink;
    ctx.shadowColor = dress.ink;
    ctx.shadowBlur = dress.glow ?? 0;
    ctx.font = '500 22px "IBM Plex Mono"';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, 30, h / 2 + 1);
    ctx.shadowBlur = 0;
  }

  return {
    width,
    themes: THEMES,
    get active() { return active; },
    show(i) {
      if (i === active) return;
      fading = { from: active, p: 0 };
      active = i;
    },
    // How far the bar is lit, from the middle out: 0 dark, 1 whole.
    open(v) { holder.style.setProperty('--open', String(v)); },
    // A tap on the style showing, for those that answer one (Marquee crawls).
    tap() { themes[active].bar.tap?.(); },
    render(model, list, now, dt, t) {
      sessions = list.map((s, i) => (busyUntil.get(i) > t ? { ...s, state: 'working' } : s));
      const v = view(model, now);
      if (fading) fading.p = Math.min(1, fading.p + dt / FADE);
      themes.forEach((entry, i) => {
        const showing = i === active || (fading && fading.p < 1 && i === fading.from);
        const alpha = i === active ? (fading ? fading.p : 1) : fading && i === fading.from ? 1 - fading.p : 0;
        entry.canvas.style.opacity = String(alpha);
        // Only the style showing takes a click (the others sit over it, unseen).
        entry.canvas.style.pointerEvents = i === active ? '' : 'none';
        if (showing) {
          entry.bar.render(v, dt, t);
        }
      });
      if (fading?.p >= 1) fading = null;
      row.touch(press ? press.i : -1);
      row.render(sessions, dt, t);

      const dress = DRESS[THEMES[active].id];
      const s = press ? sessions[press.i] : null;
      if (press && !press.talking) {
        press.held += dt;
        ring.style.setProperty('--held', String(Math.min(1, press.held / HOLD)));
        if (press.held >= HOLD) Object.assign(press, { talking: true, start: t });
      }
      if (press?.talking && s) {
        voice.hidden = false;
        reading.hidden = true;
        ring.style.setProperty('--held', '1');
        drawVoice(t, dt, s, SAID[press.i % SAID.length], dress);
      } else if (status && performance.now() / 1000 < status.until) {
        voice.hidden = false;
        reading.hidden = true;
        drawStatus(status.text, dress);
      } else {
        status = null;
        voice.hidden = true;
        if (press && s) {
          reading.hidden = false;
          reading.style.fontSize = `${Math.min(24, screen.clientHeight * 0.44)}px`;
          reading.replaceChildren(s.title, Object.assign(document.createElement('span'), { textContent: WORDS[s.state] ?? '' }));
        } else reading.hidden = true;
      }
    },
  };
}
