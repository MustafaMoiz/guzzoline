import * as THREE from 'three';
import { CLAWD, PARTS } from './clawd.js';

// Lights for the voxel mascot, as Walk has them: a warm sky, a key light from the front left,
// and a rim from behind.
export function lights(scene) {
  scene.add(new THREE.HemisphereLight(0xfff4ec, 0x2a1c16, 1.6));
  const key = new THREE.DirectionalLight(0xffffff, 3.2);
  key.position.set(-0.5, 0.8, 1.6);
  const rim = new THREE.DirectionalLight(0xffe2d2, 1.4);
  rim.position.set(1, 0.4, -0.8);
  scene.add(key, rim);
}

export const bodyMaterial = () => new THREE.MeshStandardMaterial({
  color: CLAWD, roughness: 0.6, metalness: 0, emissive: CLAWD, emissiveIntensity: 0.12,
});
export const eyeMaterial = () => new THREE.MeshBasicMaterial({ color: 0x0b0604 });

// The mascot in voxels: a body block with recessed eyes, and arms and legs that move.
export function figure(bodyMaterial, eyeMaterial) {
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

  // `wave` raises the right arm and swings it, from 0 (down) to 1 (all the way up); `cheer`
  // raises both, as Claude Code's arms-up pose does.
  function pose({ grid, phase, walking, squash, wave = 0, swing = 0, cheer = 0 }) {
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
      if (i === 1 && wave) {
        // Raised beside the head, still against the body, waving out and back.
        arm.position.x += wave * (0.25 + swing * 0.35);
        arm.position.y += wave * (3 + swing * 0.4);
      }
      if (cheer) {
        arm.position.x += (i ? 1 : -1) * cheer * 0.25;
        arm.position.y += cheer * 3;
      }
    });
  }

  return { group, pose };
}

