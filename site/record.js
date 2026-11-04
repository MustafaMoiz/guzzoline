import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import { createTour } from './tour.js';

// The panel demo alone, for recording a video of it. Each step's start is noted, by the
// page's clock, in window.marks, so a recorder can cut exactly one loop.
await Promise.all(['400 20px "IBM Plex Mono"', '500 20px "IBM Plex Mono"', '500 20px "Barlow Condensed"',
  '600 20px "Barlow Condensed"'].map((font) => document.fonts.load(font)));

window.marks = [];
const tour = createTour(document.querySelector('.tour'), {
  caption: document.querySelector('.tour-caption'),
  onStep: (key) => window.marks.push({ key, at: performance.timeOrigin + performance.now() }),
});

let last = performance.now();
function frame(ms) {
  requestAnimationFrame(frame);
  const dt = Math.min(0.1, (ms - last) / 1000);
  last = ms;
  tour.frame(ms / 1000, dt);
}
requestAnimationFrame(frame);
