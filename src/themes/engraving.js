import * as THREE from 'three';
import { CLAWD, animate, draw as drawClawd } from '../clawd.js';
import { pct, until, clock, weekday } from '../format.js';
import { DAY } from '../state.js';

// Two scales stacked like a slide rule's. What's left of each window is a block cut in white
// lines, as in a wood engraving; what's spent is cut away. The hand points at an even pace.
const INK = '#ece8e0';
const MUTED = '#8e8a82';
const X0 = 158;
const X1 = 1650;
const UPPER = { top: 3, bottom: 16, base: 17 }; // y from the top, in pixels
const LOWER = { top: 43, bottom: 56, base: 42 };

const vertexShader = 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0., 1.); }';
const fragmentShader = /* glsl */ `
  uniform sampler2D overlay;
  uniform vec2 size;
  uniform vec4 blockA; // x from, x to, y from, y to, in pixels from the bottom left
  uniform vec4 blockB;
  varying vec2 vUv;

  float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
  }

  float hatch(vec2 p, vec4 b, float dir) {
    float edge = b.x + (noise(vec2(p.y * 0.8, b.x * 0.1)) - 0.5) * 1.6;
    float inside = smoothstep(edge - 0.5, edge + 0.5, p.x) * step(p.x, b.y) * step(b.z, p.y) * step(p.y, b.w);
    float period = 4.0;
    float t = (p.x + dir * p.y) / period;
    float d = abs(fract(t) - 0.5) * period;
    float half_ = 0.5 + 0.38 * noise(vec2(p.x * 0.035 + floor(t) * 3.1, floor(t) * 0.7));
    float line = 1.0 - smoothstep(half_ - 0.55, half_ + 0.55, d);
    line *= smoothstep(0.1, 0.22, noise(p * vec2(0.3, 0.8) + floor(t) * 7.0));
    return line * inside;
  }

  void main() {
    vec2 p = vUv * size;
    float h = max(hatch(p, blockA, 1.0), hatch(p, blockB, -1.0));
    vec4 o = texture2D(overlay, vUv);
    vec3 c = vec3(0.86, 0.83, 0.78) * h;
    c = mix(c, o.rgb, o.a);
    gl_FragColor = vec4(c, 1.0);
    #include <colorspace_fragment>
  }
`;

const timeText = (ts) => {
  const { time, period } = clock(ts);
  return `${time.replace(':', '·')}${period ? ` ${period}` : ''}`;
};

function resetPhrase(win) {
  if (!win.active) return '';
  if (win.status === 'out') return `in ${until(win.resetIn)}`;
  if (win.kind === 'session' || win.resetIn < DAY) return `till ${timeText(win.resetsAt)}`;
  return `till ${weekday(win.resetsAt)}`;
}

