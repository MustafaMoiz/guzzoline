import { defineConfig } from 'vite';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, join } from 'node:path';

// Usage numbers the Touch Bar app last read (no credentials), shown by the gallery's Live button.
const USAGE_CACHE = `${homedir()}/Library/Application Support/Guzzoline/usage.json`;

// The Claude app keeps a file per Claude Code session (its own format, not a published one):
// <account>/<org>/local_<id>.json, and an entry in waiting-input/ while one waits on you.
const SESSIONS = `${homedir()}/Library/Application Support/Claude/claude-code-sessions`;
const RECENT = 12 * 60 * 60e3;

// Each claude process keeps a record of the session it runs, <pid>.json, which says busy until
// its turn is over and so is any agent or workflow it left working in the background.
const RUNNING = `${homedir()}/.claude/sessions`;

// The Claude app's ids for the sessions Claude Code is still busy with, as the Touch Bar app reads
// them: a record counts while its process runs and began before the record did (a process that
// ended without clearing its record left it behind, and a newer one may have its number).
function busySessions() {
  if (!existsSync(RUNNING)) return new Set();
  const runs = [];
  for (const file of readdirSync(RUNNING).filter((f) => /^\d+\.json$/.test(f))) {
    try {
      const r = JSON.parse(readFileSync(join(RUNNING, file), 'utf8'));
      if (r.hostSessionId && r.pid > 0 && ['busy', 'waiting'].includes(r.status)) runs.push(r);
    } catch { /* a file being written */ }
  }
  if (!runs.length) return new Set();
  const began = {};
  try {
    const ps = execFileSync('ps', ['-o', 'pid=,lstart=', '-p', runs.map((r) => r.pid).join(',')], { encoding: 'utf8' });
    for (const [, pid, start] of ps.matchAll(/^\s*(\d+)\s+(.+?)\s*$/gm)) began[pid] = Date.parse(start);
  } catch { /* none of them is running */ }
  return new Set(runs.filter((r) => began[r.pid] <= (r.startedAt ?? 0) + 1000).map((r) => r.hostSessionId));
}

// A session's state: waiting on you, working until its latest message has a summary and Claude
// Code isn't busy with it, or finished: done (or failed) for an hour, idle after. The Touch Bar
// app starts the hour when you're next at the Mac.
function sessionState(s, waiting, busy) {
  if (waiting) return 'asking';
  if (s.postTurnSummaryFor !== s.lastAssistantUuid || busy) return 'working';
  if (Date.now() - (s.lastTurnEdgeAt ?? 0) > 60 * 60e3) return 'idle';
  return s.postTurnSummary?.status_category === 'failed' ? 'failed' : 'done';
}

// Recent, unarchived sessions, the latest first: titles and states only.
function recentSessions() {
  if (!existsSync(SESSIONS)) return [];
  const out = [];
  const busy = busySessions();
  for (const account of readdirSync(SESSIONS)) {
    for (const org of readdirSync(join(SESSIONS, account))) {
      const dir = join(SESSIONS, account, org);
      const waiting = existsSync(join(dir, 'waiting-input')) ? readdirSync(join(dir, 'waiting-input')).join(' ') : '';
      for (const file of readdirSync(dir).filter((f) => /^local_.*\.json$/.test(f))) {
        try {
          const s = JSON.parse(readFileSync(join(dir, file), 'utf8'));
          if (s.isArchived || Date.now() - (s.lastActivityAt ?? 0) > RECENT) continue;
          out.push({ id: s.sessionId, title: s.title || 'Untitled', state: sessionState(s, waiting.includes(s.sessionId), busy.has(s.sessionId)),
            createdAt: s.createdAt ?? 0, activityAt: s.lastActivityAt ?? 0 });
        } catch { /* a file being written */ }
      }
    }
  }
  return out.sort((a, b) => b.activityAt - a.activityAt);
}

// The five last active, in the order they began, as the bar has them.
const readSessions = () => recentSessions().slice(0, 5).sort((a, b) => a.createdAt - b.createdAt).map(({ id, title, state }) => ({ id, title, state }));

// The Mac's alert sounds, which the panel's prototypes play.
const SOUNDS = ['Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse', 'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink'];
const defaultsRead = (domain, key) => {
  try { return execFileSync('defaults', ['read', domain, key], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return null; }
};

// Dev only: the page can POST a PNG of a bar to /__capture?name=walk, saved in captures/,
// for looking at bars pixel for pixel (and for screenshots).
const capture = {
  name: 'capture',
  configureServer(server) {
    server.middlewares.use('/__capture', (req, res) => {
      const name = new URL(req.url, 'http://local').searchParams.get('name')?.replace(/[^\w-]/g, '') || 'bar';
      const chunks = [];
      req.on('data', (chunk) => chunks.push(chunk));
      req.on('end', () => {
        mkdirSync('captures', { recursive: true });
        writeFileSync(`captures/${name}.png`, Buffer.concat(chunks));
        res.end('ok');
      });
    });
    server.middlewares.use('/__sessions', (req, res) => {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify(readSessions()));
    });
    // For the panel's prototypes: the eight last active, the five the bar shows by default ticked.
    server.middlewares.use('/__recent', (req, res) => {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify(recentSessions().slice(0, 8).map(({ id, title, state }, i) => ({ id, title, state, onBar: i < 5 }))));
    });
    // The Touch Bar app's settings, and the Mac's own alert sound.
    server.middlewares.use('/__prefs', (req, res) => {
      const mac = defaultsRead('-g', 'com.apple.sound.beep.sound');
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({
        theme: defaultsRead('app.guzzoline', 'theme') ?? 'walk',
        showing: defaultsRead('app.guzzoline', 'showing') ?? 'front',
        sound: defaultsRead('app.guzzoline', 'sound') ?? (mac ? basename(mac).replace(/\.\w+$/, '') : 'Glass'),
      }));
    });
    // One of the Mac's alert sounds as WAV, which browsers play (AIFF they don't).
    server.middlewares.use('/__sound', (req, res) => {
      const name = new URL(req.url, 'http://local').searchParams.get('name');
      if (!SOUNDS.includes(name)) {
        res.statusCode = 404;
        res.end();
        return;
      }
      const wav = join(tmpdir(), `guzzoline-sound-${name}.wav`);
      try {
        if (!existsSync(wav)) execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16', `/System/Library/Sounds/${name}.aiff`, wav]);
        res.setHeader('Content-Type', 'audio/wav');
        res.end(readFileSync(wav));
      } catch {
        res.statusCode = 500;
        res.end();
      }
    });
    server.middlewares.use('/__usage', (req, res) => {
      try {
        res.setHeader('Content-Type', 'application/json');
        res.end(readFileSync(USAGE_CACHE));
      } catch {
        res.statusCode = 404;
        res.end('{}');
      }
    });
  },
};

export default defineConfig({
  plugins: [capture],
  // The app's build copies the page into build/, which mustn't reload the gallery.
  server: { host: '127.0.0.1', port: 5188, strictPort: true, watch: { ignored: ['**/build/**', '**/dist/**', '**/captures/**'] } },
  build: { target: 'es2022' },
});
