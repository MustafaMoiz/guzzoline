import * as THREE from 'three';
import { CLAWD, animate } from '../clawd.js';
import { bodyMaterial, eyeMaterial, figure, lights } from '../voxel.js';
import { Label } from '../text.js';
import { approach, clamp, pixelCamera, rect } from '../draw.js';
import { pct, resetText } from '../format.js';

const INK = '#f2efe9';
const MUTED = '#8b877f';

const U = 3; // one mascot unit, in pixels
const GROUND = 17;
// Laid out from the bar's width: the second limit's figures end at the right margin, its track
// sits before them, then the first limit's figures, and the walk takes the rest.
function layout(width) {
  const right = width - 30;
  const weekLen = Math.round(width * 0.15);
  const week1 = right - 176;
  const numX = week1 - weekLen - 90 - 200;
  return { path: [34, numX - 40], numX, week: [week1 - weekLen, week1], right };
}

export default {
  id: 'walk',
  name: 'Walk',
  note: 'Clawd walks the session. Behind it is spent, ahead is what’s left.',

  create(canvas, { width, height }) {
    const { path: PATH, numX: NUM_X, week: WEEK, right: RIGHT } = layout(width);
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    renderer.setPixelRatio(1);
    renderer.setSize(width, height, false);
    renderer.setClearColor(0x000000, 1);

    const scene = new THREE.Scene();
    const camera = pixelCamera(width, height);

    lights(scene);
    const body = bodyMaterial();
    const eye = eyeMaterial();
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
          weekNum.set(pct(weekShown), weekHot ? CLAWD : INK);
          weekSign.set('%');
          weekReset.set(resetText(w));
          const weekX = RIGHT - (weekNum.width + 2 + weekSign.width + 14 + weekReset.width);
          weekNum.at(weekX, 21);
          weekSign.at(weekX + weekNum.width + 2, 21);
          weekReset.at(weekX + weekNum.width + 2 + weekSign.width + 14, 21);
        }

        renderer.render(scene, camera);
      },
    };
  },
};
