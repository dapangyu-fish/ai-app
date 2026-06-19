/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Served by config-center Flask at /static/dashboard/ ; build output overwrites that dir.
export default defineConfig({
  base: '/static/dashboard/',
  plugins: [react()],
  build: {
    outDir: '../static/dashboard',
    emptyOutDir: true,
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/test/setup.ts',
    css: false,
  },
});
