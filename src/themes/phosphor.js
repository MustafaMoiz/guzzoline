import * as THREE from 'three';
import { animate } from '../clawd.js';
import { draw as drawText, width as textWidth } from '../pixelfont.js';
import { approach } from '../draw.js';
import { clock, pct, weekday } from '../format.js';
import { DAY } from '../state.js';

// Everything is drawn as brightness into a 2D canvas, then lit as phosphor behind a control
// grid, with a glow. Unlit segments still show faintly, as they do on a real display.
const GHOST = 0.016;
const LABEL = 0.62;

const SEGMENTS = { x: 138, y: 18, w: 13, gap: 4, h: 24, skew: 4 };
const WEEK = { y: 21, groups: 7, per: 4, w: 9, gap: 3, groupGap: 9, h: 18, skew: 3 };
const WEEK_LEN = WEEK.groups * WEEK.per * (WEEK.w + WEEK.gap) + (WEEK.groups - 1) * (WEEK.groupGap - WEEK.gap) - WEEK.gap;

// Laid out from the bar's right edge, x being where each part ends: the second limit's day,
// number and segments, its label, the reset's clock, the first number; the first limit's
// segments fill what's left.
function layout(width) {
  const right = width - 24;
  const weekDigits = right - 72;
  const weekStart = weekDigits - 81 - 24 - WEEK_LEN;
  const weekLabel = weekStart - 38;
  const minutes = weekLabel - 52;
  const digits = minutes - 110;
  const n = Math.floor((digits - 100 - SEGMENTS.x + SEGMENTS.gap) / (SEGMENTS.w + SEGMENTS.gap));
  return { right, weekDigits, weekStart, weekLabel, minutes, digits, n };
}

const DIGITS = {
  0: 'abcdef', 1: 'bc', 2: 'abged', 3: 'abgcd', 4: 'fgbc', 5: 'afgcd', 6: 'afgecd', 7: 'abc', 8: 'abcdefg', 9: 'abcdfg',
};

function hexagon(ctx, pts) {
  ctx.beginPath();
  pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
  ctx.closePath();
  ctx.fill();
}

function segment(ctx, horizontal, a, b, c, t) {
  const h = t / 2;
  if (horizontal) hexagon(ctx, [[a, c], [a + h, c - h], [b - h, c - h], [b, c], [b - h, c + h], [a + h, c + h]]);
  else hexagon(ctx, [[c, a], [c + h, a + h], [c + h, b - h], [c, b], [c - h, b - h], [c - h, a + h]]);
}

// A slanted seven-segment digit in a w×h box at (x, y), every segment ghosted, the digit's lit.
function digit(ctx, ch, x, y, w, h, t, level = 1) {
  const k = 0.1;
  const g = 1.2;
  ctx.setTransform(1, 0, -k, 1, x + k * h, y);
  const lit = DIGITS[ch] ?? '';
  const segs = {
    a: [true, t / 2 + g, w - t / 2 - g, t / 2],
    g: [true, t / 2 + g, w - t / 2 - g, h / 2],
    d: [true, t / 2 + g, w - t / 2 - g, h - t / 2],
    f: [false, t / 2 + g, h / 2 - g, t / 2],
    b: [false, t / 2 + g, h / 2 - g, w - t / 2],
    e: [false, h / 2 + g, h - t / 2 - g, t / 2],
    c: [false, h / 2 + g, h - t / 2 - g, w - t / 2],
  };
  for (const [name, [horizontal, a, b, c]] of Object.entries(segs)) {
    const v = lit.includes(name) ? level : GHOST;
    ctx.fillStyle = `rgb(${v * 255},0,0)`;
    segment(ctx, horizontal, a, b, c, t);
  }
  ctx.setTransform(1, 0, 0, 1, 0, 0);
}

// A right-aligned run of digits; blanks stay as ghost eights.
function number(ctx, text, right, y, w, h, t, pitch, count, level) {
  const chars = text.padStart(count, ' ').slice(-count);
  [...chars].forEach((ch, i) => digit(ctx, ch, right - (count - i) * pitch, y, w, h, t, level));
}

