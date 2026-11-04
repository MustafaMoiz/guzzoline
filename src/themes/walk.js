import * as THREE from 'three';
import { CLAWD, PARTS, animate } from '../clawd.js';
import { Label } from '../text.js';
import { approach, clamp, pixelCamera, rect } from '../draw.js';
import { pct, resetText } from '../format.js';

const INK = '#f2efe9';
const MUTED = '#8b877f';

const U = 3; // one mascot unit, in pixels
const GROUND = 17;
const PATH = [34, 1222]; // where the session's walk starts and ends
const NUM_X = 1262;
const WEEK = [1496, 1790];
const WEEK_NUM_X = 1822;

// The mascot in voxels: a body block with recessed eyes, and arms and legs that move.
function figure(bodyMaterial, eyeMaterial) {
  const group = new THREE.Group();
  const cube = new THREE.BoxGeometry(1, 1, 1);
  const torso = new THREE.Group();
  const back = new THREE.Mesh(new THREE.BoxGeometry(13, 8, 5), bodyMaterial);
  back.position.set(0, 6, -0.5);
  const front = new THREE.InstancedMesh(cube, bodyMaterial, 13 * 8);
  const eyes = new THREE.InstancedMesh(cube, eyeMaterial, 16);
  torso.add(back, front, eyes);
  const arms = PARTS.arms.map(({ x, y }) => {
    const m = new THREE.Mesh(new THREE.BoxGeometry(2, 2, 2), bodyMaterial);
    m.userData.base = new THREE.Vector3(x + 1 - 8.5, 10 - y - 1, 0);
    torso.add(m);
    return m;
  });
  const legs = PARTS.legs.map(({ x }) => {
    const m = new THREE.Mesh(new THREE.BoxGeometry(1, 2, 2), bodyMaterial);
    m.userData.base = new THREE.Vector3(x + 0.5 - 8.5, 1, 0.5);
    group.add(m);
    return m;
  });
  group.add(torso);

  const m4 = new THREE.Matrix4();
  let shown = null;
  // The face comes from the 2D pose: body cells are the front layer, gaps in it are eyes.
  function face(grid) {
    if (grid === shown) return;
    shown = grid;
    let n = 0;
    let e = 0;
    for (let r = 0; r < 8; r++) {
      for (let c = 2; c <= 14; c++) {
        const x = c + 0.5 - 8.5;
        const y = 9.5 - r;
        if (grid[r][c]) front.setMatrixAt(n++, m4.makeTranslation(x, y, 2.5));
        else eyes.setMatrixAt(e++, m4.makeTranslation(x, y, 1.9));
      }
    }
    front.count = n;
    eyes.count = e;
    front.instanceMatrix.needsUpdate = true;
    eyes.instanceMatrix.needsUpdate = true;
  }

  function pose({ grid, phase, walking, squash }) {
    face(grid);
    const lift = walking ? Math.sin(phase) : 0;
    legs.forEach((leg, i) => {
      const up = i % 2 === 0 ? Math.max(0, lift) : Math.max(0, -lift);
      leg.position.copy(leg.userData.base).add(new THREE.Vector3(0, up * 0.9, 0));
    });
    torso.position.y = walking ? Math.abs(lift) * 0.45 : 0;
    torso.scale.y = squash;
    arms.forEach((arm, i) => {
      arm.position.copy(arm.userData.base);
      arm.position.y += walking ? (i ? -lift : lift) * 0.45 : 0;
    });
  }

  return { group, pose };
}

