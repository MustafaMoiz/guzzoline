import { defineConfig } from 'vite';

// The landing page (site/), built on its own: `npm run build:site` writes dist-site/, which is
// what Netlify serves. The gallery and the panel prototype stay in the main config.
export default defineConfig({
  root: 'site',
  build: { outDir: '../dist-site', emptyOutDir: true, target: 'es2022' },
  preview: { host: '127.0.0.1', port: 5190, strictPort: true },
});
