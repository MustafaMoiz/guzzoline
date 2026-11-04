import * as THREE from 'three';
import { CLAWD, animate, draw as drawClawd } from '../clawd.js';
import { pct, resetText } from '../format.js';

// An incense clock: sticks laid on an ash bed, burning toward the mascot. Ash is what's spent,
// the ember is now, smoke rises off it. Marks under the bed are hours, and days for the week.
const BED = 44; // y of the ash bed, from the top
// Laid out from the bar's width: the second limit's stick and figures at the right edge, the
// first limit's figures and Clawd before them, and the first stick takes the rest.
function layout(width) {
  const weekX1 = width - 156;
  const weekX0 = weekX1 - Math.round(width * 0.17);
  const text = weekX0 - 208;
  const x1 = text - 68;
  return { text, clawd: x1 + 16, right: width - 18, sticks: [{ x0: 46, x1, thick: 3 }, { x0: weekX0, x1: weekX1, thick: 2 }] };
}
const INK = '#ece8e0';
const MUTED = '#8b877f';

const hash = (n) => {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

// Ash breaks into pieces of fixed lengths, so it doesn't shimmer as the ember moves.
function ashBreaks(length, seed) {
  const breaks = [0];
  for (let i = 0; breaks.at(-1) < length; i++) breaks.push(breaks.at(-1) + 9 + hash(seed + i) * 19);
  return breaks;
}

const pointsVertex = /* glsl */ `
  attribute float size;
  attribute float alpha;
  varying float vAlpha;
  void main() {
    vAlpha = alpha;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    gl_PointSize = size;
  }
`;
const pointsFragment = /* glsl */ `
  uniform vec3 color;
  uniform float sharp;
  varying float vAlpha;
  void main() {
    float r = length(gl_PointCoord - 0.5) * 2.0;
    float a = exp(-r * r * sharp) * (1.0 - smoothstep(0.7, 1.0, r)) * vAlpha;
    gl_FragColor = vec4(color, a);
    #include <colorspace_fragment>
  }
`;

function particles(max, color, sharp, blending) {
  const geometry = new THREE.BufferGeometry();
  const position = new Float32Array(max * 3);
  const size = new Float32Array(max);
  const alpha = new Float32Array(max);
  geometry.setAttribute('position', new THREE.BufferAttribute(position, 3));
  geometry.setAttribute('size', new THREE.BufferAttribute(size, 1));
  geometry.setAttribute('alpha', new THREE.BufferAttribute(alpha, 1));
  const points = new THREE.Points(geometry, new THREE.ShaderMaterial({
    uniforms: { color: { value: new THREE.Color(color) }, sharp: { value: sharp } },
    vertexShader: pointsVertex,
    fragmentShader: pointsFragment,
    transparent: true,
    depthWrite: false,
    blending,
  }));
  points.frustumCulled = false;
  const live = [];
  return {
    points,
    live,
    flush() {
      live.forEach((p, i) => {
        position.set([p.x, p.y, 0], i * 3);
        size[i] = p.size;
        alpha[i] = p.alpha;
      });
      geometry.setDrawRange(0, live.length);
      for (const name of ['position', 'size', 'alpha']) geometry.attributes[name].needsUpdate = true;
    },
  };
}

export default {
  id: 'incense',
  name: 'Incense',
  note: 'An incense clock. The ash is what’s spent; it burns toward Clawd. Smoke when Claude works.',

  create(canvas, { width, height }) {
    const renderer = new THREE.WebGLRenderer({ canvas });
    renderer.setPixelRatio(1);
    renderer.setSize(width, height, false);
    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(0, width, height, 0, -10, 10);

    const paint = document.createElement('canvas');
    paint.width = width;
    paint.height = height;
    const ctx = paint.getContext('2d');
    const flat = new THREE.CanvasTexture(paint);
    flat.colorSpace = THREE.SRGBColorSpace;
    flat.generateMipmaps = false;
    flat.minFilter = flat.magFilter = THREE.NearestFilter;
    const backdrop = new THREE.Mesh(new THREE.PlaneGeometry(width, height), new THREE.MeshBasicMaterial({ map: flat, toneMapped: false }));
    backdrop.position.set(width / 2, height / 2, 0);
    scene.add(backdrop);

    const smoke = particles(700, '#e8e4dd', 6, THREE.NormalBlending);
    const sparks = particles(120, '#ffb27a', 9, THREE.AdditiveBlending);
    const embers = particles(2, '#ff7a3c', 3.2, THREE.AdditiveBlending);
    scene.add(smoke.points, embers.points, sparks.points);

    const L = layout(width);
    const state = L.sticks.map((s, i) => ({ ...s, breaks: ashBreaks(s.x1 - s.x0, i * 97), tip: s.x0, emit: 0 }));

    function drawStick(st, burnt, lit, t) {
      const y = BED - st.thick;
      const tip = Math.round(st.tip);
      // The ash bed and its marks.
      ctx.fillStyle = '#2c2a27';
      ctx.fillRect(st.x0 - 14, BED, st.x1 - st.x0 + 28, 1);
      ctx.fillStyle = '#55524d';
      const marks = st.kind === 'session' ? 5 : 7;
      for (let m = 0; m <= marks; m++) ctx.fillRect(Math.round(st.x0 + (m / marks) * (st.x1 - st.x0)), BED + 2, 1, 3);
      // Ash: broken pieces, a little sunk, flecked.
      for (let i = 0; i < st.breaks.length - 1; i++) {
        const a = st.x0 + st.breaks[i];
        const b = Math.min(st.x0 + st.breaks[i + 1] - 1, tip - 1);
        if (a >= tip) break;
        const sink = hash(i * 7 + st.x0) > 0.6 ? 1 : 0;
        ctx.fillStyle = hash(i * 3 + 1) > 0.5 ? '#6f6a63' : '#7b766e';
        ctx.fillRect(a, y + sink, Math.max(0, b - a), st.thick);
        ctx.fillStyle = '#9b958c';
        for (let k = 0; k < (b - a) / 6; k++) ctx.fillRect(a + Math.floor(hash(i * 13 + k) * (b - a)), y + sink, 1, 1);
      }
      // What's left: a pale stick, charred just behind the ember.
      if (tip < st.x1) {
        ctx.fillStyle = '#d6ccbb';
        ctx.fillRect(tip, y, st.x1 - tip, st.thick);
        ctx.fillStyle = '#efe7d9';
        ctx.fillRect(tip, y, st.x1 - tip, 1);
        if (lit) {
          const grad = ctx.createLinearGradient(tip, 0, tip + 9, 0);
          grad.addColorStop(0, '#2a120a');
          grad.addColorStop(1, 'rgba(42,18,10,0)');
          ctx.fillStyle = grad;
          ctx.fillRect(tip, y, 9, st.thick);
          ctx.fillStyle = `rgba(255,${140 + 60 * Math.sin(t * 3)},90,1)`;
          ctx.fillRect(tip - 1, y, 2, st.thick);
        }
      }
      return { x: tip, y: height - y - st.thick / 2 };
    }

    function step(list, dt, update) {
      for (let i = list.length - 1; i >= 0; i--) {
        const p = list[i];
        p.age += dt;
        if (p.age >= p.life) { list.splice(i, 1); continue; }
        update(p);
      }
    }

    return {
      busy: false,
      render(v, dt, t) {
        const asleep = [v.primary, v.secondary].some((w) => w?.status === 'out');
        ctx.clearRect(0, 0, width, height);
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, width, height);
        embers.live.length = 0;
        this.busy = false;

        state.forEach((st, i) => {
          const win = i ? v.secondary : v.primary;
          if (!win) return;
          st.kind = win.kind;
          const target = st.x0 + win.used * (st.x1 - st.x0);
          st.tip += (target - st.tip) * (1 - Math.exp(-6 * dt));
          const lit = win.active && win.status !== 'out' && !asleep;
          if (lit) this.busy = true;
          const tip = drawStick(st, win.used, lit, t);

          // The now mark: where the ember would be at an even pace.
          if (win.active) {
            const px = Math.round(st.x0 + win.elapsed * (st.x1 - st.x0));
            ctx.fillStyle = INK;
            ctx.beginPath();
            ctx.moveTo(px + 0.5, BED + 6);
            ctx.lineTo(px + 3.5, BED + 11);
            ctx.lineTo(px - 2.5, BED + 11);
            ctx.fill();
          }

          if (lit) {
            const working = v.working;
            const glow = 0.75 + 0.25 * Math.sin(t * 2.2 + i) + (working ? 0.35 : 0);
            embers.live.push({ x: tip.x, y: tip.y, size: (st.thick + 1) * 7 * glow, alpha: 0.95 });
            st.emit += dt * (working ? 70 : 26) * (i ? 0.6 : 1);
            while (st.emit >= 1) {
              st.emit -= 1;
              smoke.live.push({
                x: tip.x + (Math.random() - 0.5), y: tip.y + 1, age: 0, life: 2.8 + Math.random() * 1.6,
                seed: Math.random() * 100, size: 2, alpha: 0, vy: 9 + Math.random() * 5, rise: 0, turb: working ? 1.6 : 1,
              });
            }
            if (working && Math.random() < dt * 5) {
              for (let k = 0; k < 3; k++) {
                sparks.live.push({
                  x: tip.x, y: tip.y, age: 0, life: 0.3 + Math.random() * 0.4, size: 2.5, alpha: 1,
                  vx: (Math.random() - 0.5) * 40, vy: 20 + Math.random() * 30,
                });
              }
            }
          }
        });

        step(smoke.live, dt, (p) => {
          const h = p.rise;
          const curl = Math.min(1, h / 16) * p.turb;
          p.y += p.vy * dt;
          p.rise += p.vy * dt;
          p.x += (Math.sin(t * 0.9 + p.seed + h * 0.12) * 5 + Math.sin(t * 2.1 + h * 0.31 + p.seed * 2) * 3) * curl * dt + 1.5 * dt;
          const k = p.age / p.life;
          p.size = 2 + h * 0.22;
          p.alpha = Math.min(1, p.age * 4) * (1 - k) * 0.16;
        });
        step(sparks.live, dt, (p) => {
          p.x += p.vx * dt;
          p.y += p.vy * dt;
          p.vy -= 90 * dt;
          p.alpha = 1 - p.age / p.life;
        });
        smoke.flush();
        sparks.flush();
        embers.flush();

        // Clawd sits at the end of the session's stick, eyes closed unless Claude is working.
        const grid = animate(t, { asleep: asleep || !v.working });
        drawClawd(ctx, grid, L.clawd, BED - 20, 2, CLAWD);

        // Figures.
        const s = v.primary;
        const w = v.secondary;
        ctx.textBaseline = 'alphabetic';
        // A number, a per cent sign and the reset, from x, or ending at `right`.
        const figures = (win, x, right) => {
          const parts = [
            [pct(v.show === 'used' ? win.used : win.left), '300 26px "IBM Plex Mono"', win.status === 'low' || win.status === 'out' ? CLAWD : INK, 2],
            ['%', '300 17px "IBM Plex Mono"', MUTED, 12],
            [resetText(win), '300 19px "IBM Plex Mono"', MUTED, 0],
          ];
          const widths = parts.map(([text, font]) => { ctx.font = font; return ctx.measureText(text).width; });
          let cx = right == null ? x : right - widths.reduce((a, b, i) => a + b + parts[i][3], 0);
          parts.forEach(([text, font, color, gap], i) => {
            ctx.font = font;
            ctx.fillStyle = color;
            ctx.fillText(text, cx, 40);
            cx += widths[i] + gap;
          });
        };
        figures(s, L.text);
        if (w) figures(w, null, L.right);

        flat.needsUpdate = true;
        renderer.render(scene, camera);
      },
    };
  },
};
