// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  site: 'https://hearcat.natume.workers.dev',
  vite: {
    plugins: [tailwindcss()]
  }
});