function colon(ctx, x, y, h, level) {
  ctx.fillStyle = `rgb(${level * 255},0,0)`;
  ctx.fillRect(x, y + h * 0.28, 3, 3);
  ctx.fillRect(x - 1, y + h * 0.66, 3, 3);
}

function label(ctx, text, x, y, level = LABEL, scale = 2) {
  ctx.fillStyle = `rgb(${level * 255},0,0)`;
  drawText(text, 0, 0, (dx, dy) => ctx.fillRect(x + dx * scale, y + dy * scale, scale * 0.8, scale * 0.8));
}

function bar(ctx, x, y, w, h, skew, level) {
  ctx.fillStyle = `rgb(${level * 255},0,0)`;
  hexagon(ctx, [[x + skew, y], [x + w + skew, y], [x + w, y + h], [x, y + h]]);
}

const vertexShader = 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0., 1.); }';
// A tight glow, sampled around each pixel: a bloom pass would smear a 60-pixel-tall strip.
const fragmentShader = /* glsl */ `
  uniform sampler2D map;
  uniform vec3 phosphor;
  uniform vec2 size;
  varying vec2 vUv;
  void main() {
    vec2 px = 1.0 / size;
    float i = texture2D(map, vUv).r;
    float glow = 0.0;
    float total = 0.0;
    for (int dx = -6; dx <= 6; dx++) {
      for (int dy = -3; dy <= 3; dy++) {
        float w = exp(-float(dx * dx) / 12.0 - float(dy * dy) / 4.0);
        glow += texture2D(map, vUv + vec2(float(dx), float(dy)) * px).r * w;
        total += w;
      }
    }
    glow /= total;
    vec2 p = vUv * size;
    float mesh = max(step(2.3, mod(p.x + p.y, 3.0)), step(2.3, mod(p.x - p.y + 3000.0, 3.0)));
    vec3 c = phosphor * (i * (1.0 - 0.3 * mesh) * 0.95 + glow * 0.35);
    c += vec3(1.0, 0.8, 0.66) * smoothstep(0.9, 1.0, i) * 0.06;
    gl_FragColor = vec4(c, 1.0);
    #include <colorspace_fragment>
  }
`;