export default {
  id: 'engraving',
  name: 'Engraving',
  note: 'Two scales, like a slide rule. What’s left is cut in white lines; the hand points at an even pace.',

  create(canvas, { width, height }) {
    const renderer = new THREE.WebGLRenderer({ canvas });
    renderer.setPixelRatio(1);
    renderer.setSize(width, height, false);

    const paint = document.createElement('canvas');
    paint.width = width;
    paint.height = height;
    const ctx = paint.getContext('2d');
    const overlay = new THREE.CanvasTexture(paint);
    overlay.colorSpace = THREE.SRGBColorSpace;
    overlay.generateMipmaps = false;
    overlay.minFilter = overlay.magFilter = THREE.NearestFilter;

    const uniforms = {
      overlay: { value: overlay },
      size: { value: new THREE.Vector2(width, height) },
      blockA: { value: new THREE.Vector4() },
      blockB: { value: new THREE.Vector4() },
    };
    const scene = new THREE.Scene();
    const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.ShaderMaterial({ uniforms, vertexShader, fragmentShader })));

    const chips = [];

    // Ticks along a baseline: `marks` is a list of [fraction, length].
    function scale(base, dir, marks) {
      ctx.fillStyle = INK;
      ctx.globalAlpha = 0.85;
      ctx.fillRect(X0, base, X1 - X0, 1);
      for (const [f, len] of marks) {
        const x = Math.round(X0 + f * (X1 - X0));
        ctx.fillRect(x, dir > 0 ? base + 1 : base - len, 1, len);
      }
      ctx.globalAlpha = 1;
    }

    // An even-pace pointer in the channel between the scales: a stem and a head at the ticks.
    function pointer(x, up) {
      const cx = Math.round(x) + 0.5;
      ctx.fillStyle = INK;
      if (up) {
        ctx.fillRect(cx - 0.5, 27, 1, 6);
        ctx.beginPath();
        ctx.moveTo(cx, 23.5);
        ctx.lineTo(cx + 3, 28.5);
        ctx.lineTo(cx - 3, 28.5);
        ctx.fill();
      } else {
        ctx.fillRect(cx - 0.5, 27, 1, 6);
        ctx.beginPath();
        ctx.moveTo(cx, 36.5);
        ctx.lineTo(cx + 3, 31.5);
        ctx.lineTo(cx - 3, 31.5);
        ctx.fill();
      }
    }

    function figures(win, show, baseline) {
      const value = pct(show === 'used' ? win.used : win.left);
      const hot = win.status === 'low' || win.status === 'out';
      ctx.font = '400 27px "IM Fell English"';
      ctx.fillStyle = hot ? CLAWD : INK;
      ctx.textAlign = 'right';
      ctx.fillText(value, 1728, baseline);
      ctx.textAlign = 'left';
      ctx.font = '400 17px "IM Fell English"';
      ctx.fillStyle = MUTED;
      ctx.fillText('%', 1731, baseline);
      ctx.font = 'italic 400 19px "IM Fell English"';
      ctx.fillText(resetPhrase(win), 1758, baseline);
    }

    return {
      render(v, dt, t) {
        const s = v.primary;
        const w = v.secondary;
        const len = X1 - X0;
        const bS = X0 + s.used * len;
        const bW = w ? X0 + w.used * len : X1;
        uniforms.blockA.value.set(bS, X1, height - UPPER.bottom - 1, height - UPPER.top);
        uniforms.blockB.value.set(bW, X1, height - LOWER.bottom - 1, height - LOWER.top);

        ctx.clearRect(0, 0, width, height);

        // The maker's mark: the one thing in colour.
        const asleep = s.status === 'out' || w?.status === 'out';
        drawClawd(ctx, animate(t, { asleep }), 22, 15, 3);

        ctx.font = '400 15px "IM Fell English SC"';
        ctx.fillStyle = MUTED;
        ctx.textAlign = 'left';
        ctx.fillText(s.name, 84, 14);
        if (w) ctx.fillText(w.name, 84, 55);

        // Hours and ten minutes on a session; days and quarter days on a week.
        const marks = (win) => {
          const out = [];
          if (win.kind === 'session') {
            for (let m = 0; m <= 300; m += 10) out.push([m / 300, m % 60 === 0 ? 6 : m % 30 === 0 ? 4 : 2]);
          } else {
            for (let q = 0; q <= 28; q++) out.push([q / 28, q % 4 === 0 ? 6 : 2]);
          }
          return out;
        };
        scale(UPPER.base, 1, marks(s));
        if (w) scale(LOWER.base, -1, marks(w));

        if (s.active) pointer(X0 + s.elapsed * len, true);
        if (w?.active) pointer(X0 + w.elapsed * len, false);

        // Chips fly off the edge of the session's block while Claude is working.
        if (v.working && !asleep && Math.random() < dt * 9) {
          chips.push({ x: bS, y: UPPER.top + 2 + Math.random() * 10, vx: -20 - Math.random() * 30, vy: -25 - Math.random() * 25, life: 0 });
        }
        ctx.fillStyle = INK;
        for (let i = chips.length - 1; i >= 0; i--) {
          const c = chips[i];
          c.life += dt;
          c.x += c.vx * dt;
          c.y += c.vy * dt;
          c.vy += 140 * dt;
          if (c.life > 0.5) { chips.splice(i, 1); continue; }
          ctx.globalAlpha = 1 - c.life / 0.5;
          ctx.fillRect(Math.round(c.x), Math.round(c.y), 1.5, 1.5);
        }
        ctx.globalAlpha = 1;

        figures(s, v.show, 24);
        if (w) figures(w, v.show, 54);

        overlay.needsUpdate = true;
        renderer.render(scene, camera);
      },
    };
  },
};
