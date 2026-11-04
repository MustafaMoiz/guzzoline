import * as THREE from 'three';

// A line of text drawn at device-pixel size and shown 1:1 on a plane, for orthographic scenes
// where one unit is one pixel.
export class Label {
  constructor({ font, color = '#f2efe9', align = 'left', letterSpacing = '0px', pad = 3 }) {
    Object.assign(this, { font, color, align, letterSpacing, pad });
    this.canvas = document.createElement('canvas');
    this.ctx = this.canvas.getContext('2d');
    this.material = new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, toneMapped: false });
    this.mesh = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), this.material);
    this.text = null;
    this.width = 0;
    this.x = 0;
    this.y = 0;
  }

  set(text, color = this.color) {
    if (text === this.text && color === this.drawnColor) return this;
    this.text = text;
    this.drawnColor = color;
    const { ctx, pad } = this;
    ctx.font = this.font;
    ctx.letterSpacing = this.letterSpacing;
    const m = ctx.measureText(text || ' ');
    this.ascent = Math.ceil(m.fontBoundingBoxAscent);
    const w = Math.max(1, Math.ceil(m.width) + pad * 2);
    const h = Math.ceil(m.fontBoundingBoxAscent + m.fontBoundingBoxDescent) + pad * 2;
    this.canvas.width = w;
    this.canvas.height = h;
    ctx.font = this.font;
    ctx.letterSpacing = this.letterSpacing;
    ctx.fillStyle = color;
    ctx.textBaseline = 'alphabetic';
    ctx.fillText(text, pad, pad + this.ascent);
    this.material.map?.dispose();
    const tex = new THREE.CanvasTexture(this.canvas);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.generateMipmaps = false;
    tex.minFilter = tex.magFilter = THREE.LinearFilter;
    this.material.map = tex;
    this.material.needsUpdate = true;
    this.width = w - pad * 2;
    this.mesh.scale.set(w, h, 1);
    return this.at(this.x, this.y);
  }

  // Put the text's baseline at y (from the bottom), aligned on x.
  at(x, y) {
    this.x = x;
    this.y = y;
    const w = this.mesh.scale.x;
    const h = this.mesh.scale.y;
    let left = x - this.pad;
    if (this.align === 'right') left = x - this.width - this.pad;
    if (this.align === 'center') left = x - this.width / 2 - this.pad;
    left = Math.round(left);
    const top = Math.round(y + this.ascent + this.pad);
    this.mesh.position.set(left + w / 2, top - h / 2, 0);
    return this;
  }
}