export default {
  id: 'phosphor',
  name: 'Phosphor',
  note: 'A vacuum fluorescent display. The lit segments are what’s left, so it dims as you spend.',

  create(canvas, { width, height }) {
    const renderer = new THREE.WebGLRenderer({ canvas });
    renderer.setPixelRatio(1);
    renderer.setSize(width, height, false);

    const paint = document.createElement('canvas');
    paint.width = width;
    paint.height = height;
    const ctx = paint.getContext('2d');
    const map = new THREE.CanvasTexture(paint);
    map.colorSpace = THREE.NoColorSpace;
    map.generateMipmaps = false;
    map.minFilter = map.magFilter = THREE.NearestFilter;

    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.ShaderMaterial({
      uniforms: {
        map: { value: map },
        phosphor: { value: new THREE.Color('#ff8a5c') },
        size: { value: new THREE.Vector2(width, height) },
      },
      vertexShader,
      fragmentShader,
    })));

    const L = layout(width);
    const lit5 = new Float32Array(L.n);
    const litW = new Float32Array(WEEK.groups * WEEK.per);

    // Lit segments ease toward their state: on quickly, off with a little afterglow.
    function ladder(levels, target, boundaryPulse, dt) {
      const n = levels.length;
      const on = Math.round(target * n);
      for (let i = 0; i < n; i++) {
        let goal = i < on ? 1 : GHOST;
        if (boundaryPulse && i === on - 1) goal = 0.55 + 0.45 * boundaryPulse;
        levels[i] = approach(levels[i], goal, goal > levels[i] ? 40 : 7, dt);
      }
    }

    return {
      render(v, dt, t) {
        const s = v.primary;
        const w = v.secondary;
        const showUsed = v.show === 'used';
        const pulse = v.working && s.status !== 'out' ? 0.5 + 0.5 * Math.sin(t * 9) : 0;
        ladder(lit5, showUsed ? s.used : s.left, pulse, dt);
        if (w) ladder(litW, showUsed ? w.used : w.left, 0, dt);

        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, width, height);

        // The mascot, in phosphor dots.
        ctx.fillStyle = 'rgb(255,0,0)';
        const asleep = s.status === 'out' || w?.status === 'out';
        const grid = animate(t, { working: v.working && !asleep, asleep });
        for (let r = 0; r < grid.length; r++) {
          for (let c = 0; c < grid[r].length; c++) if (grid[r][c]) ctx.fillRect(24 + c * 3, 15 + r * 3, 2.4, 2.4);
        }

        // The first limit: the session, or the week on a plan without one.
        label(ctx, s.short, 100, 23);
        lit5.forEach((level, i) => {
          bar(ctx, SEGMENTS.x + i * (SEGMENTS.w + SEGMENTS.gap), SEGMENTS.y, SEGMENTS.w, SEGMENTS.h, SEGMENTS.skew, level);
        });
        const segPitch = SEGMENTS.w + SEGMENTS.gap;
        if (s.active) {
          const pace = showUsed ? s.elapsed : 1 - s.elapsed;
          const px = SEGMENTS.x + pace * L.n * segPitch - SEGMENTS.gap / 2;
          ctx.fillStyle = `rgb(${0.7 * 255},0,0)`;
          hexagon(ctx, [[px - 4, 51], [px + 4, 51], [px, 46]]);
        }
        const shown = showUsed ? s.used : s.left;
        const blink = Math.floor(t * 1.6) % 2 === 0;
        number(ctx, pct(shown), L.digits, 12, 20, 36, 4, 27, 3, 1);
        label(ctx, '%', L.digits + 6, 34);
        // When it resets: a clock time (a weekday when that's days off), blinking like a VCR's
        // once the limit has run out.
        const resetLevel = s.status === 'out' && !blink ? GHOST : 1;
        const level = s.active ? resetLevel : GHOST;
        if (s.active && s.kind === 'week' && s.resetIn >= DAY) {
          label(ctx, weekday(s.resetsAt).toUpperCase(), L.minutes - 70, 23, level);
        } else {
          const { time, period } = s.active ? clock(s.resetsAt) : { time: ':', period: '' };
          const [hh, mm] = time.split(':');
          number(ctx, hh, L.minutes - 44, 23, 13, 26, 3, 17, 2, level);
          colon(ctx, L.minutes - 40, 23, 26, level);
          number(ctx, mm, L.minutes, 23, 13, 26, 3, 17, 2, level);
          if (period) label(ctx, period.toUpperCase(), L.minutes + 6, 22, level * 0.8, 1.4);
        }

        if (!w) {
          map.needsUpdate = true;
          renderer.render(scene, camera);
          return;
        }

        // The second limit, in seven groups of four.
        label(ctx, w.short, L.weekLabel, 23);
        litW.forEach((level, i) => {
          const g = Math.floor(i / WEEK.per);
          const x = L.weekStart + i * (WEEK.w + WEEK.gap) + g * (WEEK.groupGap - WEEK.gap);
          bar(ctx, x, WEEK.y, WEEK.w, WEEK.h, WEEK.skew, level);
        });
        if (w.active) {
          const pace = showUsed ? w.elapsed : 1 - w.elapsed;
          const px = L.weekStart + pace * WEEK_LEN;
          ctx.fillStyle = `rgb(${0.7 * 255},0,0)`;
          hexagon(ctx, [[px - 4, 50], [px + 4, 50], [px, 45]]);
        }
        number(ctx, pct(showUsed ? w.used : w.left), L.weekDigits, 12, 20, 36, 4, 27, 3, 1);
        label(ctx, '%', L.weekDigits + 6, 34);
        const weekLevel = w.status === 'out' && !blink ? GHOST : 0.85;
        const day = w.resetIn != null && w.resetIn < DAY ? clock(w.resetsAt).time : weekday(w.resetsAt ?? v.now);
        label(ctx, day.toUpperCase(), L.right - textWidth(day.toUpperCase()) * 2, 23, weekLevel);

        map.needsUpdate = true;
        renderer.render(scene, camera);
      },
    };
  },
};
