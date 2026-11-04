// Clawd, Claude Code's mascot, decoded from the block glyphs Claude Code draws it with
// (2.1.309). A character cell is 2×2 quadrants, and a terminal quadrant is twice as tall as it
// is wide, so the grids here are in square units: 2 columns by 4 rows per cell.

export const CLAWD = '#d77757'; // clawd_body, rgb(215,119,87)

export const W = 17;
export const H = 10;

// In the default pose, in grid units (y down): the body block, then the parts around it.
export const PARTS = {
  body: { x: 2, y: 0, w: 13, h: 8 },
  eyes: [{ x: 4, y: 2 }, { x: 12, y: 2 }],
  arms: [{ x: 0, y: 4, w: 2, h: 2 }, { x: 15, y: 4, w: 2, h: 2 }],
  legs: [2, 4, 12, 14].map((x) => ({ x, y: 8, w: 1, h: 2 })),
};

// Quadrant bits: 1 upper-left, 2 upper-right, 4 lower-left, 8 lower-right.
const QUADS = {
  ' ': 0, '▘': 1, '▝': 2, '▀': 3, '▖': 4, '▌': 5, '▞': 6, '▛': 7,
  '▗': 8, '▚': 9, '▐': 10, '▜': 11, '▄': 12, '▙': 13, '▟': 14, '█': 15,
};

const ARMS = {
  down: { r1L: ' ▐', r1R: '', r2L: '▝▜', r2R: '█▀' },
  up: { r1L: '▗▟', r1R: '▄', r2L: ' ▜', r2R: '█▘' },
  'one-up': { r1L: ' ▐', r1R: '▄', r2L: '▝▜', r2R: '█▘' },
};

// A lid cell is the body colour with a dark line across its bottom quarter: a closed eye.
const EYES = {
  open: [['▛███▛█']],
  left: [['▟███▟█']],
  right: [['█▟███▟']],
  closed: [['▂', true], ['███'], ['▂', true], ['█']],
  wink: [['▛███'], ['▂', true], ['█']],
};

const FEET = { both: ' ▝▝   ▝▝ ', left: ' ▝▝      ', right: '      ▝▝ ' };

// Claude Code's turnaround, in 13 frames: [glyphs, face from, face to] per row. Cells outside
// the face range are the side of the body.
const TURN = {
  'right-12': [[' ▐█▜██▛█ ', 2, 8], ['▝▜██████▀', 2, 7], [' ▝▝   ▝▝ ']],
  'right-30': [['  █▛██▛▌ ', 2, 7], [' ▝█████▛ ', 2, 7], ['  ▘▘  ▘▘ ']],
  'right-55': [['  ▐█▛█▜  ', 3, 7], ['  ▐████  ', 3, 7], ['  ▝▝ ▝▝  ']],
  'right-75': [['   ██▛▌  ', 3, 6], ['   ███▌  ', 3, 6], ['   ▘  ▘  ']],
  edge: [['   ▐██   ', 4, 6], ['   ▐██   ', 4, 6], ['   ▝ ▝   ']],
  'back-105': [['   ███▌  ', 3, 6], ['   ███▌  ', 3, 6], ['   ▘  ▘  ']],
  'back-125': [['  ▐████  ', 3, 7], ['  ▐████  ', 3, 7], ['  ▝▝ ▝▝  ']],
  'back-150': [['  █████▌ ', 2, 7], [' ▝█████▛ ', 2, 7], ['  ▘▘  ▘▘ ']],
  back: [[' ▐██████ ', 2, 8], ['▝▜██████▀', 2, 7], [' ▝▝   ▝▝ ']],
  'left-75': [['   ▛██▌  ', 3, 6], ['   ███▌  ', 3, 6], ['   ▘  ▘  ']],
  'left-55': [['  ▐▜▛██  ', 3, 7], ['  ▐████  ', 3, 7], ['  ▝▝ ▝▝  ']],
  'left-30': [['  ▛██▛█▌ ', 2, 7], [' ▝█████▛ ', 2, 7], ['  ▘▘  ▘▘ ']],
  'left-12': [[' ▐▛███▜█ ', 2, 8], ['▝▜██████▀', 2, 7], [' ▝▝   ▝▝ ']],
};
export const TURN_FRAMES = ['right-12', 'right-30', 'right-55', 'right-75', 'edge', 'back-105',
  'back-125', 'back-150', 'back', 'left-75', 'left-55', 'left-30', 'left-12'];

const cells = (glyphs, lid = false) => [...glyphs].map((ch) => ({ ch, lid }));

// A grid is H rows of W values: 0 empty, 1 body, 2 side of the body.
function decode(rows) {
  const grid = Array.from({ length: 12 }, () => new Uint8Array(18));
  rows.forEach((row, r) => row.forEach(({ ch, lid, side }, i) => {
    const x = i * 2;
    const y = r * 4;
    const v = side ? 2 : 1;
    if (lid) {
      for (let k = 0; k < 3; k++) grid[y + k][x] = grid[y + k][x + 1] = v;
      return;
    }
    const m = QUADS[ch] ?? 0;
    if (m & 1) grid[y][x] = grid[y + 1][x] = v;
    if (m & 2) grid[y][x + 1] = grid[y + 1][x + 1] = v;
    if (m & 4) grid[y + 2][x] = grid[y + 3][x] = v;
    if (m & 8) grid[y + 2][x + 1] = grid[y + 3][x + 1] = v;
  }));
  // The first unit column and the last two rows are always empty.
  return grid.slice(0, H).map((row) => row.slice(1, 1 + W));
}

const cache = new Map();

export function pose({ eyes = 'open', arms = 'down', feet = 'both' } = {}) {
  const key = `${eyes}/${arms}/${feet}`;
  if (!cache.has(key)) {
    const a = ARMS[arms];
    const eyeCells = EYES[eyes].flatMap(([g, lid]) => cells(g, lid));
    cache.set(key, decode([
      [...cells(a.r1L), ...eyeCells, ...cells(a.r1R)],
      [...cells(a.r2L), ...cells('█████'), ...cells(a.r2R)],
      cells(FEET[feet]),
    ]));
  }
  return cache.get(key);
}

export function turn(name) {
  const key = `turn/${name}`;
  if (!cache.has(key)) {
    cache.set(key, decode(TURN[name].map(([glyphs, from = 0, to = 0]) => [...glyphs].map((ch, i) => ({
      ch, side: from !== to && (i < from || i >= to),
    })))));
  }
  return cache.get(key);
}

// The pose for a moment in time: blinking now and then, walking when Claude is working.
export function animate(t, { working = false, asleep = false, seed = 0 } = {}) {
  if (asleep) return pose({ eyes: 'closed' });
  const blinkEvery = 4.2 + (seed % 3) * 0.7;
  const blinking = (t + seed) % blinkEvery < 0.13;
  const eyes = blinking ? 'closed' : 'open';
  if (!working) return pose({ eyes });
  const step = Math.floor(t * 7) % 4; // both, left, both, right
  return pose({ eyes, feet: ['both', 'left', 'both', 'right'][step] });
}

// Draw a grid on a 2D canvas, one unit as `u` pixels. `side` colours the side of the body.
export function draw(ctx, grid, x, y, u, color = CLAWD, side = '#a3563d') {
  for (let r = 0; r < grid.length; r++) {
    for (let c = 0; c < grid[r].length; c++) {
      const v = grid[r][c];
      if (!v) continue;
      ctx.fillStyle = v === 2 ? side : color;
      ctx.fillRect(x + c * u, y + r * u, u, u);
    }
  }
}
