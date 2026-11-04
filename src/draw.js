import * as THREE from 'three';

// An orthographic camera where one unit is one device pixel, origin at the bottom left.
export function pixelCamera(width, height) {
  const camera = new THREE.OrthographicCamera(0, width, height, 0, -1000, 1000);
  camera.position.z = 100;
  return camera;
}

// A flat rectangle placed in pixels: rect(color).place(x, y, w, h).
export function rect(color, opacity = 1) {
  const material = new THREE.MeshBasicMaterial({
    color, opacity, transparent: opacity < 1, depthWrite: false, toneMapped: false,
  });
  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), material);
  mesh.place = (x, y, w, h) => {
    mesh.position.set(x + w / 2, y + h / 2, mesh.position.z);
    mesh.scale.set(Math.max(w, 1e-4), Math.max(h, 1e-4), 1);
    return mesh;
  };
  return mesh;
}

export const mix = (a, b, t) => a + (b - a) * t;
export const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
// Frame-rate independent easing toward a target.
export const approach = (v, target, rate, dt) => v + (target - v) * (1 - Math.exp(-rate * dt));
