import { defineConfig } from 'vite';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';

// Usage numbers the Touch Bar app last read (no credentials), shown by the gallery's Live button.
const USAGE_CACHE = `${homedir()}/Library/Application Support/Barometer/usage.json`;

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
  server: { host: '127.0.0.1', port: 5188, strictPort: true },
  build: { target: 'es2022' },
});
