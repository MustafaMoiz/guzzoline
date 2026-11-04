const MIN = 60e3;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

export const pct = (v) => String(Math.round(v * 100));

// "2h 14m", "14m", "3d 4h": how long until a reset.
export function until(ms) {
  if (ms == null) return '';
  if (ms >= DAY) {
    const d = Math.floor(ms / DAY);
    const h = Math.floor((ms % DAY) / HOUR);
    return h ? `${d}d ${h}h` : `${d}d`;
  }
  if (ms >= HOUR) {
    const h = Math.floor(ms / HOUR);
    const m = Math.floor((ms % HOUR) / MIN);
    return m ? `${h}h ${m}m` : `${h}h`;
  }
  return ms >= MIN ? `${Math.floor(ms / MIN)}m` : '<1m';
}

const timeParts = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });

// { time: "4:10", period: "pm" } in the viewer's locale; period is '' on a 24-hour clock.
export function clock(ts) {
  const parts = timeParts.formatToParts(ts);
  const time = parts.filter((p) => p.type !== 'dayPeriod').map((p) => p.value).join('').trim();
  const period = parts.find((p) => p.type === 'dayPeriod')?.value.toLowerCase().replace(/\./g, '') ?? '';
  return { time, period };
}

export const weekday = (ts) => new Date(ts).toLocaleDateString(undefined, { weekday: 'short' });

// When a window resets: a countdown once it has run out, otherwise a time for the session
// (and for a week resetting within the day) and a weekday for the week.
export function resetText(win) {
  if (!win.active) return '';
  if (win.status === 'out') return `in ${until(win.resetIn)}`;
  if (win.kind === 'session' || win.resetIn < DAY) {
    const { time, period } = clock(win.resetsAt);
    return period ? `${time} ${period}` : time;
  }
  return weekday(win.resetsAt);
}
