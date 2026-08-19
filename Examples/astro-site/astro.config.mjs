import { defineConfig } from 'astro/config';

export default defineConfig({
  // 'file' format (about.html instead of about/index.html) keeps relative
  // links working when the built site is browsed straight from dist/ over
  // file:// — which is how Tim previews a site before it's deployed.
  build: { format: 'file' },
});
