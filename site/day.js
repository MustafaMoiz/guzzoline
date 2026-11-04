import { DAY, HOUR, MIN } from '../src/state.js';

// Half a minute of a working day, looped: four Claude Code sessions start, wait on you and
// finish. The usage holds still, as it would over half a minute. Times are seconds into the loop.
export const LENGTH = 30;

const TITLES = ['Landing page', 'Invoice parser', 'Flaky tests', 'Release notes'];
const STATES = [
  [0, ['working', 'working', 'idle', 'done']],
  [5, ['working', 'asking', 'idle', 'done']],
  [10, ['working', 'working', 'working', 'done']],
  [15, ['done', 'working', 'working', 'idle']],
  [21, ['done', 'working', 'asking', 'idle']],
  [25, ['done', 'done', 'working', 'idle']],
];

export const SESSIONS = TITLES.length;

export function createDay(start = Date.now()) {
  const sessions = TITLES.map((title, i) => ({ id: `local_${i}`, title, state: 'idle' }));
  // The 5-hour window began 2h 10m ago; the week 3.4 days ago.
  const sessionReset = start + 2 * HOUR + 50 * MIN;
  const weekReset = start + 3.6 * DAY;
  return {
    sessions,
    // The bar's model at a moment of the loop: which sessions do what, and how much is used.
    at(loopT, now) {
      const t = ((loopT % LENGTH) + LENGTH) % LENGTH;
      let states = STATES[0][1];
      for (const [from, s] of STATES) if (t >= from) states = s;
      states.forEach((state, i) => { sessions[i].state = state; });
      return {
        windows: [
          { key: 'five_hour', used: 0.41, resetsAt: sessionReset },
          { key: 'seven_day', used: 0.42, resetsAt: weekReset },
        ],
        working: states.includes('working'),
        show: 'left',
        live: false,
      };
    },
  };
}
