import * as THREE from 'three';
import { animate } from '../clawd.js';
import { draw as drawText, width as textWidth } from '../pixelfont.js';
import { clock, pct, until, weekday } from '../format.js';
import { DAY } from '../state.js';

// An LED sign, 401 × 12 dots at a 5 px pitch. Every frame the content is laid out in dots, and
// a shader draws each dot as a lamp with a halo. Now and then a sentence crawls across it.
const ROWS = 12;
const PITCH = 5;
const CRAWL_SPEED = 46; // dots a second
const CRAWL_EVERY = 45; // seconds

// Laid out in dots from the sign's right edge: the second limit's figures end there, its
// meter sits before them, then the first limit's figures; the first meter takes the rest.
function layout(cols) {
  const right = cols - 3;
  const week = { x: right - 54 - 77, w: 77, top: 4, rows: 4 };
  const text = week.x - 64;
  return { right, text, bar: { x: 23, w: text - 6 - 23, top: 3, rows: 6 }, week };
}

const vertexShader = 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0., 1.); }';
const fragmentShader = /* glsl */ `
  uniform sampler2D frame; // r: brightness, g: 1 for an orange lamp
  uniform vec2 size;
  uniform vec2 grid;
  uniform float pitch;
  uniform vec2 offset;
  varying vec2 vUv;
  void main() {
    vec2 p = vUv * size;
    vec2 cell = floor((p - offset) / pitch);
    vec3 col = vec3(0.0);
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        vec2 c = cell + vec2(float(dx), float(dy));
        if (c.x < 0.0 || c.y < 0.0 || c.x >= grid.x || c.y >= grid.y) continue;
        vec4 f = texture2D(frame, (c + 0.5) / grid);
        vec3 tint = mix(vec3(1.0, 0.8, 0.62), vec3(1.0, 0.36, 0.2), f.g);
        float d = length(p - ((c + 0.5) * pitch + offset));
        if (dx == 0 && dy == 0) {
          float disc = 1.0 - smoothstep(1.3, 1.9, d);
          col += mix(vec3(0.018, 0.016, 0.015), tint * 1.1, f.r) * disc;
        }
        col += tint * f.r * exp(-d * d / 7.0) * 0.22;
      }
    }
    gl_FragColor = vec4(col, 1.0);
    #include <colorspace_fragment>
  }
`;

// A page of lamps: brightness and colour per dot, rows counted from the top.
function page(cols) {
  const level = new Float32Array(cols * ROWS);
  const orange = new Uint8Array(cols * ROWS);
  return {
    cols,
    level,
    orange,
    clear() { level.fill(0); orange.fill(0); },
    set(c, r, v = 1, o = 0) {
      if (c < 0 || c >= cols || r < 0 || r >= ROWS) return;
      level[r * cols + c] = v;
      orange[r * cols + c] = o;
    },
  };
}

const timeText = (ts) => {
  const { time, period } = clock(ts);
  return period ? `${time} ${period}` : time;
};

function resetShort(win) {
  if (!win.active) return '';
  if (win.status === 'out') return until(win.resetIn).replace(/ /g, '');
  if (win.kind === 'session' || win.resetIn < DAY) return timeText(win.resetsAt);
  return weekday(win.resetsAt);
}

// "66% of the session left · resets at 1:18 — 59% of the week left · resets Sat"
function phrase(win) {
  if (!win.active) return `${win.phrase} is fresh`;
  if (win.status === 'out') return `${win.phrase} is spent · back in ${until(win.resetIn)}`;
  const when = win.kind === 'session' || win.resetIn < DAY ? `at ${timeText(win.resetsAt)}` : weekday(win.resetsAt);
  return `${pct(win.left)}% of ${win.phrase} left · resets ${when}`;
}

const sentence = (v) => [v.primary, v.secondary].filter(Boolean).map(phrase).join(' — ').toUpperCase();

