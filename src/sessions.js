import * as THREE from 'three';
import { CLAWD, animate } from './clawd.js';
import { figure, eyeMaterial, lights } from './voxel.js';
import { pixelCamera } from './draw.js';

// Your Claude Code sessions as a crew of Clawds to the right of the usage, one each, in the
// order the sessions began. Each acts out its session and is coloured by it: red, walking, while
// it works; amber, hopping and waving, while it waits on you; green for a while once it has
// finished (cheering, or shaking its head if it failed); blue, dimmed and dozing, after that. Touch one to read its title; it stands on a lit line while you do.
const INK = '#ece8e0';
const U = 3; // one mascot unit, in pixels
const SLOT = 72; // each Clawd's share of the row
export const MOST = 5; // Clawds the bar has room for
const PAD = 22;
const FEET = 15; // where they stand, from the bottom
export const rowWidth = (n) => (n ? PAD * 2 + Math.min(n, MOST) * SLOT - 12 : 0);
export const slotAt = (x) => Math.floor((x - PAD + 6) / SLOT);

const COLOUR = { working: '#e0443e', asking: '#f5a623', done: '#4fb477', failed: '#4fb477', idle: '#4a86d8' };
// How bright each is: the one waiting on you outshines the rest.
const LIGHT = { asking: 1.1, working: 1, done: 1, failed: 1, idle: 0.55 };

// Made-up sessions for the gallery, one in each state.
export const SAMPLE_SESSIONS = [
  { id: 'local_a', title: 'Touch Bar ideas', state: 'working' },
  { id: 'local_b', title: 'Inbox triage', state: 'asking' },
  { id: 'local_c', title: 'Display calibration', state: 'done' },
  { id: 'local_d', title: 'Editor fixes', state: 'idle' },
  { id: 'local_e', title: 'Release notes', state: 'failed' },
];

export function createRow(canvas, { width, height }) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(1);
  renderer.setSize(width, height, false);
  renderer.setClearColor(0x000000, 1);
  const scene = new THREE.Scene();
  const camera = pixelCamera(width, height);
  lights(scene);

  const paint = document.createElement('canvas');
  paint.width = width;
  paint.height = height;
  const ctx = paint.getContext('2d');
  const flat = new THREE.CanvasTexture(paint);
  flat.colorSpace = THREE.SRGBColorSpace;
  flat.minFilter = flat.magFilter = THREE.NearestFilter;
  flat.generateMipmaps = false;
  const backdrop = new THREE.Mesh(new THREE.PlaneGeometry(width, height), new THREE.MeshBasicMaterial({ map: flat, toneMapped: false }));
  backdrop.position.set(width / 2, height / 2, -50);
  scene.add(backdrop);

  // A Clawd for each the bar has room for, each with its own body material so it can be coloured for its state.
  const eye = eyeMaterial();
  const target = new THREE.Color();
  const crew = Array.from({ length: MOST }, () => {
    const body = new THREE.MeshStandardMaterial({ color: CLAWD, roughness: 0.6, metalness: 0, emissive: CLAWD, emissiveIntensity: 0.12 });
    const f = figure(body, eye);
    const rig = new THREE.Group();
    rig.add(f.group);
    rig.scale.setScalar(U);
    rig.visible = false;
    scene.add(rig);
    return { f, rig, body, fresh: true };
  });

  let touched = -1;

  return {
    busy: false,
    // The Clawd under a finger, on a lit line while a title is shown for it.
    touch(i) { touched = i; },
    render(sessions, dt, t) {
      const shown = sessions.slice(0, MOST);
      ctx.clearRect(0, 0, width, height);
      this.busy = shown.length > 0;
      crew.forEach((c) => { c.rig.visible = false; });

      shown.forEach((s, i) => {
        const c = crew[i];
        const cx = PAD + i * SLOT + 25;
        const seed = i * 0.61;
        // Each Clawd eases into its state's colour.
        target.set(COLOUR[s.state] ?? CLAWD).multiplyScalar(LIGHT[s.state] ?? 1);
        if (c.fresh) c.body.color.copy(target);
        else c.body.color.lerp(target, 1 - Math.exp(-6 * dt));
        c.fresh = false;
        c.body.emissive.copy(c.body.color);

        let grid = animate(t + seed);
        let walking = false;
        let phase = 0;
        let hop = 0;
        let squash = 1;
        let wave = 0;
        let cheer = 0;
        let yaw = 0;
        if (s.state === 'working') {
          walking = true;
          phase = t * 8 + seed * 4;
          yaw = 0.45;
        } else if (s.state === 'asking') {
          const p = ((t + seed) % 1.4) / 1.4;
          hop = p < 0.32 ? Math.sin((p / 0.32) * Math.PI) * 8 : 0;
          squash = p >= 0.32 && p < 0.44 ? 0.88 + ((p - 0.32) / 0.12) * 0.12 : 1;
          wave = 1;
          yaw = Math.sin(t * 1.7 + seed) * 0.22;
        } else if (s.state === 'done') {
          const p = ((t + seed) % 3) / 3;
          if (p < 0.16) {
            hop = Math.sin((p / 0.16) * Math.PI) * 6;
            cheer = 1;
          }
        } else if (s.state === 'failed') {
          const p = ((t + seed) % 2) / 2;
          yaw = p < 0.3 ? Math.sin((p / 0.3) * Math.PI * 4) * 0.4 : 0;
        } else {
          grid = animate(t, { asleep: true });
          squash = 0.95 + Math.sin(t * 1.4 + seed) * 0.012;
        }
        c.f.pose({ grid, phase, walking, squash, wave, swing: Math.sin(t * 11 + seed), cheer });
        c.f.group.rotation.set(0.3, yaw, 0);
        c.rig.position.set(cx, FEET + 1 + hop, 0);
        c.rig.visible = true;

        // Under a finger, it stands on a lit line.
        if (touched === i) {
          ctx.fillStyle = INK;
          ctx.fillRect(cx - 22, height - FEET + 2, 44, 2);
        }
      });

      flat.needsUpdate = true;
      renderer.render(scene, camera);
    },
  };
}
