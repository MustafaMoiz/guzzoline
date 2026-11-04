import '@fontsource/ibm-plex-mono/300.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import '@fontsource/barlow-condensed/500.css';
import '@fontsource/barlow-condensed/600.css';
import '@fontsource/big-shoulders-stencil-display/900';
import './site.css';
import { createBar } from './bar.js';
import { createDay, SESSIONS } from './day.js';
import { createTour } from './tour.js';

// The film, cut to one shove: the levers go forward (0–0.55 s), the pipes gush, and from
// CROWD_AT the crowd below catches it.
const CROWD_AT = 3.4;
// A finger resting this long on the film is holding it, not starting to scroll the page.
const HOLD_MS = 200;
// Seconds on Marquee before its sentence crawls across, as it does now and then in the app.
const CRAWL_AFTER = 1.2;
// How far past the line between two styles (in styles) before the next one shows.
const SLACK = 0.06;
// Seconds the strip takes to glide back to its start for a new style.
const GLIDE = 0.55;

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const $ = (selector) => document.querySelector(selector);
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const smooth = (a, b, v) => {
  const x = clamp01((v - a) / (b - a));
  return x * x * (3 - 2 * x);
};

await Promise.all(['400 20px "IBM Plex Mono"', '500 20px "IBM Plex Mono"', '500 20px "Barlow Condensed"',
  '600 20px "Barlow Condensed"', '900 20px "Big Shoulders Stencil Display"'].map((font) => document.fonts.load(font)));

// The film: still until you hold it, or the label under it. Then the warlord shoves the
// levers once.
const film = $('video.film');
const pump = $('.pump');
const subtitle = $('.subtitle');
let playing = false;

function pull(sound) {
  if (playing || reduce) return;
  playing = true;
  film.muted = !sound;
  film.currentTime = 0;
  film.classList.remove('done');
  film.classList.add('on');
  pump.classList.add('gone');
  film.play().catch(() => {
    film.muted = true;
    film.play().catch(() => {});
  });
}

// A mouse press pulls at once, with sound. A finger is given a moment to show it's holding
// rather than scrolling; a browser lets sound play only once it lifts, so a hold starts the
// film quiet and lifting brings the sound in. A tap pulls too.
let hold = 0;
function down(event) {
  if (event.button !== 0) return;
  if (event.pointerType === 'mouse') {
    pull(true);
    return;
  }
  clearTimeout(hold);
  hold = setTimeout(() => {
    hold = 0;
    pull(false);
  }, HOLD_MS);
}
function cancel() {
  clearTimeout(hold);
  hold = 0;
}
function up(event) {
  if (event.pointerType === 'mouse') return;
  const tapped = hold !== 0;
  cancel();
  if (tapped) pull(true);
  else if (playing) film.muted = false;
}
for (const el of [$('.press'), pump]) {
  el.addEventListener('pointerdown', down);
  el.addEventListener('pointerup', up);
  el.addEventListener('pointercancel', cancel); // the page scrolled instead
  el.addEventListener('contextmenu', (event) => event.preventDefault()); // a long press
}
// From a keyboard, the label is a button like any other.
pump.addEventListener('click', (event) => {
  if (event.detail === 0) pull(true);
});

film.addEventListener('timeupdate', () => {
  if (film.currentTime >= CROWD_AT) subtitle.classList.add('on');
});
film.addEventListener('ended', () => {
  // Back to the warlord at his levers.
  film.classList.add('done');
  subtitle.classList.remove('on');
  setTimeout(() => {
    film.classList.remove('on', 'done');
    film.currentTime = 0;
    pump.classList.remove('gone');
    playing = false;
  }, 900);
});

// The five styles. While you scroll through their section the Touch Bar stays put, and each
// fifth of the way it changes style. Where it's too long for the screen, it also slides past
// end to end within each style (one way, then back), so you see all of it.
const section = $('.themes');
const stage = $('.stage');
const windowEl = $('.window');
const deck = $('.deck');
const barEl = $('.bar');
const ticks = [...document.querySelectorAll('.ticks i')];
const bar = createBar(barEl, SESSIONS);
const day = createDay(Date.now());
const count = bar.themes.length;
bar.open(1);

let current = -1;
let shownAt = 0;
let crawled = false;
function choose(i, t) {
  if (i === current) return;
  // Where the strip is carried past a window, it glides back to its start for the new style.
  if (current >= 0 && overflow) {
    deck.classList.add('gliding');
    clearTimeout(choose.glide);
    choose.glide = setTimeout(() => deck.classList.remove('gliding'), GLIDE * 1000);
  }
  current = i;
  shownAt = t;
  crawled = false;
  bar.show(i);
  // No name on the page; a screen reader still hears which style it is.
  barEl.setAttribute('aria-label', `A Touch Bar in the ${bar.themes[i].name} style, showing Claude usage and four Claude Code sessions`);
  ticks.forEach((tick, j) => tick.classList.toggle('on', j === i));
}

// How far the strip overhangs its window, and where the stage holds still.
let overflow = 0;
let stageTop = 0;
function measure() {
  overflow = Math.max(0, deck.offsetWidth - windowEl.clientWidth);
  stageTop = parseFloat(getComputedStyle(stage).top) || 0;
}
measure();
addEventListener('resize', measure);

// The panel on a Mac's screen (its previews are made as you come near).
const tour = createTour($('.tour'), { caption: $('.tour-caption'), reduce });

const started = performance.now() / 1000;
let last = started;
function frame(ms) {
  requestAnimationFrame(frame);
  const t = ms / 1000;
  const dt = Math.min(0.1, t - last);
  last = t;

  const box = section.getBoundingClientRect();
  const travel = box.height - stage.offsetHeight;
  const along = travel > 0 ? clamp01((stageTop - box.top) / travel) * count : 0;
  // A style changes only once you're a little past the line, so stopping on it doesn't flicker.
  let i = current < 0 ? Math.floor(along) : current;
  if (along >= current + 1 + SLACK || along < current - SLACK) i = Math.floor(along);
  i = Math.min(count - 1, Math.max(0, i));
  choose(i, t);
  if (bar.themes[i].id === 'marquee' && !crawled && t - shownAt > CRAWL_AFTER) {
    crawled = true;
    bar.tap();
  }
  if (overflow) {
    // Each style starts at the strip's left end, where its own Clawd is, rests there a moment,
    // and is carried to the right end, past the numbers and the sessions' Clawds.
    const q = smooth(0.15, 0.9, along - i);
    const inset = 24;
    deck.style.transform = `translateX(${inset - q * (overflow + 2 * inset)}px)`;
  } else deck.style.transform = '';

  // Drawn only while it's on screen.
  if (box.top < innerHeight && box.bottom > 0) {
    const now = Date.now();
    bar.render(day.at(t - started, now), day.sessions, now, dt, t);
  }
  tour.frame(t, dt);
}
requestAnimationFrame(frame);

// Copying: the install line, and the prompt for Claude Code.
for (const button of document.querySelectorAll('.copy')) {
  const code = button.parentElement.querySelector('code');
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(code.textContent.trim());
      button.textContent = 'Witnessed!';
      button.classList.add('copied');
    } catch {
      getSelection().selectAllChildren(code);
      button.textContent = 'Press ⌘C';
    }
    setTimeout(() => {
      button.textContent = 'Copy';
      button.classList.remove('copied');
    }, 2000);
  });
}