export default {
  id: 'marquee',
  name: 'Marquee',
  note: 'An LED sign. Now and then it spells the numbers out (click it); lamps chase while Claude works.',

  create(canvas, { width, height }) {
    const COLS = Math.floor(width / PITCH);
    const { right: RIGHT, text: TEXT, bar: BAR, week: WEEK } = layout(COLS);
    const renderer = new THREE.WebGLRenderer({ canvas });
    renderer.setPixelRatio(1);
    renderer.setSize(width, height, false);

    const data = new Uint8Array(COLS * ROWS * 4);
    const frame = new THREE.DataTexture(data, COLS, ROWS, THREE.RGBAFormat);
    frame.minFilter = frame.magFilter = THREE.NearestFilter;
    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.ShaderMaterial({
      uniforms: {
        frame: { value: frame },
        size: { value: new THREE.Vector2(width, height) },
        grid: { value: new THREE.Vector2(COLS, ROWS) },
        pitch: { value: PITCH },
        offset: { value: new THREE.Vector2((width - COLS * PITCH) / 2, (height - ROWS * PITCH) / 2) },
      },
      vertexShader,
      fragmentShader,
    })));

    const dash = page(COLS);
    let message = null;
    let crawl = -1; // dots scrolled, or -1 when the dashboard is standing still
    let nextCrawl = null; // in seconds of animation time
    let clicked = false;
    canvas.addEventListener('pointerdown', () => { clicked = true; });

    function text(p, str, x, r, v = 1) {
      return drawText(str, x, r, (c, rr) => p.set(c, rr, v));
    }

    // Lit up to the fraction, the rest of the meter glowing faintly; a week is ruled in days.
    function meter(p, box, fraction, pace, chase, t, days = 0) {
      const lit = Math.round(fraction * box.w);
      for (let c = 0; c < box.w; c++) {
        const dayLine = days && c > 0 && c % Math.round(box.w / days) === 0;
        for (let r = 0; r < box.rows; r++) {
          let v = c < lit ? 1 : 0.1;
          if (c < lit && chase && (c - Math.floor(t * 14)) % 6 === 0) v = 0.35;
          if (dayLine) v = 0;
          p.set(box.x + c, box.top + r, v);
        }
      }
      if (pace != null) {
        const c = box.x + Math.round(pace * box.w);
        p.set(c, box.top - 2, 0.55);
        p.set(c, box.top + box.rows + 1, 0.55);
      }
    }

    function dashboard(v, t) {
      const s = v.primary;
      const w = v.secondary;
      const used = v.show === 'used';
      dash.clear();
      const asleep = s.status === 'out' || w?.status === 'out';
      const grid = animate(t, { working: v.working && !asleep, asleep });
      grid.forEach((row, r) => row.forEach((on, c) => { if (on) dash.set(2 + c, 1 + r, 1, 1); }));

      meter(dash, BAR, used ? s.used : s.left, s.active ? (used ? s.elapsed : 1 - s.elapsed) : null,
        v.working && !asleep, t, s.kind === 'week' ? 7 : 0);
      const blinkOff = Math.floor(t * 1.6) % 2 === 1;
      let x = text(dash, `${pct(used ? s.used : s.left)}%`, TEXT, 2);
      if (!(s.status === 'out' && blinkOff)) text(dash, resetShort(s).toUpperCase(), x + 4, 2, 0.6);
      if (!w) return;

      const weekNumber = `${pct(used ? w.used : w.left)}%`;
      const weekReset = resetShort(w).toUpperCase();
      // The figures need more room when the week resets within the day and shows a time; the
      // meter makes it, rather than being written over.
      const figures = textWidth(weekNumber) + 5 + textWidth(weekReset);
      const meterBox = { ...WEEK, w: Math.max(20, Math.min(WEEK.w, RIGHT - figures - 6 - WEEK.x)) };
      meter(dash, meterBox, used ? w.used : w.left, w.active ? (used ? w.elapsed : 1 - w.elapsed) : null, false, t, 7);
      // A text's end is a dot of spacing past its last glyph, and the reset starts 4 dots after.
      x = text(dash, weekNumber, RIGHT - (textWidth(weekNumber) + 5 + textWidth(weekReset)), 2);
      if (!(w.status === 'out' && blinkOff)) text(dash, weekReset, x + 4, 2, 0.6);
    }

    function show(at) {
      for (let r = 0; r < ROWS; r++) {
        for (let c = 0; c < COLS; c++) {
          let v = 0;
          let o = 0;
          const tx = c + at;
          const src = (p, x) => { v = p.level[r * p.cols + x]; o = p.orange[r * p.cols + x]; };
          if (tx < COLS) src(dash, tx);
          else if (message && tx >= COLS + 40 && tx < COLS + 40 + message.cols) src(message, tx - COLS - 40);
          else if (message && tx >= COLS + 80 + message.cols) src(dash, tx - (COLS + 80 + message.cols));
          const i = ((ROWS - 1 - r) * COLS + c) * 4;
          data[i] = Math.round(v * 255);
          data[i + 1] = o ? 255 : 0;
        }
      }
      frame.needsUpdate = true;
    }

    return {
      busy: false,
      render(v, dt, t) {
        dashboard(v, t);
        nextCrawl ??= t + 12;
        if (clicked) nextCrawl = t;
        clicked = false;
        if (crawl < 0 && t >= nextCrawl) {
          const str = sentence(v);
          message = page(textWidth(str) + 1);
          text(message, str, 0, 2);
          crawl = 0;
        }
        if (crawl >= 0) {
          crawl += CRAWL_SPEED * dt;
          if (crawl >= COLS + 80 + message.cols) {
            crawl = -1;
            nextCrawl = t + CRAWL_EVERY;
          }
        }
        this.busy = crawl >= 0;
        show(crawl < 0 ? 0 : Math.floor(crawl));
        renderer.render(scene, camera);
      },
    };
  },
};
