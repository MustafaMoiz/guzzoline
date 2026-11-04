export const MIN = 60e3;
export const HOUR = 60 * MIN;
export const DAY = 24 * HOUR;
export const SESSION_MS = 5 * HOUR;
export const WEEK_MS = 7 * DAY;

const clamp01 = (v) => Math.min(1, Math.max(0, v));

// What a limit is called and how long its window runs. Keys are the usage API's: five_hour,
// seven_day, and seven_day_<model> for a model's own weekly limit.
export function describe(key) {
  if (key === 'five_hour') return { kind: 'session', short: '5H', name: 'session', phrase: 'the session', length: SESSION_MS };
  if (key === 'seven_day') return { kind: 'week', short: 'WK', name: 'week', phrase: 'the week', length: WEEK_MS };
  const model = key.replace(/^seven_day_/, '').replace(/_/g, ' ');
  return { kind: 'week', short: model.slice(0, 2).toUpperCase(), name: model, phrase: `the ${model} week`, length: WEEK_MS };
}

// One limit as a theme sees it. `used` and `left` are fractions of the limit, `elapsed` the
// fraction of the window's time that has passed: at an even pace, used ≈ elapsed.
function windowView({ key, used, resetsAt }, now) {
  const about = describe(key);
  const active = resetsAt != null && resetsAt > now;
  const u = active ? clamp01(used) : 0;
  const elapsed = active ? clamp01(1 - (resetsAt - now) / about.length) : 0;
  let status = 'ok';
  if (!active) status = 'fresh';
  else if (u >= 1) status = 'out';
  else if (u >= 0.9) status = 'low';
  else if (u > elapsed + 0.1) status = 'fast';
  // At the pace so far, when the limit runs out, if that comes before the reset.
  let runsOutAt = null;
  if (active && u > 0 && u < 1 && elapsed > 0.02) {
    const at = now + ((1 - u) * elapsed * about.length) / u;
    if (at < resetsAt) runsOutAt = at;
  }
  return {
    key, ...about, used: u, left: 1 - u, elapsed, active, status, runsOutAt,
    resetsAt: active ? resetsAt : null,
    resetIn: active ? resetsAt - now : null,
  };
}

const rank = (w) => (w.key === 'five_hour' ? 0 : w.key === 'seven_day' ? 1 : 2);

// The two limits a bar shows, in order: the 5-hour session and the week on plans with a
// session limit; otherwise the week and the next weekly limit, such as one model's.
export const slots = (windows) => [...windows].sort((a, b) => rank(a) - rank(b)).slice(0, 2);

export function view(model, now) {
  const [a, b] = slots(model.windows);
  return {
    now,
    primary: a ? windowView(a, now) : null,
    secondary: b ? windowView(b, now) : null,
    working: model.working,
    show: model.show,
    live: model.live,
  };
}

const win = (key, used, resetsAt) => ({ key, used, resetsAt });

export const SCENARIOS = {
  Fresh: (now) => [win('five_hour', 0, null), win('seven_day', 0.12, now + 6.2 * DAY)],
  Steady: (now) => [win('five_hour', 0.34, now + 2.75 * HOUR), win('seven_day', 0.41, now + 3.6 * DAY)],
  Burning: (now) => [win('five_hour', 0.72, now + 3.4 * HOUR), win('seven_day', 0.66, now + 4.4 * DAY)],
  Low: (now) => [win('five_hour', 0.93, now + 0.8 * HOUR), win('seven_day', 0.88, now + 1.3 * DAY)],
  Out: (now) => [win('five_hour', 1, now + 67 * MIN), win('seven_day', 0.74, now + 2.1 * DAY)],
  'Week out': (now) => [win('five_hour', 0.18, now + 4.1 * HOUR), win('seven_day', 1, now + 1.6 * DAY)],
  // A plan with no session limit: the week, and one model's week.
  'Weekly only': (now) => [win('seven_day', 0.02, now + 3.45 * DAY), win('seven_day_fable', 0, now + 3.45 * DAY)],
};

export function createModel(now) {
  return { windows: SCENARIOS.Steady(now), working: false, show: 'left', live: false };
}

const resetTime = (at) => (at ? Date.parse(at) : null);

// One entry of the usage API's list of limits, the ones the Claude app's usage card shows:
// { kind: "weekly_all" | "weekly_scoped" | …, group: "weekly", percent: 2, resets_at: "…",
//   scope: { model: { display_name: "Fable" } } }.
function fromLimit(limit) {
  const model = limit.scope?.model?.display_name;
  const session = limit.group === 'session' || /five|hour|session/.test(limit.kind ?? '');
  const key = session ? 'five_hour' : model ? `seven_day_${model.toLowerCase()}` : 'seven_day';
  return win(key, limit.percent / 100, resetTime(limit.resets_at));
}

// Limits from the usage API's response. It lists them under `limits`; older responses had only
// top-level windows, { five_hour: { utilization: 34, resets_at: "…" }, seven_day: …, … }.
export function fromUsage(usage) {
  if (Array.isArray(usage?.limits) && usage.limits.length) {
    return usage.limits.filter((l) => typeof l.percent === 'number').map(fromLimit);
  }
  return Object.entries(usage ?? {})
    .filter(([key, v]) => /^(five_hour|seven_day)/.test(key) && typeof v?.utilization === 'number')
    .map(([key, v]) => win(key, v.utilization / 100, resetTime(v.resets_at)));
}

const rand = (a, b) => a + Math.random() * (b - a);

// A made-up working day, sped up: bursts of work that spend the limits, pauses between them,
// sessions that run out and reset.
export function createLapse(model) {
  let phaseLeft = 0;
  let rate = 0.3; // session spent per hour while working
  return function step(now, dt) {
    const hours = dt / HOUR;
    const session = model.windows.find((w) => w.key === 'five_hour');
    const weeks = model.windows.filter((w) => w !== session);
    phaseLeft -= dt;
    const blocked = model.windows.some((w) => w.used >= 1 && w.resetsAt > now && rank(w) < 2);
    if (phaseLeft <= 0 || (model.working && blocked)) {
      model.working = !model.working && !blocked;
      phaseLeft = model.working ? rand(10, 50) * MIN : rand(6, 40) * MIN;
      rate = rand(0.12, 0.5);
    }
    if (session && session.resetsAt != null && now >= session.resetsAt) {
      session.resetsAt = null;
      session.used = 0;
    }
    for (const w of weeks) {
      if (w.resetsAt != null && now >= w.resetsAt) {
        w.resetsAt += WEEK_MS;
        w.used = 0;
      }
    }
    if (!model.working) return;
    if (session) {
      if (session.resetsAt == null) {
        session.resetsAt = now + SESSION_MS;
        session.used = 0;
      }
      session.used = Math.min(1, session.used + rate * hours);
    }
    weeks.forEach((w, i) => {
      w.used = Math.min(1, w.used + ((rate * hours) / (session ? 11 : 4)) * (i ? 0.5 : 1));
    });
  };
}