export default {
  id: 'walk',
  name: 'Walk',
  note: 'Clawd walks the session. Behind it is spent, ahead is what’s left.',

  create(canvas, { width, height }) {
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    renderer.setPixelRatio(1);
    renderer.setSize(width, height, false);
    renderer.setClearColor(0x000000, 1);

    const scene = new THREE.Scene();
    const camera = pixelCamera(width, height);

    scene.add(new THREE.HemisphereLight(0xfff4ec, 0x2a1c16, 1.6));
    const key = new THREE.DirectionalLight(0xffffff, 3.2);
    key.position.set(-0.5, 0.8, 1.6);
    const rim = new THREE.DirectionalLight(0xffe2d2, 1.4);
    rim.position.set(1, 0.4, -0.8);
    scene.add(key, rim);

    const body = new THREE.MeshStandardMaterial({
      color: CLAWD, roughness: 0.6, metalness: 0, emissive: CLAWD, emissiveIntensity: 0.12,
    });
    const eye = new THREE.MeshBasicMaterial({ color: 0x0b0604 });
    const me = figure(body, eye);
    const rig = new THREE.Group();
    rig.add(me.group);
    rig.scale.setScalar(U);
    rig.position.y = GROUND + 1; // the tilt dips the front of the feet; this keeps them on the line

    // The floor is glossy black: a dim, unlit copy hangs below the line, fading out.
    const glossBody = new THREE.MeshBasicMaterial({ color: 0x2e1a13 });
    const mirrored = figure(glossBody, eye);
    const mirrorRig = new THREE.Group();
    mirrorRig.add(mirrored.group);
    mirrorRig.scale.set(U, -U, U);
    mirrorRig.position.y = GROUND - 4;
    scene.add(rig, mirrorRig);

    const fadeWidth = PATH[1] + 60;
    const fade = new THREE.Mesh(
      new THREE.PlaneGeometry(fadeWidth, GROUND),
      new THREE.ShaderMaterial({
        transparent: true,
        depthTest: false,
        uniforms: { top: { value: GROUND } },
        vertexShader: 'varying float vY; void main(){ vY = (modelMatrix * vec4(position,1.)).y; gl_Position = projectionMatrix * viewMatrix * modelMatrix * vec4(position,1.); }',
        fragmentShader: 'uniform float top; varying float vY; void main(){ float a = 1. - smoothstep(0., top, vY) * 0.85; gl_FragColor = vec4(0.,0.,0.,a); }',
      }),
    );
    fade.position.set(fadeWidth / 2, GROUND / 2, 20);
    fade.renderOrder = 5;
    scene.add(fade);

    // The path: spent is a solid line, what's left is dotted, the tick is an even pace.
    const flat = new THREE.Group();
    flat.renderOrder = 10;
    const trail = rect(INK, 0.9);
    const pace = rect(INK, 0.4);
    const post = rect(INK, 0.55);
    const flag = rect(INK, 0.55);
    const dots = new THREE.InstancedMesh(new THREE.PlaneGeometry(2, 2),
      new THREE.MeshBasicMaterial({ color: MUTED, transparent: true, opacity: 0.55, toneMapped: false }), 200);
    flat.add(trail, pace, post, flag, dots);
    trail.position.z = -40; // behind the mascot, so its feet stand on the line

    const weekRest = rect(MUTED, 0.6);
    const weekFill = rect(INK, 0.9);
    const weekNow = rect(INK, 0.45);
    const weekTicks = Array.from({ length: 8 }, () => rect(MUTED, 0.7));
    flat.add(weekRest, weekFill, weekNow, ...weekTicks);
    for (const o of flat.children) o.renderOrder = 10;
    scene.add(flat);

    const sweat = rect(INK, 0.9);
    sweat.renderOrder = 11;
    scene.add(sweat);
    const zs = [0, 1, 2].map(() => {
      const z = new Label({ font: '400 15px "IBM Plex Mono"', color: MUTED }).set('z');
      z.material.opacity = 0;
      scene.add(z.mesh);
      return z;
    });

    const num = new Label({ font: '500 26px "IBM Plex Mono"' });
    const sign = new Label({ font: '400 17px "IBM Plex Mono"', color: MUTED });
    const reset = new Label({ font: '400 19px "IBM Plex Mono"', color: MUTED });
    const weekNum = new Label({ font: '500 26px "IBM Plex Mono"' });
    const weekSign = new Label({ font: '400 17px "IBM Plex Mono"', color: MUTED });
    const weekReset = new Label({ font: '400 19px "IBM Plex Mono"', color: MUTED });
    for (const l of [num, sign, reset, weekNum, weekSign, weekReset]) scene.add(l.mesh);

    const m4 = new THREE.Matrix4();
    let x = PATH[0];
    let facing = 1;
    let yaw = 0;
    let phase = 0;

    return {
      busy: false,
      render(v, dt, t) {
        const s = v.primary;
        const w = v.secondary;
        const len = PATH[1] - PATH[0];
        // The mascot is half a body wide, so it walks to just short of the finish post.
        const target = PATH[0] + s.used * (len - 30);
        const d = target - x;
        const moving = Math.abs(d) > 0.75;
        if (moving) {
          const speed = clamp(Math.abs(d) * 2.5, 45, 900);
          x += Math.sign(d) * Math.min(Math.abs(d), speed * dt);
          facing = Math.sign(d);
        }
        const asleep = !moving && (s.status === 'out' || w?.status === 'out');
        const walking = moving || (v.working && !asleep);
        this.busy = moving || asleep;
        phase += dt * (walking ? (moving ? 13 : 8) : 0);
        if (!walking) phase = 0;
        yaw = approach(yaw, walking ? facing * 0.55 : 0, 8, dt);

        const grid = animate(t, { asleep });
        const squash = asleep ? 0.95 + Math.sin(t * 1.4) * 0.012 : 1;
        for (const f of [me, mirrored]) {
          f.pose({ grid, phase, walking, squash });
          f.group.position.x = x / U;
          f.group.rotation.set(0.3, yaw, 0);
        }
        mirrored.group.rotation.set(-0.3, yaw, 0);

        // Path.
        const xi = Math.round(x);
        trail.place(PATH[0], GROUND - 2, Math.max(0, xi - PATH[0]), 2);
        let n = 0;
        for (let dx = xi + 30; dx < PATH[1] - 2 && n < 200; dx += 8) {
          dots.setMatrixAt(n++, m4.makeTranslation(dx, GROUND - 1, 0));
        }
        dots.count = n;
        dots.instanceMatrix.needsUpdate = true;
        pace.visible = s.active;
        pace.place(Math.round(PATH[0] + s.elapsed * (len - 30)) - 1, GROUND - 9, 2, 6);
        post.place(PATH[1], GROUND - 2, 2, 16);
        flag.place(PATH[1] + 2, GROUND + 9, 6, 5);

        // Sweating when working faster than the window refills.
        const sweating = walking && !moving && s.status === 'fast';
        const sp = (t % 1.1) / 1.1;
        sweat.visible = sweating;
        sweat.material.opacity = 0.9 * (1 - sp);
        sweat.place(xi + (facing > 0 ? 27 : -30), GROUND + 29 - sp * 10, 3, 4);

        zs.forEach((z, i) => {
          const p = ((t * 0.45 + i / 3) % 1);
          z.material.opacity = asleep ? Math.sin(p * Math.PI) * 0.9 : 0;
          z.at(xi + 20 + p * 14 + i * 2, GROUND + 22 + p * 10);
        });

        // Numbers.
        const shown = v.show === 'used' ? s.used : s.left;
        const hot = s.status === 'low' || s.status === 'out';
        num.set(pct(shown), hot ? CLAWD : INK).at(NUM_X, 21);
        sign.set('%').at(NUM_X + num.width + 2, 21);
        reset.set(resetText(s)).at(NUM_X + num.width + sign.width + 14, 21);

        // The second limit: a thinner track, ruled in days.
        const weekParts = [weekRest, weekFill, weekNow, ...weekTicks, weekNum.mesh, weekSign.mesh, weekReset.mesh];
        for (const part of weekParts) part.visible = Boolean(w);
        if (w) {
          const wl = WEEK[1] - WEEK[0];
          const wy = 29;
          const fill = Math.round(w.used * wl);
          weekFill.place(WEEK[0], wy - 1, fill, 2);
          weekRest.place(WEEK[0] + fill, wy - 0.5, wl - fill, 1);
          weekTicks.forEach((tick, i) => tick.place(Math.round(WEEK[0] + (i / 7) * wl), wy - 4, 1, 3));
          weekNow.visible = w.active;
          weekNow.place(Math.round(WEEK[0] + w.elapsed * wl) - 1, wy + 3, 2, 5);
          const weekShown = v.show === 'used' ? w.used : w.left;
          const weekHot = w.status === 'low' || w.status === 'out';
          weekNum.set(pct(weekShown), weekHot ? CLAWD : INK).at(WEEK_NUM_X, 21);
          weekSign.set('%').at(WEEK_NUM_X + weekNum.width + 2, 21);
          weekReset.set(resetText(w)).at(WEEK_NUM_X + weekNum.width + weekSign.width + 14, 21);
        }

        renderer.render(scene, camera);
      },
    };
  },
};
