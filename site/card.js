import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import '@fontsource/big-shoulders-stencil-display/900';
import { createBar } from './bar.js';
import { createDay, SESSIONS } from './day.js';

// The social card's Touch Bar: Marquee, whose lamps read even when the card is small, with the
// made-up day's sessions working, waiting, finished and dozing. window.ready says it's drawn.
const STYLE = 'marquee';
const MOMENT = 7; // seconds into the made-up day: one session of each kind
// A fixed afternoon, so the session resets at a plain time ("4:30 PM") whenever it's drawn.
const NOW = new Date(2026, 10, 4, 13, 40).getTime();

await Promise.all(['400 20px "IBM Plex Mono"', '500 20px "IBM Plex Mono"', '500 20px "Barlow Condensed"',
  '600 20px "Barlow Condensed"', '900 20px "Big Shoulders Stencil Display"'].map((font) => document.fonts.load(font)));

const bar = createBar(document.querySelector('.bar'), SESSIONS);
const day = createDay(NOW);
bar.open(1);
bar.show(bar.themes.findIndex((t) => t.id === STYLE));

const start = performance.now();
let last = start;
function frame(ms) {
  const dt = Math.min(0.1, (ms - last) / 1000);
  last = ms;
  bar.render(day.at(MOMENT, NOW), day.sessions, NOW, dt, ms / 1000);
  if (ms - start > 1500) window.ready = true; // past the fade from the first style
  else requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
